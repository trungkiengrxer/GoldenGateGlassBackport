// The app computes the glass 27 recipe for each glass and writes the real values into the glassBackground filter (like
// DesignLibrary 27 applying Parameters), plus a recipe code for the 27-only groups.
// Lives in GGLegibility.dylib (also in the Dock, Control Center: no AppKit link, every AppKit call goes through the runtime,
// main thread only).
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import "Recipe27.h"
#import "Legibility.h"

// MARK: - Shader handshake and settings

/// GGGlass sets the notify state ABI = 2 when the shader understands recipe codes. Anything else (old GGGlass, off) and the
/// app writes nothing new. GG_ABI_FAKE: fake value for tests; GG_ABI_NAME: test name.
static int ggABI(void) {
    static int abi = -1;
    if (abi >= 0) return abi;
    const char *fake = getenv("GG_ABI_FAKE");
    if (fake) return abi = atoi(fake);
    int token; uint64_t st = 0;
    const char *name = getenv("GG_ABI_NAME") ?: "com.goldengate.glass.abi";
    if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) { notify_get_state(token, &st); notify_cancel(token); }
    return abi = (int)st;
}

static BOOL ggEnabled(void) {
    static int on = -1;
    if (on < 0) {
        const char *alt = getenv("GG_PREFS");
        NSDictionary *s = alt ? [NSDictionary dictionaryWithContentsOfFile:@(alt)]
                              : [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
        id v = s[@"GGApp.appRecipes"];
        on = (v ? [v boolValue] : YES) && ggABI() == 2;
    }
    return on;
}

// MARK: - Glass identity

/// The 26.6 face result when 26.6 assigns the filter (before the app overwrites it), remembered on the layer for later recomputes.
/// recipe: >= 0 from the face, -1 adaptive/unknown; -3 not yet. shadow: 26.6 has a shadow (inputShadowOpacity > 0) for this glass.
/// subdued, boost: only for widgets/notification cards in NotificationCenter (gg_face_nc).
typedef struct { int recipe; bool dark, inactive; float x; bool shadow, subdued, boost; } GGFace;
static const void *kFaceKey = &kFaceKey;
static void ggSetFace(CALayer *l, GGFace f) {
    objc_setAssociatedObject(l, kFaceKey, [NSValue valueWithBytes:&f objCType:@encode(GGFace)], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL ggGetFace(CALayer *l, GGFace *f) {
    NSValue *v = objc_getAssociatedObject(l, kFaceKey);
    if (!v) return NO;
    [v getValue:f size:sizeof *f];
    return YES;
}

static double ggNum(id f, NSString *k, double d) { id v = [f valueForKey:k]; return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : d; }

/// NotificationCenter process (desktop widgets, notifications). GG_HOST_NC: tests treat the test process as NotificationCenter.
static BOOL ggHostNC(void) {
    if (getenv("GG_HOST_NC")) return YES;
    static int nc = -1;
    if (nc < 0) nc = [[NSBundle mainBundle].bundleIdentifier isEqual:@"com.apple.notificationcenterui"];
    return nc;
}

static GGFace ggFaceOf(id f) {
    double fill[4] = {0, 0, 0, 0};
    CGColorRef c = (__bridge CGColorRef)[f valueForKey:@"inputFaceColorMatrixFillColor"];
    if (c && CFGetTypeID(c) == CGColorGetTypeID()) {
        size_t n = CGColorGetNumberOfComponents(c);
        const CGFloat *cc = CGColorGetComponents(c);
        if (n >= 4) for (int i = 0; i < 4; i++) fill[i] = cc[i];
        else if (n == 2) { fill[0] = fill[1] = fill[2] = cc[0]; fill[3] = cc[1]; }
    }
    GGFace r = {-1, false, false, 0, ggNum(f, @"inputShadowOpacity", 0) > 0, false, false};
    double b = ggNum(f, @"inputFaceColorMatrixBlack", 0), w = ggNum(f, @"inputFaceColorMatrixWhite", 1),
           s = ggNum(f, @"inputFaceColorMatrixSaturation", 1);
    // Widgets (ChicletRecipe) and notification cards (NotificationCenterRecipe): light/dark comes from the face, because
    // NotificationCenter forces the widget glass appearance per tint style (filterStyle), not per appearance.
    if (ggHostNC() && (r.recipe = gg_face_nc(b, w, s, fill, &r.dark, &r.inactive, &r.subdued, &r.boost)) >= 0) return r;
    r.recipe = gg_face_recipe(b, w, s, fill, &r.dark, &r.inactive);
    return r;
}

/// View holding the layer (nearest NSView delegate up the superlayer chain), nil off the main thread or if none.
static id ggViewOf(CALayer *l) {
    if (![NSThread isMainThread]) return nil;
    Class nsview = NSClassFromString(@"NSView");
    for (int i = 0; l && i < 64; i++, l = l.superlayer) if (nsview && [l.delegate isKindOfClass:nsview]) return l.delegate;
    return nil;
}

typedef struct { int recipe; bool dark, inactive, entry; } GGState;

/// Picks the 27 recipe and state. false: unknown, keep the old code (the shader guesses).
static BOOL ggResolve(CALayer *l, GGFace face, GGState *out) {
    out->entry = NO;
    if (face.recipe == GG_R_CHICLET || face.recipe == GG_R_NOTIF) {   // NotificationCenter only (ggFaceOf)
        out->recipe = face.recipe; out->dark = face.dark; out->inactive = face.inactive;
        return YES;
    }
    id view = ggViewOf(l);
    id window = view ? ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("window")) : nil;
    int viewRecipe = -1;
    Class glassCls = NSClassFromString(@"NSGlassEffectView"), popCls = NSClassFromString(@"NSPopoverFrame"),
          fieldCls = NSClassFromString(@"NSTextField");
    BOOL sawGlass = NO;
    out->entry = NO;
    id owner = view ? ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("superview")) : nil;
    for (id v = view; v && viewRecipe < 0; v = ((id (*)(id, SEL))objc_msgSend)(v, sel_registerName("superview"))) {
        // Entry field glass (Aquaduck NSSearchField/NSTextField, DesignLibrary.MacEngineeringSearchField): 27 uses
        // RegularEntryFieldRecipe = regular + DisableBlur (YCC/backdropScale/blur fill go through a closure not yet
        // reverse-engineered, kept as regular).
        if (!sawGlass && fieldCls && [v isKindOfClass:fieldCls]) { out->entry = YES; break; }
        // The NSGlassEffectView recipe only applies to its own glass (layers owned by it or a direct subview), not to nested
        // child glass (search fields, glass buttons in a sidebar): 27 draws child glass with the element's own recipe.
        if (!sawGlass && glassCls && [v isKindOfClass:glassCls] && v != view && v != owner) break;
        if (!sawGlass && glassCls && [v isKindOfClass:glassCls]) {
            sawGlass = YES;
            long var = ((long (*)(id, SEL))objc_msgSend)(v, sel_registerName("_variant"));
            if (var >= 16 && var <= 18) viewRecipe = GG_R_SIDEBAR;   // floating / edge sidebar / inspector
            else if (var == 20) {                                    // popover with an arrow (26.6; 27 uses 21)
                for (id p = v; p; p = ((id (*)(id, SEL))objc_msgSend)(p, sel_registerName("superview")))
                    if (popCls && [p isKindOfClass:popCls]) { viewRecipe = GG_R_POPOVER; break; }
            }
        }
    }
    BOOL viewDark = NO, hasView = view != nil;
    if (hasView) {
        id app = ((id (*)(id, SEL))objc_msgSend)(view, sel_registerName("effectiveAppearance"));
        id m = [app respondsToSelector:sel_registerName("bestMatchFromAppearancesWithNames:")]
             ? ((id (*)(id, SEL, id))objc_msgSend)(app, sel_registerName("bestMatchFromAppearancesWithNames:"), @[@"NSAppearanceNameAqua", @"NSAppearanceNameDarkAqua"]) : nil;
        viewDark = [m isEqual:@"NSAppearanceNameDarkAqua"];
    }
    BOOL windowInactive = window && [window respondsToSelector:sel_registerName("_hasActiveAppearance")]
                        && !((BOOL (*)(id, SEL))objc_msgSend)(window, sel_registerName("_hasActiveAppearance"));
    if (viewRecipe >= 0) {
        out->recipe = viewRecipe; out->dark = viewDark;
        out->inactive = viewRecipe == GG_R_POPOVER && windowInactive;   // the 27 sidebar has no Spec level inactive
        return YES;
    }
    if (out->entry && window) {   // RegularEntryFieldRecipe builds on RegularBase: active/inactive per window like regular
        out->recipe = GG_R_REGULAR; out->inactive = windowInactive; out->dark = viewDark;
        return YES;
    }
    if (face.recipe >= 0) {
        out->recipe = face.recipe; out->inactive = face.inactive;
        out->dark = hasView ? viewDark : face.dark;
        return YES;
    }
    if (face.recipe == -1 && window) {   // adaptive glass: regular, state per window
        out->recipe = GG_R_REGULAR; out->inactive = windowInactive; out->dark = viewDark;
        return YES;
    }
    return NO;
}

// MARK: - Ghi

static int32_t ggFlagOf(id f) {
    int32_t p = [[f valueForKey:@"inputClampPreserveHue"] intValue], flag = 0;
    int r; bool i, d; float a;
    if (gg_recipe_decode(p, &r, &i, &d, &flag, &a)) return flag;
    if (gg_tint_decode(p, NULL, &flag)) return flag;
    return p > 0;
}

/// (key, value) pairs of the recipe; values are NSNumber or CGColor.
static NSDictionary *ggValues(GG27Params p, int32_t code) {
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGFloat fc[4] = {p.faceFill[0], p.faceFill[1], p.faceFill[2], p.faceFill[3]};
    CGColorRef fill = CGColorCreate(cs, fc);
    NSDictionary *d = @{
        @"inputFaceColorMatrixBlack": @(p.faceBlack), @"inputFaceColorMatrixWhite": @(p.faceWhite),
        @"inputFaceColorMatrixSaturation": @(p.faceSat), @"inputFaceColorMatrixFillColor": (__bridge id)fill,
        @"inputFaceOpacity": @1,
        @"inputBleedColorMatrixBlack": @(p.bleedBlack), @"inputBleedColorMatrixWhite": @(p.bleedWhite),
        @"inputBleedColorMatrixSaturation": @(p.bleedSat),
        @"inputBlurRadius": @(p.blurRadius),
        @"inputBlurOpacity0": @(p.blurOpacity[0]), @"inputBlurOpacity1": @(p.blurOpacity[1]),
        @"inputBlurOpacity2": @(p.blurOpacity[2]), @"inputBlurOpacity3": @(p.blurOpacity[3]),
        @"inputBlurDistance0": @(p.blurDistance[0]), @"inputBlurDistance1": @(p.blurDistance[1]),
        @"inputBlurDistance2": @(p.blurDistance[2]), @"inputBlurDistance3": @(p.blurDistance[3]),
        @"inputInnerRefractionAmount": @(p.innerAmount), @"inputInnerRefractionHeight": @(p.innerHeight),
        @"inputOuterRefractionAmount": @(p.outerAmount), @"inputOuterRefractionHeight": @(p.outerHeight),
        @"inputRefractionOpacity": @(p.refractionOpacity),
        @"inputBleedAmount": @(p.bleedAmount), @"inputBleedHeight": @(p.bleedHeight), @"inputBleedOpacity": @(p.bleedOpacity),
        @"inputShadowOpacity": @(p.shadowOpacity), @"inputShadowRadius": @(p.shadowRadius),
        @"inputClampPreserveHue": @(code),
    };
    CGColorRelease(fill); CGColorSpaceRelease(cs);
    if (p.shadowVibrancy > 0) {   // NotificationCenterRecipe.ShadowVibrancy; other recipes keep the 26.6 value
        NSMutableDictionary *m = [d mutableCopy];
        m[@"inputShadowVibrancyContribution"] = @(p.shadowVibrancy);
        d = m;
    }
    return d;
}

/// Pseudo key in the plan: CABackdropLayer.scale (not a filter key).
static NSString *const kScaleKey = @"GGBackdropScale";

static float ggShortSide(CALayer *l) { CGSize s = l.bounds.size; return (float)fmin(s.width, s.height); }

/// Glass covering several shapes with different short sides (CASDFElementLayers under the SDF layer that is the glass layer
/// delegate). The 26.6 Control Center module grid is one glass of 13 shapes with short sides 28/64/140; 27 has one glass per
/// module with its own short side. There is no single x to carry: writing the bounds x (292) makes refraction jump when
/// switching from the shader path (which measures x per cell from the SDF) to the app recipe. A single shape, or shapes with
/// the same short side (toolbar button groups), do not count.
static BOOL ggMixedElements(CALayer *l) {
    id root = l.delegate;
    Class el = NSClassFromString(@"CASDFElementLayer");
    if (!el || ![root isKindOfClass:[CALayer class]]) return NO;
    __block CGFloat lo = INFINITY, hi = 0;
    __block void (^walk)(CALayer *, int);
    __block __weak void (^weakWalk)(CALayer *, int);
    weakWalk = walk = ^(CALayer *p, int depth) {
        if (depth > 8) return;
        for (CALayer *s in p.sublayers) {
            if ([s isKindOfClass:el]) { CGFloat x = fmin(s.bounds.size.width, s.bounds.size.height); lo = fmin(lo, x); hi = fmax(hi, x); }
            weakWalk(s, depth + 1);
        }
    };
    walk(root, 0);
    return hi - lo > 1;
}

/// Computes the recipe and values for filter f on layer l; nil when nothing is written (keep the old code).
static NSDictionary *ggPlan(id f, CALayer *l, GGFace face, float a) {
    float x = ggShortSide(l);
    if (x < 1) return nil;   // before layout: bounds 0, rewritten once bounds exist (setBounds: hook)
    if (ggMixedElements(l)) return nil;
    GGState s;
    if (!ggResolve(l, face, &s)) return nil;
    bool nc = s.recipe == GG_R_CHICLET || s.recipe == GG_R_NOTIF;
    // Notification cards: surfaceSize(.medium) = recipe computed with short side 166; the "x" button (20..24 pt) has no
    // surfaceSize. Simplification: cards and buttons are told apart by a 40 pt threshold, other large regular glass in
    // NotificationCenter (if any) is also computed with 166.
    if (s.recipe == GG_R_NOTIF && x >= 40) x = 166;
    // Widgets/cards: the code's inactive bit carries subdued (the shader does not apply inactive to these two recipes).
    int32_t code = gg_recipe_encode(s.recipe, nc ? face.subdued : s.inactive, s.dark, ggFlagOf(f), a);
    GG27Params p = gg27_recipe_params(s.recipe, s.dark, s.inactive, a, x);
    if (s.recipe == GG_R_CHICLET && face.boost && !s.dark && !s.inactive) p.faceWhite = 1;   // flag 0x42000 (Modifier 0x195efe6f0)
    if (nc && face.subdued) gg27_subdued(&p, s.dark);
    // Like the shader's guessing path: enable the shadow only when 26.6 has one for this glass. Panels/menus (the window
    // draws the shadow) have 0 on 26.6; QuartzCore does not grow the drawing bounds for the recipe shadow, so the shadow is
    // clipped into a dark square-cornered area around the panel.
    if (!face.shadow) p.shadowOpacity = 0;
    if (s.entry) {   // RegularEntryFieldRecipe: DisableBlur 27 (0x195f1eb94) blurRadius constant(0), blur opacity 0, distances 0
        p.blurRadius = 0;
        for (int i = 0; i < 4; i++) p.blurOpacity[i] = p.blurDistance[i] = 0;
    }
    NSDictionary *v = ggValues(p, code);
    if (s.recipe == GG_R_CHICLET) {   // ChicletRecipe.Modifier, P branch: resolutionAdequacy
        float pl = 1 / (float)fmax(l.contentsScale, 1), fillOp = a > 0.5f ? 2 * (a - 0.5f) : 0;
        NSMutableDictionary *m = [v mutableCopy];
        m[kScaleKey] = @(gg27_backdrop_scale(p.blurRadius, p.faceFill[3], fillOp, pl));
        v = m;
    }
    return v;
}

/// Applies the plan to filter f of layer l (pseudo key kScaleKey becomes CABackdropLayer.scale).
static void ggApplyPlan(NSDictionary *v, id f, CALayer *l, NSString *keyPathPrefix) {
    [v enumerateKeysAndObjectsUsingBlock:^(NSString *k, id obj, BOOL *stop) {
        if ([k isEqual:kScaleKey]) [l setValue:obj forKey:@"scale"];
        else if (keyPathPrefix) [l setValue:obj forKeyPath:[keyPathPrefix stringByAppendingString:k]];
        else [f setValue:obj forKey:k];
    }];
    // 26.6 SwiftUI sizes CABackdropLayer.marginWidth to its own outer refraction (0.2 x; 9.6 on a notification card). The
    // backdrop is captured and drawn only within bounds + margin, so a larger 27 outer refraction (41.5 on a card) clips the
    // card shadow into a square-edged halo. Grow the margin to the written outer refraction, never shrink it.
    double outer = [v[@"inputOuterRefractionAmount"] doubleValue];
    if ([l respondsToSelector:NSSelectorFromString(@"marginWidth")] && [[l valueForKey:@"marginWidth"] doubleValue] < outer)
        [l setValue:@(outer) forKey:@"marginWidth"];
}

/// Only CAFilter has a type key: a CIFilter in layer.filters (Quick Look) throws NSUnknownKeyException on valueForKey:@"type".
static BOOL ggIsGlassFilter(id f) {
    static Class caFilter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ caFilter = NSClassFromString(@"CAFilter"); });
    return caFilter && [f isKindOfClass:caFilter] && [[f valueForKey:@"type"] isEqual:@"glassBackground"];
}

