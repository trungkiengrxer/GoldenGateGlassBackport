// GGIsland.dylib, M2: hooks every OSD entry point of ControlCenter 26.6 (25G72) SystemBannerService
// (_TtC16ControlCenterApp19SystemBannerService, selectors from `ipsw class-dump --arch x86_64`), reports each call to
// gg_island_osd_sink (default: os_log, subsystem com.goldengate.island, category osd) and forwards it unchanged.
// Inactive when the class is missing, when `defaults write com.goldengate.island disable -bool YES` is set, or with
// GG_ISLAND_DISABLE in the environment (tests). A selector missing on another build is skipped and logged.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

typedef void (*GGIslandOSDSink)(NSString *event, NSArray *args);

static os_log_t gg_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.goldengate.island", "osd"); });
    return log;
}

static void gg_log_sink(NSString *event, NSArray *args) {
    os_log(gg_log(), "%{public}@ %{public}@", event, [args componentsJoinedByString:@" | "]);
}

__attribute__((visibility("default"))) GGIslandOSDSink gg_island_osd_sink = gg_log_sink;
static int hooks;
__attribute__((visibility("default"))) int gg_island_hook_count(void) { return hooks; }

/// M3: set by the Swift island host. NO = the island shows this event, skip the 26.6 presentation. NULL = forward.
typedef BOOL (*GGIslandForward)(NSString *event, NSArray *args);
__attribute__((visibility("default"))) GGIslandForward gg_island_should_forward;
/// M3: YES = drop the 26.6 SystemBannerWindow ordering (Focus banner, an internal Swift request in 26.6).
typedef BOOL (*GGIslandSuppress)(void);
__attribute__((visibility("default"))) GGIslandSuppress gg_island_suppress_banner;

/// Reports the call; returns whether the original must run.
static BOOL emit(SEL sel, NSArray *args) {
    NSString *name = NSStringFromSelector(sel);
    if (gg_island_osd_sink) gg_island_osd_sink(name, args);
    return gg_island_should_forward ? gg_island_should_forward(name, args) : YES;
}

/// Overrides `sel` on `c` itself: adds a method when `c` only inherits it (never patches the superclass), otherwise
/// replaces it. Returns the implementation to call as the original.
static IMP override(Class c, SEL sel, id block) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { os_log(gg_log(), "missing selector %{public}s, skipped", sel_getName(sel)); return NULL; }
    IMP orig = method_getImplementation(m), imp = imp_implementationWithBlock(block);
    if (!class_addMethod(c, sel, imp, method_getTypeEncoding(m))) orig = method_setImplementation(m, imp);
    return orig;
}

/// Replaces the implementation of `sel` with `block`; returns the original IMP, or NULL (and logs) if `sel` is missing.
static IMP swap(Class c, SEL sel, id block) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) { os_log(gg_log(), "missing selector %{public}s, skipped", sel_getName(sel)); return NULL; }
    hooks++;
    return method_setImplementation(m, imp_implementationWithBlock(block));
}

typedef void (^Done)(void);
static void (*o_image)(id, SEL, long long, unsigned, unsigned, unsigned);
static void (*o_imageText)(id, SEL, long long, unsigned, unsigned, unsigned, id);
static void (*o_imageChiclets)(id, SEL, long long, unsigned, unsigned, unsigned, unsigned, unsigned, signed char);
static void (*o_imagePath)(id, SEL, id, unsigned, unsigned, unsigned, id);
static void (*o_fadeClassic)(id, SEL, unsigned);
static void (*o_fullScreen)(id, SEL, long long, unsigned, unsigned, unsigned);
static void (*o_displayBrightness)(id, SEL, unsigned, double, double, signed char);
static void (*o_keyboardBrightness)(id, SEL, double, double, signed char);
static void (*o_volume)(id, SEL, double, double, signed char);
static void (*o_mute)(id, SEL, double, double, signed char);
static void (*o_srConnected)(id, SEL, id);
static void (*o_srConnectedInfo)(id, SEL, id);
static void (*o_srConnectedBattery)(id, SEL, id, double);
static void (*o_srReverse)(id, SEL, id, id, Done);
static void (*o_srReverseInfo)(id, SEL, id, id, Done);
static void (*o_srLowBattery)(id, SEL, id, unsigned, signed char, id, id, double);
static void (*o_srRemove)(id, SEL, long long);
static void (*o_listening)(id, SEL, long long, id);
static void (*o_accessoryType)(id, SEL, long long, id, double);
static void (*o_accessory)(id, SEL, id, id);
static void (*o_accessoryBattery)(id, SEL, id, id, double);
static void (*o_focus)(id, SEL, id, signed char);
static void (*o_lowBattery)(id, SEL, double);

