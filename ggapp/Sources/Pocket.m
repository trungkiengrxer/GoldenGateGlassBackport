// 27 style scroll pocket. Hooks by selector, runs after the original layout so AppKit does not overwrite our layers.
// Top edge only.
// Recipe choice (27: function 0x18b45aa9c, called from 0x18b47c6b8):
// - hard style (setScrollPocketStyle 2) -> HardPocket.
// - pocket over glass (scroll view in a sidebar) -> ThinFilmPocket(isOverGlass: true).
// - title text on the toolbar (27: NSToolbarTitleStackView, element style 0, flag B) -> ThinFilmPocket; Photos 27 shows
//   this milky band under its titled toolbar.
// - otherwise (content scroll view) -> ConditionalPocketRecipe(base: ThinFilmPocket): in a key window with the mouse not
//   over the bar every layer has alpha 0 (fully transparent, no divider); hover or a non-key window -> ThinFilm.
// - titlebar pocket: Clear when a scroll view pocket covers it, ThinFilm with a toolbar title, otherwise Hard.
// 27 ThinFilm (0x18b45e6d8, NSScrollPocketThinFilmUsesBlurFill branch, on by default) covers exactly the bar height without
// spilling into the content: below is ContentBlurFill (variableBlur r 2-2.5 + blur-fill r 16 darken/lighten/normal, scale
// 0.5, sat 1.25, +0.03), above is BackgroundReplay (uniform background replay 0.5 light / 0.6 dark, blur 16 scale 0.25,
// compensating sat). Blur-fill (inputBlurFill*) is a new variableBlur parameter in QuartzCore 27 that 26.6 lacks: rebuilt
// with three CABackdropLayers in one group (gaussianBlur 16 + darkenBlendMode / lightenBlendMode / normal).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
void ggLog(NSString *fmt, ...);

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
@end

static IMP oPocketLayout;
static NSHashTable *gPockets;
static char kFilm, kHover, kHard, kCapture, kRecipe;

// Clear: the titlebar pocket when the window has a scroll view pocket covering the same area (26.6 draws two pockets
// on top of each other, 27 only one).
typedef NS_ENUM(NSInteger, GGRecipe) { GGRecipeNone, GGRecipeHard, GGRecipeThinFilm, GGRecipeConditional, GGRecipeThinFilmOverGlass, GGRecipeClear };

static CAFilter *blur(CGFloat r) {
    CAFilter *f = [CAFilter filterWithType:@"gaussianBlur"];
    [f setValue:@(r) forKey:@"inputRadius"];
    [f setValue:@YES forKey:@"inputNormalizeEdges"];
    return f;
}

/// PocketLayer matrix (27: 0x18b464224): saturation s (keeps BT.709 Y, scales Cb/Cr) then shifts Y by
/// blackPoint b / whitePoint 1 + b (adds b to every channel).
static CAFilter *saturate(float s, float bias) {
    const float L[3] = {0.2126f, 0.7152f, 0.0722f};
    float m[20] = {0};
    for (int i = 0; i < 3; i++) {
        for (int j = 0; j < 3; j++) m[i * 5 + j] = (1 - s) * L[j] + (i == j ? s : 0);
        m[i * 5 + 4] = bias;
    }
    m[18] = 1;
    CAFilter *f = [CAFilter filterWithType:@"colorMatrix"];
    [f setValue:[NSValue valueWithBytes:m objCType:"{CAColorMatrix=ffffffffffffffffffff}"] forKey:@"inputColorMatrix"];
    return f;
}

static CALayer *backdropLayer(NSString *name) {
    CALayer *l = [NSClassFromString(@"CABackdropLayer") layer];
    l.name = name;
    return l;
}

/// Layer-hosting view: we own the root layer so AppKit does not remove sublayers (sublayers inserted directly into the
/// NSScrollPocket layer are lost after layout). Does not take the mouse.
@interface GGBackdropView : NSView
@end
@implementation GGBackdropView
- (NSView *)hitTest:(NSPoint)p { return nil; }
@end

static GGBackdropView *hostView(CALayer *root) {
    GGBackdropView *v = [[GGBackdropView alloc] initWithFrame:NSZeroRect];
    v.layer = root;
    v.wantsLayer = YES;
    return v;
}