/// Whether the face on the filter is still the face the app wrote per plan v (26.6 has not changed it). v nil (no bounds yet): treated as unchanged.
static BOOL ggFaceUnchanged(id f, NSDictionary *v) {
    if (!v) return YES;
    for (NSString *k in @[@"inputFaceColorMatrixBlack", @"inputFaceColorMatrixWhite", @"inputFaceColorMatrixSaturation"])
        if (fabs(ggNum(f, k, NAN) - [v[k] doubleValue]) > 1e-4) return NO;
    return YES;
}

bool gg_recipe_apply(id f, CALayer *l, float a) {
    if (!ggEnabled() || !ggIsGlassFilter(f)) return false;
    // The filter already carries a recipe code (written earlier by the app, AppKit reassigned the same object): the face is
    // a 27 face, use the remembered face.
    GGFace face;
    int r; bool i, d; int32_t fl; float aa;
    BOOL ours = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &i, &d, &fl, &aa);
    // A new layer with no remembered identity whose filter already carries a code: take the identity from the code (the
    // 27 regular light face matches sidebar signature #17).
    // Shadow: the app only writes shadow > 0 when 26.6 already had one, so the current filter value tells us.
    // Widgets/cards: the inactive bit is subdued (boost and legacy widgets are not carried in the code).
    if (ours && !ggGetFace(l, &face)) {
        bool nc = r == GG_R_CHICLET || r == GG_R_NOTIF;
        face = (GGFace){r, d, nc ? false : i, 0, ggNum(f, @"inputShadowOpacity", 0) > 0, nc && i, false};
    }
    // The code remains but 26.6 changed the face on this same object (the Control Center show/hide animation reassigns the
    // same filter with an interpolated face): that is a new 26.6 face, do not overwrite it with the target values (the glass
    // cell would show at full strength for a moment before the animation runs).
    if (ours && !ggFaceUnchanged(f, ggPlan(f, l, face, a))) ours = NO;
    if (!ours) face = ggFaceOf(f);
    face.x = ggShortSide(l);
    ggSetFace(l, face);   // remember -2 too (26.6 animation frame): later rewrites (bounds, window) must not apply the old identity over it
    if (face.recipe == -2) return false;
    NSDictionary *v = ggPlan(f, l, face, a);
    if (!v) return false;
    ggApplyPlan(v, f, l, nil);
    return true;
}