static id orNull(id o) { return o ?: [NSNull null]; }

/// Focus: on 26.6 the Focus banner is an internal Swift request in ControlCenter (log category system-banners,
/// "focusMode(activity:isOn:)"), not showFocusMode:isOn:, so the bridge observes Focus.framework FCActivityManager
/// (sharedActivityManager, addObserver:, activeActivityDidChangeForManager:) instead. Event args: identifier, display
/// name, SF symbol, color name of the active activity, or a single NSNull when Focus turns off.
@interface GGIslandFocusObserver : NSObject
@end
@implementation GGIslandFocusObserver
- (void)activeActivityDidChangeForManager:(id)manager {
    id a = [manager valueForKey:@"activeActivity"];
    NSArray *args = a ? @[orNull([a valueForKey:@"activityIdentifier"]), orNull([a valueForKey:@"activityDisplayName"]),
                          orNull([a valueForKey:@"activitySymbolImageName"]), orNull([a valueForKey:@"activityColorName"])]
                      : @[[NSNull null]];
    emit(_cmd, args);
}
@end

static void gg_island_observe_focus(void) {
    Class m = objc_getClass("FCActivityManager");
    if (![m respondsToSelector:@selector(sharedActivityManager)]) { os_log(gg_log(), "FCActivityManager missing, Focus not observed"); return; }
    static GGIslandFocusObserver *observer;
    observer = [GGIslandFocusObserver new];
    [[m performSelector:@selector(sharedActivityManager)] performSelector:@selector(addObserver:) withObject:observer];
    os_log(gg_log(), "Focus observer registered");
}

/// Swift island host (Bootstrap.swift); weak so the bridge also works alone.
extern void gg_island_start(void) __attribute__((weak_import));

static void (*o_bannerFront)(id, SEL, id);
static void (*o_bannerFrontRegardless)(id, SEL);
static void (*o_bannerMakeKeyFront)(id, SEL, id);

static BOOL gg_suppressed(void) {
    BOOL s = gg_island_suppress_banner && gg_island_suppress_banner();
    if (s) os_log(gg_log(), "26.6 SystemBannerWindow suppressed");
    return s;
}

static void gg_island_hook_banner_window(void) {
    Class w = objc_getClass("_TtC16ControlCenterApp18SystemBannerWindow");
    if (!w) { os_log(gg_log(), "SystemBannerWindow missing, Focus banner not suppressed"); return; }
    SEL a = @selector(orderFront:), b = @selector(orderFrontRegardless), k = @selector(makeKeyAndOrderFront:);
    o_bannerFront = (void *)override(w, a, ^(id me, id sender) { if (!gg_suppressed()) o_bannerFront(me, a, sender); });
    o_bannerFrontRegardless = (void *)override(w, b, ^(id me) { if (!gg_suppressed()) o_bannerFrontRegardless(me, b); });
    o_bannerMakeKeyFront = (void *)override(w, k, ^(id me, id sender) { if (!gg_suppressed()) o_bannerMakeKeyFront(me, k, sender); });
}

