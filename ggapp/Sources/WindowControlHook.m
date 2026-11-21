// Attaches 27 style traffic lights (WindowControl.swift) to the 26.6 traffic light buttons. 26.6 lights go through
// NSThemeWidgetAquaduckVisualProvider -> _NSCoreHostingView<ThemeWidgetView> (child of _NSThemeWidget). After the original
// updateBezelConfiguration: and layout:, create our NSHostingView once as a child of the button, same frame, not taking
// the mouse; hide the original hosting view.
// Measured on 26.6: buttonID 25 close, 26 minimize, 27 zoom (0 before attach); _interactionState 0 normal, 1 disabled,
// 2 pressed, 4 mouse inside the light group; AppKit calls updateBezelConfiguration: again on press/release, entering/leaving
// the group, key change.
// GG_WC_SNAP=<directory>: 4 s after hooking, the app captures its own windows with traffic lights to PNG (for testing real
// apps when the shell has no screen recording permission; an app capturing its own windows needs no permission).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
void ggLog(NSString *fmt, ...);
NSView *gg_wc_make(void);
void gg_wc_update(NSView *v, NSInteger buttonID, BOOL edited, BOOL obscured, NSInteger state, BOOL active, NSInteger zoomKind);
void gg_wc_drag(NSView *v, NSPoint p, NSInteger phase);

static IMP oUpdate, oLayout, oDown, oNext;
static Ivar ivButton, ivState;
static Class cButtonCfg, cWidgetCfg;
static char kView, kConfig;

static void apply(id provider) {
    NSButton *b = object_getIvar(provider, ivButton);
    id cfg = b ? objc_getAssociatedObject(b, &kConfig) : nil;
    // Read KVC and ivars by offset only on the exact measured classes (valueForKey: with an unknown key throws).
    if (![cfg isKindOfClass:cWidgetCfg] || ![cfg isKindOfClass:cButtonCfg]) return;
    NSInteger bid = [[cfg valueForKey:@"buttonID"] integerValue];
    if (!b.window || bid < 25 || bid > 27) return;
    NSView *v = objc_getAssociatedObject(b, &kView);
    if (!v) {
        v = gg_wc_make();
        objc_setAssociatedObject(b, &kView, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [b addSubview:v];
    }
    v.frame = b.bounds;
    for (NSView *s in b.subviews)
        if (s != v && !s.hidden && [NSStringFromClass(s.class) containsString:@"_NSCoreHostingView"]) s.hidden = YES;
    NSInteger state = *(NSInteger *)((__bridge void *)cfg + ivar_getOffset(ivState));
    NSWindow *w = b.window;
    NSInteger zoom = (w.styleMask & NSWindowStyleMaskFullScreen) ? 2
        : ((w.styleMask & NSWindowStyleMaskResizable) && !(w.collectionBehavior & NSWindowCollectionBehaviorFullScreenNone)) ? 1 : 0;
    gg_wc_update(v, bid, [[cfg valueForKey:@"isEdited"] boolValue], [[cfg valueForKey:@"isObscured"] boolValue], state,
                 w.isKeyWindow || w.isMainWindow, zoom);
}

static void hUpdate(id self, SEL _cmd, id cfg) {
    ((void (*)(id, SEL, id))oUpdate)(self, _cmd, cfg);
    NSButton *b = object_getIvar(self, ivButton);
    if (b && cfg) objc_setAssociatedObject(b, &kConfig, cfg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    apply(self);
}

static void hLayout(id self, SEL _cmd) {
    ((void (*)(id, SEL))oLayout)(self, _cmd);
    apply(self);
}

// Drag gesture for FlexInteraction. Measured on 26.6: -[_NSThemeWidget mouseDown:] runs its own loop until mouse up,
// fetching events with -[NSWindow nextEventMatchingMask:untilDate:inMode:dequeue:]; cell tracking uses untilMouseUp NO so
// dragging off the light stops continueTracking calls, and local monitors do not see events inside this loop.
static NSView *dragButton, *dragHost;   // light currently held (main thread only, inside mouseDown:)
static void hDown(NSView *self, SEL _cmd, NSEvent *e) {
    NSView *v = objc_getAssociatedObject(self, &kView);
    NSView *outerButton = dragButton, *outerHost = dragHost;
    if (v) { dragButton = self; dragHost = v; gg_wc_drag(v, [v convertPoint:e.locationInWindow fromView:nil], 0); }
    ((void (*)(id, SEL, NSEvent *))oDown)(self, _cmd, e);
    if (v) { gg_wc_drag(v, NSZeroPoint, 2); dragButton = outerButton; dragHost = outerHost; }
}
static NSEvent *hNext(NSWindow *self, SEL _cmd, NSEventMask mask, NSDate *until, NSRunLoopMode mode, BOOL dequeue) {
    NSEvent *e = ((NSEvent *(*)(id, SEL, NSEventMask, NSDate *, NSRunLoopMode, BOOL))oNext)(self, _cmd, mask, until, mode, dequeue);
    if (dragHost && e.type == NSEventTypeLeftMouseDragged && e.window == self && dragButton.window == self)
        gg_wc_drag(dragHost, [dragHost convertPoint:e.locationInWindow fromView:nil], 1);
    return e;
}

BOOL gg_wc_hook(void) {
    Class c = NSClassFromString(@"NSThemeWidgetAquaduckVisualProvider");
    cButtonCfg = NSClassFromString(@"NSButtonBezelConfiguration");
    cWidgetCfg = NSClassFromString(@"NSThemeWidgetBezelConfiguration");
    ivButton = c ? class_getInstanceVariable(c, "button") : NULL;
    ivState = cButtonCfg ? class_getInstanceVariable(cButtonCfg, "_interactionState") : NULL;
    if (!ivButton || !ivState || !cWidgetCfg) return NO;
    if (!ggSwizzle(c, @selector(updateBezelConfiguration:), (IMP)hUpdate, &oUpdate)) return NO;
    ggSwizzle(c, @selector(layout), (IMP)hLayout, &oLayout);
    if (ggSwizzle(NSClassFromString(@"_NSThemeWidget"), @selector(mouseDown:), (IMP)hDown, &oDown))
        ggSwizzle([NSWindow class], @selector(nextEventMatchingMask:untilDate:inMode:dequeue:), (IMP)hNext, &oNext);
    const char *snapDir = getenv("GG_WC_SNAP");
    if (snapDir) {
        NSString *dir = @(snapDir);
        // GG_WC_SNAP_DARK=1: switch this app's own NSApp.appearance to dark before capturing (system appearance untouched).
        if (getenv("GG_WC_SNAP_DARK")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            CGImageRef (*shot)(CGRect, uint32_t, uint32_t, uint32_t) = dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
            for (NSWindow *w in NSApp.windows) {
                if (!shot || !w.visible || ![w standardWindowButton:NSWindowCloseButton]) continue;
                CGImageRef img = shot(CGRectNull, 8, (uint32_t)w.windowNumber, 1);
                if (!img) continue;
                NSString *p = [dir stringByAppendingFormat:@"/wc-%d-%ld.png", getpid(), (long)w.windowNumber];
                [[[[NSBitmapImageRep alloc] initWithCGImage:img] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:p atomically:YES];
                CGImageRelease(img);
                ggLog(@"traffic lights: captured %@", p);
            }
        });
    }
    return YES;
}