/// Widget excludingPlatter layer: YCC matrix (black b, white 1, saturation s) with (b, s) = (0.6, 1.1) light / (0.7, 1.2) dark,
/// exactly the !P branch of ChicletRecipe.PostProcess (0x195efd650..0x195efd870). The 27 branch does not build this layer.
static BOOL ggIsWidgetForeground(const float *m) {
    const float L[3] = {0.2126f, 0.7152f, 0.0722f};
    for (int k = 0; k < 2; k++) {
        float b = k ? 0.7f : 0.6f, s = k ? 1.2f : 1.1f, c = 1 - b - s;
        BOOL ok = YES;
        for (int i = 0; i < 3 && ok; i++)
            for (int j = 0; j < 5 && ok; j++) {
                float want = j < 3 ? c * L[j] + (i == j ? s : 0) : j == 3 ? 0 : b;
                if (fabsf(m[i * 5 + j] - want) > 2e-3f) ok = NO;
            }
        const float alpha[5] = {0, 0, 0, 1, 0};
        for (int j = 0; j < 5 && ok; j++) if (fabsf(m[15 + j] - alpha[j]) > 1e-6f) ok = NO;
        if (ok) return YES;
    }
    return NO;
}

typedef struct CAColorMatrix { float m[20]; } CAColorMatrix;

