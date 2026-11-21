// macOS 27 style sidebars.
// Changes exactly the places 27 changed in AppKit, hooking by selector:
// 1. No more floating sidebars: 27 makes -[NSSplitViewItem wantsFloatingAppearance] (0x18ae9e200) and
//    -[NSSplitViewItem _hasFloatingAppearance] (0x18ae9e380) always return NO, the setter (0x18ae9e208) empty, and drops the
//    NSSplitViewItemSidebarDefaultsToFloatingAppearance key. 26.6 then builds edge glass by itself (_glassVariant 17).
// 2. Colored icons in key windows: 27 adds a windowIsActive parameter to
//    -[NSTintConfiguration _sidebarRowTintColorForSelectedRow:wantsSolarium:contentType:windowIsActive:] (0x18aa6d1b4),
//    -[NSImageCell _imageContentStyleInView:] calls it with contentType 1 and controlView.window._isKeyWindowIgnoringFocus.
//    26.6 lacks that parameter (unselected rows always labelColor): we store the controlView key state in a thread-local
//    in -[NSImageCell _vibrancyFilterForControlView:] (the only caller path, measured by backtrace) and return the 27 color.
// 3. Semibold text on selected rows: 27 -[NSTableCellView _updateFont] (0x18a4dddfc) switches the font to weight 0.3 when
//    the row is selected, and _updateSourceListAttributesInRowView: (0x18a4f6790) calls it again on every row update.
//    In 27 this branch is gated by NSTableCellViewForceStylingUpdates / apps linked against the 27 SDK [I]; here always on.
// 4. (GGApp.sidebarGlass, off by default) 27 SidebarRecipe glass parameters computed in-app like 27 does: Planar face,
//    edge bleed sat 1.5, outer refraction and shadow off; inactive same as active (27 has no inactive schema for sidebars).
//    The GGGlass shader must recognize this signature to draw kVariant 2, so it is not enabled by default yet.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
BOOL ggSettingDefault(NSString *key, BOOL def);
void ggLog(NSString *fmt, ...);
void gg_sidebar_swiftui_install(void);
void gg_search_glass_install(void);
void gg_sidebar_uikit_install(void);

// ---- 1. not floating ----
static BOOL retNO(id self, SEL _cmd) { return NO; }
static void setIgnored(id self, SEL _cmd, BOOL v) {}

// ---- 2. icon color ----
static __thread int tlsKey = -1;   // key state of the window holding the image cell being colored, -1 = unknown
static IMP oVibrancy, oRowTint;

static id hVibrancy(id self, SEL _cmd, NSView *view) {
    int prev = tlsKey;
    NSWindow *w = view.window;
    tlsKey = w ? ((BOOL (*)(id, SEL))objc_msgSend)(w, sel_registerName("_isKeyWindowIgnoringFocus")) : -1;
    id r = ((id (*)(id, SEL, id))oVibrancy)(self, _cmd, view);
    tlsKey = prev;
    return r;
}

static NSColor *dynAlpha1(NSColor *c) { return ((NSColor *(*)(id, SEL, CGFloat))objc_msgSend)(c, sel_registerName("_colorWithDynamicAlphaComponent:"), 1.0); }

/// Solarium branch of the 27 version (selection not considered): text (contentType 0) always labelColor (26.6 tints selected
/// row text with the accent color, visible in inactive windows); images (contentType 1) in key windows -> type 0
/// controlAccentColor, 1 systemGray, 2 custom color, non-key -> labelColor. Outside Solarium, or images with unknown key
/// state: keep the 26.6 version.
static id hRowTint(id self, SEL _cmd, BOOL selected, BOOL solarium, long contentType) {
    if (solarium && contentType == 0) return dynAlpha1(NSColor.labelColor);
    if (!solarium || contentType != 1 || tlsKey < 0)
        return ((id (*)(id, SEL, BOOL, BOOL, long))oRowTint)(self, _cmd, selected, solarium, contentType);
    if (!tlsKey) return dynAlpha1(NSColor.labelColor);
    switch (((long (*)(id, SEL))objc_msgSend)(self, sel_registerName("_type"))) {
        case 0: return NSColor.controlAccentColor;
        case 1: return dynAlpha1(NSColor.systemGrayColor);
        case 2: return ((id (*)(id, SEL))objc_msgSend)(self, sel_registerName("_tintColor"));
        default: return nil;
    }
}

// ---- 3. semibold selected row text ----
static IMP oSourceListAttrs;

