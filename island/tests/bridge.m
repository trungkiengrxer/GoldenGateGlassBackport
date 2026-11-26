// Tests for GGIsland.dylib (Bridge/OSDBridge.m) without ControlCenter: a fake class with the name and selectors of
// ControlCenter 26.6 SystemBannerService (ipsw class-dump --arch x86_64). fadeClassicImageOnDisplay: is left out on
// purpose (missing selector must be skipped). Built with -DNOCLASS it has no fake class at all.
#import <Foundation/Foundation.h>

typedef void (*GGIslandOSDSink)(NSString *event, NSArray *args);
extern GGIslandOSDSink gg_island_osd_sink;
extern int gg_island_hook_count(void);
typedef BOOL (*GGIslandForward)(NSString *event, NSArray *args);
extern GGIslandForward gg_island_should_forward;
typedef BOOL (*GGIslandSuppress)(void);
extern GGIslandSuppress gg_island_suppress_banner;

static int failures;
static void expect(BOOL c, NSString *name) { printf("%s %s\n", c ? "OK  " : "FAIL", name.UTF8String); if (!c) failures++; }

static NSMutableArray *originals, *events;   // args seen by the fake originals, (event, args) seen by the sink
static void sink(NSString *e, NSArray *a) { [events addObject:@[e, a]]; }

#ifndef NOCLASS
static void rec(NSArray *a) { [originals addObject:a]; }

@interface _TtC16ControlCenterApp19SystemBannerService : NSObject
- (void)showImage:(long long)image onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f;
- (void)showImage:(long long)image onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f withText:(id)t;
- (void)showImage:(long long)image onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f
   filledChiclets:(unsigned int)fc totalChiclets:(unsigned int)tc locked:(signed char)l;
- (void)showImageAtPath:(id)path onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f withText:(id)t;
- (void)showFullScreenImage:(long long)image onDisplayID:(unsigned int)d priority:(unsigned int)p msecToAnimate:(unsigned int)a;
- (void)showDisplayBrightness:(unsigned int)b value:(double)v max:(double)m isEnabled:(signed char)e;
- (void)showKeyboardBrightness:(double)b max:(double)m isEnabled:(signed char)e;
- (void)showVolume:(double)v max:(double)m isEnabled:(signed char)e;
- (void)showMute:(double)v max:(double)m isEnabled:(signed char)e;
- (void)showSmartRoutingConnected:(id)c;
- (void)showSmartRoutingConnectedWithUserInfo:(id)i;
- (void)showSmartRoutingConnected:(id)c batteryLevel:(double)l;
- (void)showSmartRoutingReverseRoute:(id)r text:(id)t completion:(void (^)(void))done;
- (void)showSmartRoutingReverseRouteWithUserInfo:(id)i text:(id)t completion:(void (^)(void))done;
- (void)showSmartRoutingLowBattery:(id)b productID:(unsigned int)pid forCase:(signed char)c imageBundleIdentifier:(id)bid
                         imageName:(id)n batteryLevel:(double)l;
- (void)removeSmartRoutingForEvent:(long long)e;
- (void)showListeningModeChange:(long long)c address:(id)a;
- (void)showAccessoryWithType:(long long)t text:(id)x batteryLevel:(double)l;
- (void)showAccessory:(id)a text:(id)x;
- (void)showAccessory:(id)a text:(id)x batteryLevel:(double)l;
- (void)showFocusMode:(id)m isOn:(signed char)on;
- (void)showLowBattery:(double)b;
@end

@implementation _TtC16ControlCenterApp19SystemBannerService
- (void)showImage:(long long)i onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f { rec(@[@(i), @(d), @(p), @(f)]); }
- (void)showImage:(long long)i onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f withText:(id)t { rec(@[@(i), @(d), @(p), @(f), t]); }
- (void)showImage:(long long)i onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f
   filledChiclets:(unsigned int)fc totalChiclets:(unsigned int)tc locked:(signed char)l { rec(@[@(i), @(d), @(p), @(f), @(fc), @(tc), @(l)]); }