bool gg_recipe_foreground(id f) {
    static Class caFilter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ caFilter = NSClassFromString(@"CAFilter"); });
    if (!ggEnabled() || !ggHostNC() || !caFilter || ![f isKindOfClass:caFilter] || ![[f valueForKey:@"type"] isEqual:@"vibrantColorMatrix"])
        return false;
    NSValue *v = [f valueForKey:@"inputColorMatrix"];
    if (![v isKindOfClass:[NSValue class]] || strcmp(v.objCType, @encode(CAColorMatrix)) != 0) return false;
    CAColorMatrix m;
    [v getValue:&m size:sizeof m];
    if (!ggIsWidgetForeground(m.m)) return false;
    m.m[18] = 0;   // alpha row (0, 0, 0, 0, 0): transparent layer
    [f setValue:[NSValue value:&m withObjCType:@encode(CAColorMatrix)] forKey:@"inputColorMatrix"];
    return true;
}

bool gg_recipe_recode(CALayer *l, float a) {
    if (!ggEnabled()) return false;
    GGFace face;
    if (!ggGetFace(l, &face)) return false;
    BOOL any = NO;
    for (id f in l.filters) {
        if (!ggIsGlassFilter(f)) continue;
        NSDictionary *v = ggPlan(f, l, face, a);
        if (!v) continue;
        NSString *name = [f valueForKey:@"name"] ?: @"glassBackground";
        ggApplyPlan(v, f, l, [NSString stringWithFormat:@"filters.%@.", name]);
        any = YES;
    }
    if (any) { face.x = ggShortSide(l); ggSetFace(l, face); }
    return any;
}