static void sidebarFont(NSTableCellView *cell, NSTableRowView *row) {
    if (!((BOOL (*)(id, SEL))objc_msgSend)(cell, sel_registerName("_hasSolariumAppearance"))) return;
    if (cell.rowSizeStyle < NSTableViewRowSizeStyleSmall || cell.rowSizeStyle > NSTableViewRowSizeStyleLarge) return;   // 27: standard row sizes only
    NSTextField *tf = ((NSTextField *(*)(id, SEL))objc_msgSend)(cell, sel_registerName("_textFieldForStyling")) ?: cell.textField;
    if (!tf || tf.currentEditor) return;
    ((void (*)(id, SEL))objc_msgSend)(cell, sel_registerName("_updateFont"));   // sidebar font per row size (as in 26.6)
    if (!row.isSelected || !tf.font) return;
    NSFontDescriptor *d = [tf.font.fontDescriptor fontDescriptorByAddingAttributes:@{NSFontTraitsAttribute: @{NSFontWeightTrait: @(NSFontWeightSemibold)}}];
    tf.font = [NSFont fontWithDescriptor:d size:tf.font.pointSize] ?: tf.font;
}

static void hSourceListAttrs(NSTableCellView *self, SEL _cmd, NSTableRowView *row) {
    ((void (*)(id, SEL, id))oSourceListAttrs)(self, _cmd, row);
    sidebarFont(self, row);
}

// ---- 4. 27 SidebarRecipe glass parameters ----
@interface CAFilter : NSObject
@property (readonly) NSString *type;
@end

/// Does an AppKit 26.6 sidebar/inspector glass (NSGlassEffectView _variant 16 floating, 17 edge, 18 inspector) contain layer l?
/// Returns the glass view to read the appearance from, nil otherwise.
static NSView *sidebarGlassOf(CALayer *l) {
    for (CALayer *p = l; p; p = p.superlayer) {
        if (![p.delegate isKindOfClass:[NSView class]]) continue;
        for (NSView *v = (NSView *)p.delegate; v; v = v.superview) {
            if ([v isKindOfClass:NSClassFromString(@"NSGlassEffectView")]) {
                long var = ((long (*)(id, SEL))objc_msgSend)(v, sel_registerName("_variant"));
                return var >= 16 && var <= 18 ? v : nil;
            }
        }
        return nil;
    }
    return nil;
}

static void applySidebarRecipe(CAFilter *f, BOOL dark) {
    // SidebarRecipe.FaceEffect (0x195f2cf7c), Planar (0x195f2c24c).
    [f setValue:@(dark ? 0.1 : 0.4) forKey:@"inputFaceColorMatrixBlack"];
    [f setValue:@(dark ? 0.5 : 1.03) forKey:@"inputFaceColorMatrixWhite"];
    [f setValue:@(dark ? 0.6 : 1.2) forKey:@"inputFaceColorMatrixSaturation"];
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedSRGB);
    CGFloat fill[4] = {dark ? 0 : 1, dark ? 0 : 1, dark ? 0 : 1, dark ? 0 : 0.2};
    CGColorRef c = CGColorCreate(cs, fill);
    [f setValue:(__bridge id)c forKey:@"inputFaceColorMatrixFillColor"];
    CGColorRelease(c); CGColorSpaceRelease(cs);
    [f setValue:@(dark ? 0.1 : 0.75) forKey:@"inputBleedColorMatrixBlack"];
    [f setValue:@(dark ? 0.5 : 0.9) forKey:@"inputBleedColorMatrixWhite"];
    [f setValue:@1.5 forKey:@"inputBleedColorMatrixSaturation"];
    [f setValue:@0 forKey:@"inputRefractionOpacity"];
    [f setValue:@0 forKey:@"inputShadowOpacity"];
}

static IMP oBackdropSetFilters;   // NULL: CABackdropLayer inherits CALayer setFilters:, call the superclass at runtime

