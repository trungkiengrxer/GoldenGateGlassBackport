// Catalyst sidebars (UIKit in Mac Catalyst apps: Podcasts, Books, News, Stocks, Home) like macOS 27.
// UIKit draws the sidebar itself, not through NSSplitViewItem. Three places where 27 differs from 26.6:
//
// 1. Tab sidebar (UITabBarController, Podcasts): 27 -[_UIFloatingTabBarPlatformMetrics_GlassMac init] (0x1ac351f6c, selector
//    names resolved from objc_msgSend$ stubs) calls setSupportsFloatingSidebar:NO; 26.6 sets YES. The other setters of this
//    function already match 27 on 26.6 (setSidebarBackgroundProvider:, setPrefersTrailingSidebarButton: exist only in 27).
//    When not floating, -[_UITabOutlineView _updateSidebarStyle] (27 0x1ac98c5bc, same branch on 26.6) sets the
//    abuttedBackground (_UIViewGlass variant 10) and border 0; the content layout stays overlap in both versions
//    (-[UITabBarControllerSidebar _resolvedLayout]: Mac + Solarium -> overlap), so content runs under the sidebar glass like 27.
//
// 2. Sidebar metrics (_UISidebarPlatformMetrics, also used by Books' UISplitViewController): UIKitCore 27 removes the
//    _Floating and _Floating_Mac classes; 27 base class -init (0x1ac4e6e34) sets fallbackCornerRadius 0, platterInsets 0,
//    floatingBackground = _UIViewGlass variant 9 (flexible), abuttedBackground = variant 10. 26.6 sets both backgrounds in
//    -[_UISidebarPlatformMetrics_Floating init] (the 26.6 base class leaves them nil), _Floating_Mac adds a radius and an
//    8 pt inset. Keep the 26.6 -init, then set radius and platter insets to 0. (Replacing it with the 26.6 base class -init
//    loses the background: the sidebar becomes transparent or white.)
//
// 3. Top inset: 26.6 -[NSThemeFrame _updateContentLayoutGuideFrame] (0x7ff806e115a0) sends -[_UISidebarPartitionAdapter
//    setTopSidebarInset:] with the titlebar/toolbar inset + 8.0 when -[NSWindow _isSidebarFloating] (the UIKit adapter has
//    no allowsFloatingLayout, so it is always "floating"). AppKit 27 no longer adds 8 (0x18a42a038..0x18a42a144). In
//    Catalyst processes the window does not treat the sidebar as floating.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

void ggLog(NSString *fmt, ...);

typedef struct { double top, leading, bottom, trailing; } GGEdgeInsets;   // NSDirectionalEdgeInsets

static IMP gGlassMacInit;
static id hGlassMacInit(id self, SEL _cmd) {
    self = ((id (*)(id, SEL))gGlassMacInit)(self, _cmd);
    SEL s = sel_registerName("setSupportsFloatingSidebar:");
    if ([self respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(self, s, NO);
    return self;
}

static IMP gFloatingMacInit;
static id hFloatingMacInit(id self, SEL _cmd) {
    self = ((id (*)(id, SEL))gFloatingMacInit)(self, _cmd);
    SEL r = sel_registerName("setFallbackCornerRadius:"), p = sel_registerName("setPlatterInsets:");
    if ([self respondsToSelector:r]) ((void (*)(id, SEL, double))objc_msgSend)(self, r, 0);
    if ([self respondsToSelector:p]) ((void (*)(id, SEL, GGEdgeInsets))objc_msgSend)(self, p, (GGEdgeInsets){0, 0, 0, 0});
    return self;
}

static BOOL retNO(id self, SEL _cmd) { return NO; }

/// UISplitViewController sidebar column background (Books): -[_UISplitViewControllerAdaptiveImpl _layoutColumnViewForColumn:layout:]
/// takes the background style from -[_UISplitViewControllerAdaptivePanelLayout backgroundStyleForSplitViewControllerColumn:]
/// (a table precomputed by the Swift layout engine) then backgroundForBackgroundStyle: (26.6 0x7ff91ace78e0, 27 0x1ac578aec,
/// same mapping: 1 abutted, 2 floating). Measured at runtime on Books 26.6: floating column -> 2 (floatingBackground), edge
/// column (platterInsets 0) -> 0, no background, content shows through behind the sidebar. [I] 27 gives an edge sidebar
/// column the abutted background (branch 1 only fits edge sidebars; the non-floating 27 tab sidebar also uses
/// abuttedBackground); the 27 layout engine (Swift, stripped) has not been read. Applies only to the primary column when the
/// split view sets primaryBackgroundStyle = sidebar (1).
static IMP gLayoutColumn, gPanelBgStyle;
static __unsafe_unretained id gLayingOutImpl;   // main thread only, during _layoutColumnViewForColumn:layout:
static void hLayoutColumn(id self, SEL _cmd, id column, id layout) {
    id prev = gLayingOutImpl;
    gLayingOutImpl = self;
    ((void (*)(id, SEL, id, id))gLayoutColumn)(self, _cmd, column, layout);
    gLayingOutImpl = prev;
}
static long hPanelBgStyle(id self, SEL _cmd, long column) {
    long st = ((long (*)(id, SEL, long))gPanelBgStyle)(self, _cmd, column);
    SEL p = sel_registerName("primaryBackgroundStyle");
    if (st == 0 && column == 0 && gLayingOutImpl && [gLayingOutImpl respondsToSelector:p]
        && ((long (*)(id, SEL))objc_msgSend)(gLayingOutImpl, p) == 1) return 1;
    return st;
}

/// Replaces the IMP of -[cls sel] once; returns YES when replaced (or already our IMP).
static BOOL ggReplace(NSString *cls, SEL sel, IMP imp, IMP *orig) {
    Method m = class_getInstanceMethod(NSClassFromString(cls), sel);
    if (!m) return NO;
    if (method_getImplementation(m) == imp) return YES;
    IMP o = method_setImplementation(m, imp);
    if (orig) *orig = o;
    return YES;
}

void gg_sidebar_uikit_install(void) {
    if (!NSClassFromString(@"_UISidebarPlatformMetrics")) return;   // not a Catalyst process
    BOOL tab = ggReplace(@"_UIFloatingTabBarPlatformMetrics_GlassMac", @selector(init), (IMP)hGlassMacInit, &gGlassMacInit);
    BOOL metrics = ggReplace(@"_UISidebarPlatformMetrics_Floating_Mac", @selector(init), (IMP)hFloatingMacInit, &gFloatingMacInit);
    BOOL top = ggReplace(@"NSWindow", sel_registerName("_isSidebarFloating"), (IMP)retNO, NULL);
    BOOL split = ggReplace(@"_UISplitViewControllerAdaptiveImpl", sel_registerName("_layoutColumnViewForColumn:layout:"), (IMP)hLayoutColumn, &gLayoutColumn)
              && ggReplace(@"_UISplitViewControllerAdaptivePanelLayout", sel_registerName("backgroundStyleForSplitViewControllerColumn:"), (IMP)hPanelBgStyle, &gPanelBgStyle);
    ggLog(@"Catalyst sidebar 27: non-floating tab sidebar %d, metrics %d, top inset without +8 %d, split view column background %d", tab, metrics, top, split);
}