__attribute__((constructor)) static void gg_island_install(void) {
    Class c = objc_getClass("_TtC16ControlCenterApp19SystemBannerService");
    if (!c) return;
    if (getenv("GG_ISLAND_DISABLE") || CFPreferencesGetAppBooleanValue(CFSTR("disable"), CFSTR("com.goldengate.island"), NULL)) {
        os_log(gg_log(), "disabled by kill switch");
        return;
    }
    SEL s;
    s = @selector(showImage:onDisplayID:priority:msecUntilFade:);
    o_image = (void *)swap(c, s, ^(id me, long long i, unsigned d, unsigned p, unsigned f) {
        emit(s, @[@(i), @(d), @(p), @(f)]); o_image(me, s, i, d, p, f); });
    SEL sImageText = @selector(showImage:onDisplayID:priority:msecUntilFade:withText:);
    o_imageText = (void *)swap(c, sImageText, ^(id me, long long i, unsigned d, unsigned p, unsigned f, id t) {
        emit(sImageText, @[@(i), @(d), @(p), @(f), orNull(t)]); o_imageText(me, sImageText, i, d, p, f, t); });
    SEL sChiclets = @selector(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:);
    o_imageChiclets = (void *)swap(c, sChiclets, ^(id me, long long i, unsigned d, unsigned p, unsigned f, unsigned fc, unsigned tc, signed char l) {
        if (emit(sChiclets, @[@(i), @(d), @(p), @(f), @(fc), @(tc), @(l)])) o_imageChiclets(me, sChiclets, i, d, p, f, fc, tc, l); });
    SEL sPath = @selector(showImageAtPath:onDisplayID:priority:msecUntilFade:withText:);
    o_imagePath = (void *)swap(c, sPath, ^(id me, id path, unsigned d, unsigned p, unsigned f, id t) {
        emit(sPath, @[orNull(path), @(d), @(p), @(f), orNull(t)]); o_imagePath(me, sPath, path, d, p, f, t); });
    SEL sFade = @selector(fadeClassicImageOnDisplay:);
    o_fadeClassic = (void *)swap(c, sFade, ^(id me, unsigned d) { emit(sFade, @[@(d)]); o_fadeClassic(me, sFade, d); });
    SEL sFull = @selector(showFullScreenImage:onDisplayID:priority:msecToAnimate:);
    o_fullScreen = (void *)swap(c, sFull, ^(id me, long long i, unsigned d, unsigned p, unsigned a) {
        emit(sFull, @[@(i), @(d), @(p), @(a)]); o_fullScreen(me, sFull, i, d, p, a); });
    SEL sDisp = @selector(showDisplayBrightness:value:max:isEnabled:);
    o_displayBrightness = (void *)swap(c, sDisp, ^(id me, unsigned b, double v, double m, signed char e) {
        emit(sDisp, @[@(b), @(v), @(m), @(e)]); o_displayBrightness(me, sDisp, b, v, m, e); });
    SEL sKbd = @selector(showKeyboardBrightness:max:isEnabled:);
    o_keyboardBrightness = (void *)swap(c, sKbd, ^(id me, double b, double m, signed char e) {
        emit(sKbd, @[@(b), @(m), @(e)]); o_keyboardBrightness(me, sKbd, b, m, e); });
    SEL sVol = @selector(showVolume:max:isEnabled:);
    o_volume = (void *)swap(c, sVol, ^(id me, double v, double m, signed char e) {
        emit(sVol, @[@(v), @(m), @(e)]); o_volume(me, sVol, v, m, e); });
    SEL sMute = @selector(showMute:max:isEnabled:);
    o_mute = (void *)swap(c, sMute, ^(id me, double v, double m, signed char e) {
        emit(sMute, @[@(v), @(m), @(e)]); o_mute(me, sMute, v, m, e); });
    SEL sSr = @selector(showSmartRoutingConnected:);
    o_srConnected = (void *)swap(c, sSr, ^(id me, id x) { emit(sSr, @[orNull(x)]); o_srConnected(me, sSr, x); });
    SEL sSrInfo = @selector(showSmartRoutingConnectedWithUserInfo:);
    o_srConnectedInfo = (void *)swap(c, sSrInfo, ^(id me, id x) { emit(sSrInfo, @[orNull(x)]); o_srConnectedInfo(me, sSrInfo, x); });
    SEL sSrBat = @selector(showSmartRoutingConnected:batteryLevel:);
    o_srConnectedBattery = (void *)swap(c, sSrBat, ^(id me, id x, double l) {
        emit(sSrBat, @[orNull(x), @(l)]); o_srConnectedBattery(me, sSrBat, x, l); });
    SEL sRev = @selector(showSmartRoutingReverseRoute:text:completion:);
    o_srReverse = (void *)swap(c, sRev, ^(id me, id r, id t, Done done) {
        emit(sRev, @[orNull(r), orNull(t)]); o_srReverse(me, sRev, r, t, done); });
    SEL sRevInfo = @selector(showSmartRoutingReverseRouteWithUserInfo:text:completion:);
    o_srReverseInfo = (void *)swap(c, sRevInfo, ^(id me, id i, id t, Done done) {
        emit(sRevInfo, @[orNull(i), orNull(t)]); o_srReverseInfo(me, sRevInfo, i, t, done); });
    SEL sLow = @selector(showSmartRoutingLowBattery:productID:forCase:imageBundleIdentifier:imageName:batteryLevel:);
    o_srLowBattery = (void *)swap(c, sLow, ^(id me, id b, unsigned pid, signed char cs, id bid, id n, double l) {
        emit(sLow, @[orNull(b), @(pid), @(cs), orNull(bid), orNull(n), @(l)]); o_srLowBattery(me, sLow, b, pid, cs, bid, n, l); });
    SEL sRemove = @selector(removeSmartRoutingForEvent:);
    o_srRemove = (void *)swap(c, sRemove, ^(id me, long long e) { emit(sRemove, @[@(e)]); o_srRemove(me, sRemove, e); });
    SEL sListen = @selector(showListeningModeChange:address:);
    o_listening = (void *)swap(c, sListen, ^(id me, long long m, id a) {
        emit(sListen, @[@(m), orNull(a)]); o_listening(me, sListen, m, a); });
    SEL sAccType = @selector(showAccessoryWithType:text:batteryLevel:);
    o_accessoryType = (void *)swap(c, sAccType, ^(id me, long long t, id x, double l) {
        emit(sAccType, @[@(t), orNull(x), @(l)]); o_accessoryType(me, sAccType, t, x, l); });
    SEL sAcc = @selector(showAccessory:text:);
    o_accessory = (void *)swap(c, sAcc, ^(id me, id a, id x) { emit(sAcc, @[orNull(a), orNull(x)]); o_accessory(me, sAcc, a, x); });
    SEL sAccBat = @selector(showAccessory:text:batteryLevel:);
    o_accessoryBattery = (void *)swap(c, sAccBat, ^(id me, id a, id x, double l) {
        emit(sAccBat, @[orNull(a), orNull(x), @(l)]); o_accessoryBattery(me, sAccBat, a, x, l); });
    SEL sFocus = @selector(showFocusMode:isOn:);
    o_focus = (void *)swap(c, sFocus, ^(id me, id m, signed char on) { emit(sFocus, @[orNull(m), @(on)]); o_focus(me, sFocus, m, on); });
    SEL sLowBat = @selector(showLowBattery:);
    o_lowBattery = (void *)swap(c, sLowBat, ^(id me, double b) { emit(sLowBat, @[@(b)]); o_lowBattery(me, sLowBat, b); });
    os_log(gg_log(), "hooks installed: %d", hooks);
    gg_island_hook_banner_window();
    dispatch_async(dispatch_get_main_queue(), ^{   // after ControlCenter finishes launching
        gg_island_observe_focus();
        if (gg_island_start) gg_island_start();
    });
}