static void hBackdropSetFilters(CALayer *self, SEL _cmd, NSArray *filters) {
    for (CAFilter *f in filters) {
        if (![f isKindOfClass:NSClassFromString(@"CAFilter")] || ![f.type isEqualToString:@"glassBackground"]) continue;
        NSView *g = sidebarGlassOf(self);
        if (g) applySidebarRecipe(f, [g.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua);
    }
    // Look up the CALayer IMP at runtime, not cached: GGLegibility replaces CALayer setFilters: after us (loads later)
    // and must still be called.
    IMP up = oBackdropSetFilters ?: class_getMethodImplementation([CALayer class], _cmd);
    ((void (*)(id, SEL, id))up)(self, _cmd, filters);
}

/// Glass search field like App Store 27. App Store 26.6 has its own NSSearchField subclass that only overrides
/// searchTextBounds; the Aquaduck provider (26.6 0x7ff8071dbde1, 27 0x18b649ea8) calls
/// _NSSubclassOverridesAnyOfTheseSelectors with [searchButtonBounds, searchTextBounds, cancelButtonBounds] (27 adds drawRect:),
/// and on an override draws the field with a context, without glass. App Store 27 drops this subclass (the 27 binary no
/// longer has searchTextBounds), so the field is a plain NSSearchField with glass. Same as App Store 27: subclasses in the
/// executable get these getters' IMPs reset to the NSSearchField IMPs. App Store only (the only 26.6 system app with the
/// override, checked across /System/Applications); other apps on 27 still behave like 26.6.
/// GG_SEARCH27=1: applies to the test app (tests/app.sh searchfield).
/// The App Store sidebar has no scroll view so the field has no pocket; 26.6 needs a pocket to pick glass, 27 does not:
/// gg_search_glass_install (SidebarIcon.m) patches that condition in DesignLibrary.
static int ggSearchFieldsLike27(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.AppStore"] && !getenv("GG_SEARCH27")) return -1;
    gg_search_glass_install();
    const char *exe = NULL;
    for (uint32_t i = 0; i < _dyld_image_count() && !exe; i++)
        if (((const struct mach_header *)_dyld_get_image_header(i))->filetype == MH_EXECUTE) exe = _dyld_get_image_name(i);
    if (!exe) return 0;
    Class base = NSClassFromString(@"NSSearchField");
    SEL sels[] = {sel_registerName("searchTextBounds"), sel_registerName("searchButtonBounds"), sel_registerName("cancelButtonBounds")};
    unsigned n = 0, changed = 0;
    const char **names = objc_copyClassNamesForImage(exe, &n);
    for (unsigned i = 0; i < n; i++) {
        Class c = objc_getClass(names[i]);
        if (!c || c == base || ![c isSubclassOfClass:base]) continue;
        unsigned mc = 0;
        Method *ms = class_copyMethodList(c, &mc);   // only methods declared in this class itself
        for (unsigned j = 0; j < mc; j++)
            for (int k = 0; k < 3; k++)
                if (method_getName(ms[j]) == sels[k]) {
                    method_setImplementation(ms[j], method_getImplementation(class_getInstanceMethod(base, sels[k])));
                    changed++;
                }
        free(ms);
    }
    free(names);
    return changed;
}

void gg_sidebar_install(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    Class item = NSClassFromString(@"NSSplitViewItem");
    IMP o;
    BOOL a = ggSwizzle(item, sel_registerName("wantsFloatingAppearance"), (IMP)retNO, &o)
          && ggSwizzle(item, sel_registerName("_hasFloatingAppearance"), (IMP)retNO, &o)
          && ggSwizzle(item, sel_registerName("setWantsFloatingAppearance:"), (IMP)setIgnored, &o);
    BOOL b = ggSwizzle(NSClassFromString(@"NSImageCell"), sel_registerName("_vibrancyFilterForControlView:"), (IMP)hVibrancy, &oVibrancy)
          && ggSwizzle(NSClassFromString(@"NSTintConfiguration"), sel_registerName("_sidebarRowTintColorForSelectedRow:wantsSolarium:contentType:"), (IMP)hRowTint, &oRowTint);
    BOOL c = ggSwizzle(NSClassFromString(@"NSTableCellView"), sel_registerName("_updateSourceListAttributesInRowView:"), (IMP)hSourceListAttrs, &oSourceListAttrs);
    BOOL d = NO;
    if (ggSettingDefault(@"GGApp.sidebarGlass", NO)) {
        Class bl = NSClassFromString(@"CABackdropLayer");
        Method m = class_getInstanceMethod(bl, @selector(setFilters:));
        BOOL inherited = m && method_getImplementation(m) == class_getMethodImplementation([CALayer class], @selector(setFilters:));
        if (inherited) d = class_addMethod(bl, @selector(setFilters:), (IMP)hBackdropSetFilters, method_getTypeEncoding(m));
        else d = ggSwizzle(bl, @selector(setFilters:), (IMP)hBackdropSetFilters, &oBackdropSetFilters);
    }
    ggLog(@"sidebar: not floating %d, icon color %d, semibold text %d, SidebarRecipe glass %d, search field like 27 %d", a, b, c, d, ggSearchFieldsLike27());
    gg_sidebar_swiftui_install();   // 27 style SwiftUI List(.sidebar) icons (SidebarIcon.m)
    if (ggSettingDefault(@"GGApp.sidebarCatalyst", YES)) gg_sidebar_uikit_install();   // edge Catalyst sidebars like 27 (SidebarUIKit.m)
}
