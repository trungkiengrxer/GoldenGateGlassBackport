// macOS 27 style window corner radius. Hooks -[NSThemeFrame _getCachedWindowCornerRadius],
// the 26.6 function (0x7ff807bb5cef) every radius lookup goes through (_cornerRadius, the corner mask AppKit sends WindowServer).
// 26.6 Solarium: utility 15, sheet/alert 26, no toolbar or toolbar expanded/preference 16, unifiedCompact 20,
// unified 26. 27 (-[NSThemeFrame _getCachedDefaultWindowCornerRadius] 0x18aca6624): NSConvolutionOverride (if nonzero),
// titled window or sheet (styleMask & 0x41) 16, alert 26, otherwise 0. Full screen stays 0 thanks to -[NSThemeFrame
// _cornerRadius]. The window shadow is built by WindowServer from the window shape, so it follows.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
void ggLog(NSString *fmt, ...);

static IMP oCornerRadius;

static CGFloat hCornerRadius(NSView *self, SEL _cmd) {
    if (!((BOOL (*)(id, SEL))objc_msgSend)(self, sel_registerName("_hasSolariumAppearance")))
        return ((CGFloat (*)(id, SEL))oCornerRadius)(self, _cmd);
    CGFloat over = ((CGFloat (*)(id, SEL))objc_msgSend)(self, sel_registerName("_convolutionOverride"));
    if (over != 0) return over;
    NSUInteger mask = ((NSUInteger (*)(id, SEL))objc_msgSend)(self, sel_registerName("_effectiveStyleMask"));
    if (!(mask & (NSWindowStyleMaskTitled | NSWindowStyleMaskDocModalWindow))) return 0;
    return ((BOOL (*)(id, SEL))objc_msgSend)(self.window, sel_registerName("_isAlertWindow")) ? 26 : 16;
}

void gg_corners_install(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    BOOL ok = ggSwizzle(NSClassFromString(@"NSThemeFrame"), sel_registerName("_getCachedWindowCornerRadius"), (IMP)hCornerRadius, &oCornerRadius);
    ggLog(@"window corners 27: %d", ok);
}