- (void)showImageAtPath:(id)path onDisplayID:(unsigned int)d priority:(unsigned int)p msecUntilFade:(unsigned int)f withText:(id)t { rec(@[path, @(d), @(p), @(f), t]); }
- (void)showFullScreenImage:(long long)i onDisplayID:(unsigned int)d priority:(unsigned int)p msecToAnimate:(unsigned int)a { rec(@[@(i), @(d), @(p), @(a)]); }
- (void)showDisplayBrightness:(unsigned int)b value:(double)v max:(double)m isEnabled:(signed char)e { rec(@[@(b), @(v), @(m), @(e)]); }
- (void)showKeyboardBrightness:(double)b max:(double)m isEnabled:(signed char)e { rec(@[@(b), @(m), @(e)]); }
- (void)showVolume:(double)v max:(double)m isEnabled:(signed char)e { rec(@[@(v), @(m), @(e)]); }
- (void)showMute:(double)v max:(double)m isEnabled:(signed char)e { rec(@[@(v), @(m), @(e)]); }
- (void)showSmartRoutingConnected:(id)c { rec(@[c]); }
- (void)showSmartRoutingConnectedWithUserInfo:(id)i { rec(@[i]); }
- (void)showSmartRoutingConnected:(id)c batteryLevel:(double)l { rec(@[c, @(l)]); }
- (void)showSmartRoutingReverseRoute:(id)r text:(id)t completion:(void (^)(void))done { rec(@[r, t]); done(); }
- (void)showSmartRoutingReverseRouteWithUserInfo:(id)i text:(id)t completion:(void (^)(void))done { rec(@[i, t]); done(); }
- (void)showSmartRoutingLowBattery:(id)b productID:(unsigned int)pid forCase:(signed char)c imageBundleIdentifier:(id)bid
                         imageName:(id)n batteryLevel:(double)l { rec(@[b, @(pid), @(c), bid, n, @(l)]); }
- (void)removeSmartRoutingForEvent:(long long)e { rec(@[@(e)]); }
- (void)showListeningModeChange:(long long)c address:(id)a { rec(@[@(c), a]); }
- (void)showAccessoryWithType:(long long)t text:(id)x batteryLevel:(double)l { rec(@[@(t), x, @(l)]); }
- (void)showAccessory:(id)a text:(id)x { rec(@[a, x]); }
- (void)showAccessory:(id)a text:(id)x batteryLevel:(double)l { rec(@[a, x, @(l)]); }
- (void)showFocusMode:(id)m isOn:(signed char)on { rec(@[m, @(on)]); }
- (void)showLowBattery:(double)b { rec(@[@(b)]); }
@end

// Fake window classes: the bridge must add overrides to SystemBannerWindow only, never patch the superclass.
static int baseFronts, bannerFronts;
@interface FakePanelBase : NSObject
- (void)orderFrontRegardless;
- (void)orderFront:(id)sender;
- (void)makeKeyAndOrderFront:(id)sender;
@end
@implementation FakePanelBase
- (void)orderFrontRegardless { if ([self class] == [FakePanelBase class]) baseFronts++; else bannerFronts++; }
- (void)orderFront:(id)sender { [self orderFrontRegardless]; }
- (void)makeKeyAndOrderFront:(id)sender { [self orderFrontRegardless]; }
@end
@interface _TtC16ControlCenterApp18SystemBannerWindow : FakePanelBase
@end
@implementation _TtC16ControlCenterApp18SystemBannerWindow
@end
static BOOL suppressOn;
static BOOL suppress(void) { return suppressOn; }
static BOOL forwardNothing(NSString *e, NSArray *a) { return NO; }

// Fake Focus.framework FCActivityManager / activity (26.6 selectors from nm on the extracted Focus dylib).
@protocol FocusObserver
- (void)activeActivityDidChangeForManager:(id)manager;
@end
@interface FakeActivity : NSObject
@property NSString *activityIdentifier, *activityDisplayName, *activitySymbolImageName, *activityColorName;
@end
@implementation FakeActivity
@end
@interface FCActivityManager : NSObject
@property(readonly) NSMutableArray *observers;
@property(nullable) FakeActivity *activeActivity;
+ (instancetype)sharedActivityManager;
- (void)addObserver:(id)o;
@end
@implementation FCActivityManager
+ (instancetype)sharedActivityManager { static FCActivityManager *m; if (!m) { m = [self new]; m->_observers = [NSMutableArray new]; } return m; }
- (void)addObserver:(id)o { [_observers addObject:o]; }
@end