static BOOL isDark(NSView *v) {
    return [[v.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
}

static NSInteger intIvar(id o, const char *name, NSInteger dflt) {
    Ivar iv = class_getInstanceVariable(object_getClass(o), name);
    return iv ? *(NSInteger *)((char *)(__bridge void *)o + ivar_getOffset(iv)) : dflt;
}

// ---- state (27: PocketRecipeState isInKeyWindow, isHovered, isScrolledFromEdge) ----

/// Tracks the mouse over the bar (27: NSScrollPocket rolloverInteraction).
@interface GGHover : NSObject
@property (weak) NSView *pocket;
@property BOOL inside;
@end
@implementation GGHover
- (void)mouseEntered:(NSEvent *)e { self.inside = YES; self.pocket.needsLayout = YES; }
- (void)mouseExited:(NSEvent *)e { self.inside = NO; self.pocket.needsLayout = YES; }
@end

static BOOL hovered(NSView *p) {
    GGHover *h = objc_getAssociatedObject(p, &kHover);
    if (!h) {
        h = [GGHover new];
        h.pocket = p;
        objc_setAssociatedObject(p, &kHover, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [p addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:h userInfo:nil]];
    }
    return h.inside;
}

static BOOL scrolledFromEdge(NSView *p) {
    NSScrollView *s = [p.superview isKindOfClass:NSScrollView.class] ? (NSScrollView *)p.superview : nil;
    if (!s) return YES;   // titlebar pocket: the content below is unknown, treat as scrolled
    NSView *doc = s.documentView;
    NSRect vis = s.documentVisibleRect;
    return doc.isFlipped ? NSMinY(vis) > NSMinY(doc.bounds) + 0.5 : NSMaxY(vis) < NSMaxY(doc.bounds) - 0.5;
}

static BOOL overGlass(NSView *p) {
    for (NSView *v = p.superview; v; v = v.superview)
        if ([v isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) return YES;
    return NO;
}

/// Free title text inside the pocket area (WWDC26 289: automatic becomes hard when title text floats over the content).
static BOOL titleOver(NSView *p) {
    NSWindow *w = p.window;
    return w.titleVisibility == NSWindowTitleVisible && w.title.length > 0 && w.toolbar && w.toolbar.isVisible;
}

/// Whether a scroll view top edge pocket covers more than half the width of area `r` (window coordinates).
static BOOL scrollPocketCovers(NSView *v, NSRect r) {
    if ([NSStringFromClass(v.class) isEqualToString:@"NSScrollPocket"] && [v.superview isKindOfClass:NSScrollView.class] && intIvar(v, "edge", -1) == 0
        && NSWidth(NSIntersectionRect(NSInsetRect([v convertRect:v.bounds toView:nil], 0, -1), r)) > NSWidth(r) / 2) return YES;
    for (NSView *s in v.subviews) if (scrollPocketCovers(s, r)) return YES;
    return NO;
}

static GGRecipe recipeFor(NSView *p) {
    if (intIvar(p, "edge", -1) != 0) return GGRecipeNone;   // NSScrollPocketEdge: top edge only (0 = top, measured in a test app)
    BOOL titlebar = ![p.superview isKindOfClass:NSScrollView.class];   // NSTitlebarBackgroundView, 26.6 sets style 2
    if (titlebar) {
        if (scrollPocketCovers(p.window.contentView, [p convertRect:p.bounds toView:nil])) return GGRecipeClear;
        // Same tree as a scroll view pocket: title -> ThinFilm, an untitled toolbar -> Conditional (a key window shows no
        // bar over content that is not scrolling, e.g. App Store while a page loads), no toolbar -> Hard.
        if (titleOver(p)) return GGRecipeThinFilm;
        return p.window.toolbar.isVisible ? GGRecipeConditional : GGRecipeHard;
    }
    if (overGlass(p)) return GGRecipeThinFilmOverGlass;
    if (intIvar(p, "style", 0) == 2) return GGRecipeHard;
    return titleOver(p) ? GGRecipeThinFilm : GGRecipeConditional;
}

// ---- ThinFilm ----

static NSString *const kNames[] = {@"ThinFilmContentBlurFill", @"ThinFilmFillDarken", @"ThinFilmFillLighten", @"ThinFilmFillNormal", @"ThinFilmBackgroundReplay", @"Separator"};
enum { LBlur, LDarken, LLighten, LNormal, LReplay, LSep, LCount };

static GGBackdropView *buildFilm(NSView *p) {
    CALayer *root = [CALayer layer];
    root.name = @"GGThinFilm";
    NSString *group = [NSString stringWithFormat:@"ggFill-%p", p];
    for (int i = 0; i < LCount; i++) {
        CALayer *l = i == LSep ? [CALayer layer] : backdropLayer(kNames[i]);
        l.name = kNames[i];
        if (i == LDarken) l.compositingFilter = @"darkenBlendMode";
        if (i == LLighten) l.compositingFilter = @"lightenBlendMode";
        if (i >= LDarken && i <= LNormal) [l setValue:group forKey:@"groupName"];   // one capture for all three fill layers
        [root addSublayer:l];
    }
    return hostView(root);
}

/// Our own background capture for a pocket, returning its group name: a captureOnly CABackdropLayer over the pocket's
/// area, under the content (below NSClipView for a scroll view, below the pocket for a titlebar), so replay layers in
/// the group show the real background (whatever the app paints) without the scrolled document, like 27
/// BackgroundReplay. 26.6 has its own capture (captureView, backgroundGroup-<ptr>) but keeps it disabled
/// (`enabled = 0`) while it draws a hard pocket, and a group member only replays when its scale equals the capture's
/// (measured: member at another scale shows nothing), so the capture takes the replay layer's scale.
static NSString *captureGroup(NSView *p, CGFloat scale) {
    NSString *g = [NSString stringWithFormat:@"ggPocketBackground-%p", p];
    GGBackdropView *c = objc_getAssociatedObject(p, &kCapture);
    if (!c) {
        CALayer *l = backdropLayer(@"GGPocketCapture");
        [l setValue:@YES forKey:@"captureOnly"];
        [l setValue:g forKey:@"groupName"];
        c = hostView(l);
        objc_setAssociatedObject(p, &kCapture, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSScrollView *s = [p.superview isKindOfClass:NSScrollView.class] ? (NSScrollView *)p.superview : nil;
    NSView *parent = s ?: p.superview, *above = s ? s.contentView : p;
    NSArray *subs = parent.subviews;
    if (c.superview != parent || [subs indexOfObject:c] > [subs indexOfObject:above])
        [parent addSubview:c positioned:NSWindowBelow relativeTo:above];
    c.hidden = NO;
    c.frame = [parent convertRect:p.bounds fromView:p];
    [c.layer setValue:@(scale) forKey:@"scale"];
    return g;
}

static void layoutFilm(NSView *p, GGRecipe r) {
    GGBackdropView *film = objc_getAssociatedObject(p, &kFilm);
    if (!film) {
        film = buildFilm(p);
        [p addSubview:film positioned:NSWindowAbove relativeTo:nil];
        objc_setAssociatedObject(p, &kFilm, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL glass = r == GGRecipeThinFilmOverGlass, dark = isDark(p), key = p.window.isKeyWindow;
    BOOL hover = hovered(p), scrolled = scrolledFromEdge(p);
    // Conditional (0x18b460b1c): key and not hovered -> every layer mask uniform 0, blur 0, no divider.
    BOOL visible = r != GGRecipeConditional || hover || !key;
    BOOL edge = scrolled || hover || !key;                        // w24: divider shown, bias +0.03
    float bias = edge && !glass ? 0.03f : 0;
    float sat = glass ? 1.0f : 1.25f;
    float replayAlpha = dark ? 0.6f : 0.5f;
    float replaySat = MAX(0, sat - (sat - 1) / replayAlpha);
    CGFloat h = p.bounds.size.height;
    CGFloat radius = 2 + 0.5 * MIN(MAX((h - 52) / 38, 0), 1);   // 0x18b45efd0: 2 + 0.5·clamp((d10 - 52)/38)
    CGFloat replayScale = glass ? 1.0 : 0.25;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    film.hidden = NO;
    film.frame = NSMakeRect(0, -0.5, p.bounds.size.width, h + 0.5);   // bottom 0.5 pt for the divider
    NSArray<CALayer *> *ls = film.layer.sublayers;
    NSRect bar = NSMakeRect(0, 0.5, p.bounds.size.width, h);
    for (CALayer *l in ls) l.frame = bar;
    // Simplification: uniform background blur r 2-2.5 instead of variableBlur with mask 0.25 (0.4 with floating elements) -> 1.0
    // over the ramp; difference < 2 pt radius, add the mask if it looks off.
    [ls[LBlur] setValue:@0.5 forKey:@"scale"];
    ls[LBlur].filters = @[blur(radius), saturate(sat, bias)];
    for (int i = LDarken; i <= LNormal; i++) {
        [ls[i] setValue:@0.5 forKey:@"scale"];
        ls[i].filters = @[blur(16), saturate(sat, bias)];
    }
    [ls[LReplay] setValue:captureGroup(p, replayScale) forKey:@"groupName"];
    [ls[LReplay] setValue:@(replayScale) forKey:@"scale"];
    ls[LReplay].filters = glass ? @[saturate(replaySat, 0)] : @[blur(16), saturate(replaySat, 0)];
    ls[LSep].frame = NSMakeRect(0, 0, p.bounds.size.width, 0.5);
    ls[LSep].backgroundColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.07 : 0.1].CGColor;
    [CATransaction commit];

    // State-driven opacity changes use the implicit CA animation (0.25 s) like 27 recipe transitions.
    ls[LBlur].opacity = visible;
    ls[LDarken].opacity = visible ? (dark ? 0.6f : 0.4f) : 0;
    ls[LLighten].opacity = visible ? (dark ? 0.4f : 0.6f) : 0;
    ls[LNormal].opacity = visible ? (dark ? 0 : 0.25f) : 0;
    ls[LReplay].opacity = visible ? replayAlpha : 0;
    ls[LSep].opacity = visible && edge;
}

// ---- HardPocket (27: 0x18b45f850) ----
// ContentBlur: scale 0.25, gaussianBlur 6, sat 1.25 when key (PocketUsesContentSaturationBoost) / 1.0, +0.03.
// BackgroundReplay: scale 1, alpha 0.85·(1 - 0.03) = 0.8245, compensating sat. Divider 0.5 pt black 10% / white 7%.
// Drawn by our own layers rather than by adjusting NSHardPocketView: 26.6 sometimes draws a pocket soft (Notes editor)
// even when 27 would pick Hard, and NSHardPocketView is then hidden.

static NSString *const kHardNames[] = {@"HardPocketContentBlur", @"HardPocketBackgroundReplay", @"Separator"};
enum { HBlur, HReplay, HSep, HCount };

static void layoutHard(NSView *p) {
    GGBackdropView *v = objc_getAssociatedObject(p, &kHard);
    if (!v) {
        CALayer *root = [CALayer layer];
        root.name = @"GGHardPocket";
        for (int i = 0; i < HCount; i++) {
            CALayer *l = i == HSep ? [CALayer layer] : backdropLayer(kHardNames[i]);
            l.name = kHardNames[i];
            [root addSublayer:l];
        }
        v = hostView(root);
        [p addSubview:v positioned:NSWindowAbove relativeTo:nil];
        objc_setAssociatedObject(p, &kHard, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL dark = isDark(p);
    float sat = p.window.isKeyWindow ? 1.25f : 1.0f, alpha = 0.85f * (1 - 0.03f);
    CGFloat w = p.bounds.size.width, h = p.bounds.size.height;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    v.hidden = NO;
    v.frame = NSMakeRect(0, -0.5, w, h + 0.5);   // bottom 0.5 pt for the divider
    NSArray<CALayer *> *ls = v.layer.sublayers;
    for (CALayer *l in ls) l.frame = NSMakeRect(0, 0.5, w, h);
    [ls[HBlur] setValue:@0.25 forKey:@"scale"];
    ls[HBlur].filters = @[blur(6), saturate(sat, 0.03f)];
    [ls[HReplay] setValue:captureGroup(p, 1.0) forKey:@"groupName"];
    [ls[HReplay] setValue:@1.0 forKey:@"scale"];
    ls[HReplay].filters = @[saturate(MAX(0, sat - (sat - 1) / alpha), 0.03f)];
    ls[HReplay].opacity = alpha;
    ls[HSep].frame = NSMakeRect(0, 0, w, 0.5);
    ls[HSep].backgroundColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.07 : 0.1].CGColor;
    [CATransaction commit];
}

/// Hides the 26.6 drawing (PocketBlur, NSHardPocketView, LuminanceAdjustment, AdditionalDimming) via alphaValue so
/// `hidden` stays under AppKit's control; the background capture layer (BackdropView) stays because the replay group needs it.
static void hide26(NSView *p, BOOL hide) {
    for (NSView *s in p.subviews) {
        NSString *c = NSStringFromClass(s.class), *n = s.layer.name ?: @"";
        if ([c containsString:@"PocketBlur"] || [c containsString:@"NSHardPocketView"] || [c containsString:@"LuminanceAdjustment"]
            || [n containsString:@"AdditionalDimming"] || [n isEqualToString:@"PocketBlur"] || [n isEqualToString:@"LuminanceAdjustment"])
            s.alphaValue = hide ? 0 : 1;
    }
}

static void hPocketLayout(NSView *self, SEL _cmd) {
    ((void (*)(id, SEL))oPocketLayout)(self, _cmd);
    GGRecipe r = recipeFor(self);
    if ([objc_getAssociatedObject(self, &kRecipe) integerValue] != r || !objc_getAssociatedObject(self, &kRecipe))
        ggLog(@"pocket %p in %@ %@: edge %ld style %ld -> recipe %ld", self, NSStringFromClass(self.superview.class), NSStringFromRect(self.frame),
              (long)intIvar(self, "edge", -1), (long)intIvar(self, "style", -1), (long)r);
    objc_setAssociatedObject(self, &kRecipe, @(r), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [gPockets addObject:self];
    BOOL thin = r == GGRecipeConditional || r == GGRecipeThinFilm || r == GGRecipeThinFilmOverGlass;
    hide26(self, r != GGRecipeNone);   // every recipe of ours replaces the 26.6 drawing, whichever one 26.6 picked
    ((NSView *)objc_getAssociatedObject(self, &kFilm)).hidden = !thin;
    ((NSView *)objc_getAssociatedObject(self, &kHard)).hidden = r != GGRecipeHard;
    ((NSView *)objc_getAssociatedObject(self, &kCapture)).hidden = !thin && r != GGRecipeHard;
    if (thin) layoutFilm(self, r);
    else if (r == GGRecipeHard) layoutHard(self);
}

static void relayout(NSWindow *w) {
    for (NSView *p in gPockets.allObjects) if (!w || p.window == w) p.needsLayout = YES;
}

/// Pocket summary of a window for tests and logs: "recipe|layer:opacity,...".
const char *gg_pocket_debug(void) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSView *p in gPockets.allObjects) {
        if (!p.window) continue;
        NSMutableArray *ls = [NSMutableArray array];
        for (NSView *host in @[objc_getAssociatedObject(p, &kFilm) ?: NSNull.null, objc_getAssociatedObject(p, &kHard) ?: NSNull.null]) {
            if ([host isKindOfClass:NSNull.class] || host.hidden) continue;
            for (CALayer *l in host.layer.sublayers)
                [ls addObject:[NSString stringWithFormat:@"%@:%.4g:%@", l.name, l.opacity,
                               [l respondsToSelector:NSSelectorFromString(@"scale")] ? [l valueForKey:@"scale"] : @"-"]];
        }
        [out addObject:[NSString stringWithFormat:@"%p %@ %@ %@|%@", p, NSStringFromClass(p.superview.class),
                        objc_getAssociatedObject(p, &kRecipe), NSStringFromRect(p.frame), [ls componentsJoinedByString:@","]]];
    }
    static char buf[8192];
    strlcpy(buf, [out componentsJoinedByString:@"\n"].UTF8String ?: "", sizeof buf);
    return buf;
}

void gg_pocket_install(void) {
    if (gPockets) return;
    gPockets = [NSHashTable weakObjectsHashTable];
    BOOL a = ggSwizzle(NSClassFromString(@"NSScrollPocket"), @selector(layout), (IMP)hPocketLayout, &oPocketLayout);
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSString *name in @[NSWindowDidBecomeKeyNotification, NSWindowDidResignKeyNotification])
        [nc addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) { relayout(n.object); }];
    // Scrolling away from the edge changes the divider and bias; AppKit does not re-layout the pocket on every scroll.
    [nc addObserverForName:NSViewBoundsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        NSView *clip = n.object;
        if (![clip isKindOfClass:NSClipView.class]) return;
        for (NSView *p in gPockets.allObjects) if (p.superview == clip.superview) p.needsLayout = YES;
    }];
    ggLog(@"pocket: NSScrollPocket %@", a ? @"hooked" : @"not hooked");
}