// MARK: - Rewrite when bounds or window change (recommit like 27)

static void ggRecodeTree(CALayer *l, int depth) {
    if (!l || depth > 64) return;
    gg_recipe_recode(l, gg_legibility_current());
    for (CALayer *s in l.sublayers) ggRecodeTree(s, depth + 1);
}

static void ggCommit(void (^work)(void)) {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    work();
    [CATransaction commit];
}

static IMP oBackdropSetBounds;
static void hBackdropSetBounds(CALayer *self, SEL _cmd, CGRect b) {
    IMP up = oBackdropSetBounds ?: class_getMethodImplementation([CALayer class], _cmd);
    ((void (*)(id, SEL, CGRect))up)(self, _cmd, b);
    GGFace face;
    if (!ggGetFace(self, &face) || fabsf(ggShortSide(self) - face.x) <= 0.5f) return;
    __weak CALayer *weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{   // outside the running layout pass
        CALayer *l = weak;
        GGFace f2;
        if (!l || !ggGetFace(l, &f2) || fabsf(ggShortSide(l) - f2.x) <= 0.5f) return;
        ggCommit(^{ gg_recipe_recode(l, gg_legibility_current()); });
    });
}

void gg_recipe_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!ggEnabled()) return;
        Class bl = NSClassFromString(@"CABackdropLayer");
        Method m = class_getInstanceMethod(bl, @selector(setBounds:));
        BOOL inherited = m && method_getImplementation(m) == class_getMethodImplementation([CALayer class], @selector(setBounds:));
        if (inherited) class_addMethod(bl, @selector(setBounds:), (IMP)hBackdropSetBounds, method_getTypeEncoding(m));
        else if (m) oBackdropSetBounds = method_setImplementation(m, (IMP)hBackdropSetBounds);
        // Window key/main change: adaptive glass and popovers change inactive (26.6 does not always reassign the filter).
        for (NSString *name in @[@"NSWindowDidBecomeKeyNotification", @"NSWindowDidResignKeyNotification",
                                 @"NSWindowDidBecomeMainNotification", @"NSWindowDidResignMainNotification"])
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) {
                id w = n.object;
                id cv = [w respondsToSelector:sel_registerName("contentView")] ? ((id (*)(id, SEL))objc_msgSend)(w, sel_registerName("contentView")) : nil;
                id frame = cv ? ((id (*)(id, SEL))objc_msgSend)(cv, sel_registerName("superview")) : nil;
                CALayer *root = (frame ?: cv) ? ((CALayer *(*)(id, SEL))objc_msgSend)(frame ?: cv, sel_registerName("layer")) : nil;
                if (root) ggCommit(^{ ggRecodeTree(root, 0); });
            }];
    });
}