/// Runs `call`, then checks the original got `args` and the sink got (`sel`, `args`) (or nothing when hooks are off).
static void check(NSString *sel, NSArray *args, BOOL hooked, void (^call)(void)) {
    [originals removeAllObjects]; [events removeAllObjects];
    call();
    BOOL orig = [originals.lastObject isEqual:args];
    BOOL sunk = hooked ? [events.lastObject isEqual:(@[sel, args])] : events.count == 0;
    expect(orig && sunk, sel);
}
#endif

int main(void) {
    @autoreleasepool {
        originals = [NSMutableArray new]; events = [NSMutableArray new];
        gg_island_osd_sink = sink;
#ifdef NOCLASS
        expect(gg_island_hook_count() == 0, @"noClassNoHooks");
#else
        BOOL hooked = getenv("GG_ISLAND_DISABLE") == NULL;
        expect(gg_island_hook_count() == (hooked ? 22 : 0), hooked ? @"hookCount22 (missingSelectorSkipped)" : @"killSwitch");
        id s = [_TtC16ControlCenterApp19SystemBannerService new];
        NSDictionary *info = @{@"name": @"AirPods"};
        check(@"showVolume:max:isEnabled:", @[@0.5, @1, @YES], hooked, ^{ [s showVolume:0.5 max:1 isEnabled:YES]; });
        check(@"showMute:max:isEnabled:", @[@0, @1, @NO], hooked, ^{ [s showMute:0 max:1 isEnabled:NO]; });
        check(@"showDisplayBrightness:value:max:isEnabled:", @[@1, @0.25, @1, @YES], hooked,
              ^{ [s showDisplayBrightness:1 value:0.25 max:1 isEnabled:YES]; });
        check(@"showKeyboardBrightness:max:isEnabled:", @[@0.75, @1, @YES], hooked, ^{ [s showKeyboardBrightness:0.75 max:1 isEnabled:YES]; });
        check(@"showFocusMode:isOn:", @[@"Work", @YES], hooked, ^{ [s showFocusMode:@"Work" isOn:YES]; });
        check(@"showLowBattery:", @[@0.1], hooked, ^{ [s showLowBattery:0.1]; });
        check(@"showSmartRoutingConnected:", @[info], hooked, ^{ [s showSmartRoutingConnected:info]; });
        check(@"showSmartRoutingConnectedWithUserInfo:", @[info], hooked, ^{ [s showSmartRoutingConnectedWithUserInfo:info]; });
        check(@"showSmartRoutingConnected:batteryLevel:", @[info, @0.8], hooked, ^{ [s showSmartRoutingConnected:info batteryLevel:0.8]; });
        __block int done = 0;
        check(@"showSmartRoutingReverseRoute:text:completion:", @[info, @"Move"], hooked,
              ^{ [s showSmartRoutingReverseRoute:info text:@"Move" completion:^{ done++; }]; });
        check(@"showSmartRoutingReverseRouteWithUserInfo:text:completion:", @[info, @"Move"], hooked,
              ^{ [s showSmartRoutingReverseRouteWithUserInfo:info text:@"Move" completion:^{ done++; }]; });
        expect(done == 2, @"forwardsCompletionBlock");
        check(@"showSmartRoutingLowBattery:productID:forCase:imageBundleIdentifier:imageName:batteryLevel:",
              @[info, @8212, @YES, @"com.apple.bid", @"case", @0.05], hooked,
              ^{ [s showSmartRoutingLowBattery:info productID:8212 forCase:YES imageBundleIdentifier:@"com.apple.bid" imageName:@"case" batteryLevel:0.05]; });
        check(@"removeSmartRoutingForEvent:", @[@3], hooked, ^{ [s removeSmartRoutingForEvent:3]; });
        check(@"showListeningModeChange:address:", @[@2, @"aa:bb"], hooked, ^{ [s showListeningModeChange:2 address:@"aa:bb"]; });
        check(@"showAccessoryWithType:text:batteryLevel:", @[@4, @"Mouse", @0.3], hooked, ^{ [s showAccessoryWithType:4 text:@"Mouse" batteryLevel:0.3]; });
        check(@"showAccessory:text:", @[info, @"Keyboard"], hooked, ^{ [s showAccessory:info text:@"Keyboard"]; });
        check(@"showAccessory:text:batteryLevel:", @[info, @"Keyboard", @0.6], hooked, ^{ [s showAccessory:info text:@"Keyboard" batteryLevel:0.6]; });
        check(@"showImage:onDisplayID:priority:msecUntilFade:", @[@7, @1, @2, @1500], hooked,
              ^{ [s showImage:7 onDisplayID:1 priority:2 msecUntilFade:1500]; });
        check(@"showImage:onDisplayID:priority:msecUntilFade:withText:", @[@7, @1, @2, @1500, @"Caps"], hooked,
              ^{ [s showImage:7 onDisplayID:1 priority:2 msecUntilFade:1500 withText:@"Caps"]; });
        check(@"showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:", @[@7, @1, @2, @1500, @5, @16, @YES], hooked,
              ^{ [s showImage:7 onDisplayID:1 priority:2 msecUntilFade:1500 filledChiclets:5 totalChiclets:16 locked:YES]; });
        check(@"showImageAtPath:onDisplayID:priority:msecUntilFade:withText:", @[@"/tmp/x.pdf", @1, @2, @1500, @"Eject"], hooked,
              ^{ [s showImageAtPath:@"/tmp/x.pdf" onDisplayID:1 priority:2 msecUntilFade:1500 withText:@"Eject"]; });
        check(@"showFullScreenImage:onDisplayID:priority:msecToAnimate:", @[@9, @1, @2, @300], hooked,
              ^{ [s showFullScreenImage:9 onDisplayID:1 priority:2 msecToAnimate:300]; });

        // Forwarding decision (M3): the island takes chiclet OSD calls; the original must then not run.
        if (hooked) {
            gg_island_should_forward = forwardNothing;
            [originals removeAllObjects]; [events removeAllObjects];
            [s showImage:5 onDisplayID:1 priority:500 msecUntilFade:4000 filledChiclets:625 totalChiclets:10000 locked:NO];
            expect(originals.count == 0 && events.count == 1, @"notForwardedWhenConsumed");
            gg_island_should_forward = NULL;
            [s showImage:5 onDisplayID:1 priority:500 msecUntilFade:4000 filledChiclets:625 totalChiclets:10000 locked:NO];
            expect(originals.count == 1, @"forwardWhenNoDecider");
            // Banner window suppression, superclass untouched.
            gg_island_suppress_banner = suppress;
            id base = [FakePanelBase new], banner = [_TtC16ControlCenterApp18SystemBannerWindow new];
            suppressOn = YES;
            [banner orderFrontRegardless]; [banner orderFront:nil]; [banner makeKeyAndOrderFront:nil]; [base orderFrontRegardless];
            BOOL blocked = bannerFronts == 0 && baseFronts == 1;
            suppressOn = NO;
            [banner orderFrontRegardless];
            expect(blocked && bannerFronts == 1, @"bannerWindowSuppressed");
        }

        // Focus: the bridge registers an observer on the main queue after launch (26.6 Focus banners are internal Swift
        // requests in ControlCenter, not showFocusMode:isOn:).
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, false);
        FCActivityManager *fm = [FCActivityManager sharedActivityManager];
        expect(fm.observers.count == (hooked ? 1 : 0), hooked ? @"focusObserverRegistered" : @"killSwitchNoFocusObserver");
        if (hooked) {
            FakeActivity *a = [FakeActivity new];
            a.activityIdentifier = @"com.apple.focus.gaming"; a.activityDisplayName = @"Gaming";
            a.activitySymbolImageName = @"gamecontroller.fill"; a.activityColorName = @"systemGreenColor";
            [events removeAllObjects];
            fm.activeActivity = a;
            [fm.observers.firstObject activeActivityDidChangeForManager:fm];
            expect([events.lastObject isEqual:(@[@"activeActivityDidChangeForManager:",
                                                 @[@"com.apple.focus.gaming", @"Gaming", @"gamecontroller.fill", @"systemGreenColor"]])], @"focusOn");
            fm.activeActivity = nil;
            [fm.observers.firstObject activeActivityDidChangeForManager:fm];
            expect([events.lastObject isEqual:(@[@"activeActivityDidChangeForManager:", @[[NSNull null]]])], @"focusOff");
        }
#endif
    }
    return failures == 0 ? 0 : 1;
}
