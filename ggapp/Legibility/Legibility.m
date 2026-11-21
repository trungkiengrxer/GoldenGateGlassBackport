// GGLegibility.dylib: the macOS 27 glass transparency slider path rebuilt on 26.6.
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <limits.h>
#import <stdatomic.h>
#import <pthread.h>
#import <notify.h>
#import <math.h>
#import "Legibility.h"
#import "Recipe27.h"

int32_t gg_tint_encode(float a, int32_t flag) {
    float c = fminf(fmaxf(isnan(a) ? 0.5f : a, 0), 1);
    return 2 + 2 * (int32_t)lroundf(c * 1000) + (flag & 1);
}

int32_t gg_tint_encode_app(float a, int32_t flag, int32_t dark) {
    float c = fminf(fmaxf(isnan(a) ? 0.5f : a, 0), 1);
    return -(2 + 4 * (int32_t)lroundf(c * 500) + 2 * (dark & 1) + (flag & 1));
}

bool gg_tint_decode(int32_t p, float *a, int32_t *flag) {
    if (p > -2 && p < 2) return false;
    if (p < 0) {
        int32_t m = -p - 2;
        if (a) *a = (float)(m / 4) / 500;
        if (flag) *flag = m & 1;
        return true;
    }
    int32_t k = (p - 2) / 2;
    if (a) *a = (float)k / 1000;
    if (flag) *flag = (p - 2) & 1;
    return true;
}

int32_t gg_tint_appearance(int32_t p) { return p <= -2 ? ((-p - 2) >> 1) & 1 : -1; }

/// Global domain as AppKit reads it (NSUserDefaults standardUserDefaults, global domain); GG_PREFS: replacement plist (tests).
static NSDictionary *ggGlobalPrefs(void) {
    const char *alt = getenv("GG_PREFS");
    if (alt) return [NSDictionary dictionaryWithContentsOfFile:@(alt)];
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    id v = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("NSGlassTintAmount"), kCFPreferencesAnyApplication,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    return v ? @{@"NSGlassTintAmount": v} : @{};
}

float GGGlassSystemLegibility(void) {
    id v = ggGlobalPrefs()[@"NSGlassTintAmount"];
    return [v isKindOfClass:[NSNumber class]] ? fminf(fmaxf([v floatValue], 0), 1) : 0.5f;
}

// Applied value (float bits; NaN = not initialized).
static _Atomic uint32_t gApplied = 0x7fc00000u;
static float ggLoad(void) { uint32_t b = atomic_load(&gApplied); float f; memcpy(&f, &b, 4); return f; }
static void ggStore(float f) { uint32_t b; memcpy(&b, &f, 4); atomic_store(&gApplied, b); }

float gg_legibility_current(void) {
    float f = ggLoad();
    if (isnan(f)) { f = GGGlassSystemLegibility(); ggStore(f); }
    return f;
}

bool gg_legibility_needs_update(void) {
    float old = gg_legibility_current(), now = GGGlassSystemLegibility();
    ggStore(now);
    return now != old;
}

// MARK: - Injecting the code into glass filters
// SwiftUICore 26.6 creates a new glassBackground filter and assigns it with -[CALayer setFilters:] on every rebuild;
// QuartzCore passes inputClampPreserveHue into the preserve_hue uniform, and the GGGlass shader decodes it.

static NSString *const kKey = @"inputClampPreserveHue";

/// Type of a filter in layer.filters / backgroundFilters, nil if it is not a CAFilter. Elements can be CIFilters (Quick Look
/// attaches CIGaussianBlur): a CIFilter throws NSUnknownKeyException on valueForKey:@"type", breaking the CATransaction being
/// committed (Finder hung on Quick Look video). respondsToSelector:valueForKey: is always true for NSObject, so it cannot guard.
static NSString *ggFilterType(id f) {
    static Class caFilter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ caFilter = NSClassFromString(@"CAFilter"); });
    return caFilter && [f isKindOfClass:caFilter] ? [f valueForKey:@"type"] : nil;
}

static BOOL ggIsGlass(id f) { return [ggFilterType(f) isEqual:@"glassBackground"]; }

/// Glass appearance like 27 (each glass follows the effectiveAppearance of its containing view, not a global system flag):
/// the nearest view up the superlayer chain (delegate of a view-backed layer). 1 dark, 0 light, -1 no view (Dock, custom
/// layers) or off the main thread (AppKit is only safe on the main thread): the shader uses the global appearance flag.
static int32_t ggLayerDark(CALayer *l) {
    if (![NSThread isMainThread]) return -1;
    SEL eff = NSSelectorFromString(@"effectiveAppearance"), best = NSSelectorFromString(@"bestMatchFromAppearancesWithNames:");
    for (int i = 0; l && i < 64; i++, l = l.superlayer) {
        id d = l.delegate;
        if (![d respondsToSelector:eff]) continue;
        id app = ((id (*)(id, SEL))objc_msgSend)(d, eff);
        if (![app respondsToSelector:best]) return -1;
        id m = ((id (*)(id, SEL, id))objc_msgSend)(app, best, @[@"NSAppearanceNameAqua", @"NSAppearanceNameDarkAqua"]);
        return [m isEqual:@"NSAppearanceNameDarkAqua"] ? 1 : 0;
    }
    return -1;
}

/// Code for a filter on layer `l`: keeps the original preserve flag (decoded if the filter already carries a code), plus the
/// glass appearance if known.
static int32_t ggCodeFor(id f, CALayer *l) {
    int32_t p = [[f valueForKey:kKey] intValue], flag = 0;
    int r; bool ri, rd; float ra;
    if (!gg_recipe_decode(p, &r, &ri, &rd, &flag, &ra) && !gg_tint_decode(p, NULL, &flag)) flag = p > 0;
    int32_t dark = ggLayerDark(l);
    return dark >= 0 ? gg_tint_encode_app(gg_legibility_current(), flag, dark) : gg_tint_encode(gg_legibility_current(), flag);
}

/// Rewrites the code on the glass filters of layer `l` only (key paths on the model layer, like recommit).
static void ggRecodeLayer(CALayer *l) {
    if (gg_recipe_recode(l, gg_legibility_current())) return;   // glass carrying the app's 27 recipe (Recipe.m)
    for (id f in l.filters) if (ggIsGlass(f)) {
        NSString *name = [f valueForKey:@"name"] ?: @"glassBackground";
        [l setValue:@(ggCodeFor(f, l)) forKeyPath:[NSString stringWithFormat:@"filters.%@.%@", name, kKey]];
    }
}

/// SwiftUI may assign the glass filter before the layer is attached to the view's layer tree (non-key window: no reassignment
/// after attaching), so the appearance is still unknown. Retry on later runloop passes (at most `left`), once the layer is
/// under a view.
static void ggRecodeWhenAttached(CALayer *layer, int left) {
    __weak CALayer *weak = layer;
    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *l = weak;
        if (!l) return;
        if (ggLayerDark(l) < 0) { if (left > 1) ggRecodeWhenAttached(l, left - 1); return; }
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        ggRecodeLayer(l);
        [CATransaction commit];
    });
}

static IMP gOrigSetFilters;
static void ggSetFilters(CALayer *self, SEL sel, NSArray *filters) {
    BOOL glass = NO;
    for (id f in filters) if (ggIsGlass(f)) {
        // The app computes the 27 recipe and writes the real values; otherwise the old code as before.
        if (!gg_recipe_apply(f, self, gg_legibility_current())) [f setValue:@(ggCodeFor(f, self)) forKey:kKey];
        glass = YES;
    } else gg_recipe_foreground(f);
    ((void (*)(id, SEL, NSArray *))gOrigSetFilters)(self, sel, filters);
    if (glass && [NSThread isMainThread] && ggLayerDark(self) < 0) ggRecodeWhenAttached(self, 3);
}

static void ggWalk(CALayer *l, int depth) {
    if (!l || depth > 64) return;
    ggRecodeLayer(l);
    for (CALayer *s in l.sublayers) ggWalk(s, depth + 1);
}

/// Sizes of the CASDFElementLayers (one per shape) under the glass SDF layer, to tell whether the glass covers one or more shapes.
static NSString *ggElements(CALayer *root) {
    NSMutableArray *out = [NSMutableArray array];
    Class el = NSClassFromString(@"CASDFElementLayer");
    __block void (^walk)(CALayer *, int);
    __block __weak void (^weakWalk)(CALayer *, int);
    weakWalk = walk = ^(CALayer *l, int depth) {
        if (depth > 8) return;
        for (CALayer *s in l.sublayers) {
            if (el && [s isKindOfClass:el]) [out addObject:[NSString stringWithFormat:@"%.0fx%.0f", s.bounds.size.width, s.bounds.size.height]];
            weakWalk(s, depth + 1);
        }
    };
    walk(root, 0);
    return [out componentsJoinedByString:@","];
}

/// sizes: for each glass layer, its bounds size and the delegate class/size (the glass shape may be defined by another layer,
/// e.g. SDFLayer in Control Center), to compare the short side the app uses with the one the shader measures from the SDF.
static void ggCollect(CALayer *l, int depth, NSCountedSet *codes, NSCountedSet *types, NSCountedSet *sizes) {
    if (!l || depth > 64) return;
    for (id f in l.filters) {
        if (ggIsGlass(f)) {
            [codes addObject:@([[f valueForKey:kKey] intValue])];
            id d = l.delegate;
            NSString *ds = [d isKindOfClass:[CALayer class]]
                ? [NSString stringWithFormat:@"%@ %.0fx%.0f elements [%@]", NSStringFromClass([d class]), ((CALayer *)d).bounds.size.width,
                   ((CALayer *)d).bounds.size.height, ggElements((CALayer *)d)]
                : NSStringFromClass([d class]);
            [sizes addObject:[NSString stringWithFormat:@"%.0fx%.0f/%@", l.bounds.size.width, l.bounds.size.height, ds]];
        }
        [types addObject:ggFilterType(f) ?: NSStringFromClass([f class])];
    }
    for (id f in l.backgroundFilters) [types addObject:[@"bg:" stringByAppendingString:ggFilterType(f) ?: NSStringFromClass([f class])]];
    for (CALayer *s in l.sublayers) ggCollect(s, depth + 1, codes, types, sizes);
}

static NSString *ggCounted(NSCountedSet *set) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id o in [set.allObjects sortedArrayUsingSelector:@selector(compare:)])
        [parts addObject:[NSString stringWithFormat:@"%@x%lu", o, (unsigned long)[set countForObject:o]]];
    return [parts componentsJoinedByString:@" "];
}

/// Diagnostics (Darwin notify com.goldengate.legibility.dump): writes the applied value and the inputClampPreserveHue codes on
/// the process glass filters (with counts) to <GG_HOME or ~>/Library/Logs/GoldenGate/legibility.log.
static void ggDump(void) {
    NSCountedSet *codes = [NSCountedSet set], *types = [NSCountedSet set], *sizes = [NSCountedSet set];
    Class ctx = NSClassFromString(@"CAContext");
    NSArray *all = [ctx respondsToSelector:@selector(allContexts)] ? [ctx performSelector:@selector(allContexts)] : nil;
    for (id c in all) if ([c respondsToSelector:@selector(layer)]) ggCollect([c performSelector:@selector(layer)], 0, codes, types, sizes);
    const char *home = getenv("GG_HOME");
    NSString *dir = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Library/Logs/GoldenGate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *line = [NSString stringWithFormat:@"%@ %@ pid %d current %.2f defaults %.2f context %lu codes [%@] filter [%@] sizes [%@]\n",
                      [NSDate date], NSProcessInfo.processInfo.processName, getpid(), gg_legibility_current(),
                      GGGlassSystemLegibility(), (unsigned long)all.count, ggCounted(codes), ggCounted(types), ggCounted(sizes)];
    NSString *path = [dir stringByAppendingPathComponent:@"legibility.log"];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

// MARK: - Trace (diagnostics): glass filter parameters per frame
// Darwin notify com.goldengate.legibility.trace: for 4 s, every ~8 ms, records the process glassBackground filters (model
// and presentation: black, white, sat, fill, blur, code) when they change, to see which states the app moves between and
// how animations interpolate. Written to <GG_HOME or ~>/Library/Logs/GoldenGate/legibility-trace.log.

static NSString *ggGlassParams(CALayer *l) {
    if (!l) return @"-";
    for (id f in l.filters) if (ggIsGlass(f)) {
        CGColorRef c = (__bridge CGColorRef)[f valueForKey:@"inputFaceColorMatrixFillColor"];
        const CGFloat *cc = c && CFGetTypeID(c) == CGColorGetTypeID() ? CGColorGetComponents(c) : NULL;
        size_t n = cc ? CGColorGetNumberOfComponents(c) : 0;
        return [NSString stringWithFormat:@"B %.4f W %.4f S %.4f fill %.3f/%.3f blur %.4f code %d",
                [[f valueForKey:@"inputFaceColorMatrixBlack"] doubleValue], [[f valueForKey:@"inputFaceColorMatrixWhite"] doubleValue],
                [[f valueForKey:@"inputFaceColorMatrixSaturation"] doubleValue], n ? cc[0] : -1.0, n ? cc[n - 1] : -1.0,
                [[f valueForKey:@"inputBlurRadius"] doubleValue], [[f valueForKey:kKey] intValue]];
    }
    return @"-";
}

static void ggTraceWalk(CALayer *l, int depth, NSMutableArray *out) {
    if (!l || depth > 64) return;
    for (id f in l.filters) if (ggIsGlass(f)) {
        [out addObject:[NSString stringWithFormat:@"%p model[%@] pres[%@]", l, ggGlassParams(l), ggGlassParams(l.presentationLayer)]];
        break;
    }
    for (CALayer *s in l.sublayers) ggTraceWalk(s, depth + 1, out);
}

static void ggTraceLine(NSString *path, NSString *s) {
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile]; [h writeData:[s dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile];
}

static void ggTrace(void) {
    const char *home = getenv("GG_HOME");
    NSString *dir = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Library/Logs/GoldenGate"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path = [dir stringByAppendingPathComponent:@"legibility-trace.log"];
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    ggTraceLine(path, [NSString stringWithFormat:@"trace start %@ pid %d\n", NSProcessInfo.processInfo.processName, getpid()]);
    __block NSString *last = nil;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 8 * NSEC_PER_MSEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        double t = CFAbsoluteTimeGetCurrent() - t0;
        if (t > 4.0) {
            ggTraceLine(path, @"trace end\n");
            dispatch_source_cancel(timer);
            return;
        }
        NSMutableArray *rows = [NSMutableArray array];
        Class ctx = NSClassFromString(@"CAContext");
        NSArray *all = [ctx respondsToSelector:@selector(allContexts)] ? [ctx performSelector:@selector(allContexts)] : nil;
        for (id c in all) if ([c respondsToSelector:@selector(layer)]) ggTraceWalk([c performSelector:@selector(layer)], 0, rows);
        NSString *now = [rows componentsJoinedByString:@" | "];
        if (![now isEqualToString:last]) { ggTraceLine(path, [NSString stringWithFormat:@"%.3f %@\n", t, now]); last = now; }
    });
    dispatch_resume(timer);
}

void gg_legibility_recommit(void) {
    void (^work)(void) = ^{
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        Class ctx = NSClassFromString(@"CAContext");
        NSArray *all = [ctx respondsToSelector:@selector(allContexts)] ? [ctx performSelector:@selector(allContexts)] : nil;
        for (id c in all) if ([c respondsToSelector:@selector(layer)]) ggWalk([c performSelector:@selector(layer)], 0);
        [CATransaction commit];
    };
    if ([NSThread isMainThread]) work(); else dispatch_async(dispatch_get_main_queue(), work);
}

// MARK: - Type 12 coordinated notification
// SkyLight 26.6 receives coordinated notifications through a function registered for CGSNotificationType 0x528
// (0x7ff80920919d); it ignores types > 10 (and calls completion at once). ggapp registers in parallel and posts the 27 name
// on SLSCoordinatedLocalNotificationCenter.

typedef void (*GGNotifyProc)(uint32_t type, void *data, uint32_t len, void *ctx);
extern int32_t SLSRegisterNotifyProc(GGNotifyProc proc, uint32_t type, void *ctx);
extern NSNotificationCenter *SLSCoordinatedLocalNotificationCenter(void);
extern mach_port_t SLSCopyCoordinatedDistributedNotificationFencePort(void);
extern int32_t SLSMainConnectionID(void);
// Returns no error code (26.6 0x7ff80955c0d5 ends with coorddistnote_epilogue): on rejection it calls completion inside the
// call; on success it calls it when WindowServer reports done (CGSNotificationType 0x529).
extern void SLSPostCoordinatedDistributedNotificationFenced(int32_t cid, uint32_t type, mach_port_t fence,
                                                            void (^completion)(void), double timeout);

static NSString *const kCoordName = @"kSLSCoordinatedGlassAppearanceSettingsChangeNotificationName";
static const uint32_t kGlassAppearanceType = 12, kCoordNotifyType = 0x528;

static void ggCoordProc(uint32_t type, void *data, uint32_t len, void *ctx) {
    if (!data || len < 4) return;
    uint32_t kind; memcpy(&kind, data, 4);
    if (kind != kGlassAppearanceType) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [SLSCoordinatedLocalNotificationCenter() postNotificationName:kCoordName object:nil];
    });
}

void gg_legibility_test_receive(const void *data, uint32_t len) { ggCoordProc(kCoordNotifyType, (void *)data, len, NULL); }

/// Like AppKit 27 block 0x18b4c4ee8: re-read, on change post the 27 notification and recommit; entangle: tie the commit to
/// the coordinated notification fence (only when AppKit is present).
static void ggApply(BOOL entangle) {
    if (gg_legibility_needs_update()) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"NSGlassEffectDiffusionDidChangeNotification" object:nil];
        gg_legibility_recommit();
    }
    Class w = NSClassFromString(@"NSCGSWindow");
    SEL sel = NSSelectorFromString(@"entangleUpdateOnFenceRight:");
    if (entangle && [w respondsToSelector:sel]) {
        mach_port_t port = SLSCopyCoordinatedDistributedNotificationFencePort();
        if (port != MACH_PORT_NULL) {
            ((void (*)(id, SEL, mach_port_t))objc_msgSend)(w, sel, port);
            mach_port_deallocate(mach_task_self(), port);
        }
    }
}

/// Writes NSGlassTintAmount (reset: deletes it) like AppKit 27 function 0x18b32a68c.
static void ggWriteTint(float a, bool reset) {
    const char *alt = getenv("GG_PREFS_WRITE");
    NSNumber *v = reset ? nil : @(fminf(fmaxf(a, 0), 1));
    if (alt) {
        NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:@(alt)] ?: [NSMutableDictionary dictionary];
        if (v) d[@"NSGlassTintAmount"] = v; else [d removeObjectForKey:@"NSGlassTintAmount"];
        [d writeToFile:@(alt) atomically:YES];
    } else {
        CFPreferencesSetValue(CFSTR("NSGlassTintAmount"), (__bridge CFNumberRef)v, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    }
}

/// Posts a type 12 coordinated notification with a fence (AppKit 27 0x18b4c4f80).
static int ggPostCoordinated(void (^completion)(int err)) {
    if (getenv("GG_TINT_NOPOST")) { if (completion) completion(0); return 0; }
    id fence = [NSClassFromString(@"CAFenceHandle") performSelector:@selector(newFenceFromDefaultServer)];
    mach_port_t port = fence ? ((mach_port_t (*)(id, SEL))objc_msgSend)(fence, NSSelectorFromString(@"copyPort")) : MACH_PORT_NULL;
    // The block running on this same thread before the function returns = WindowServer rejected it (e.g. type 12 while unpatched).
    __block _Atomic int inCall = 1, rejected = 0;
    pthread_t me = pthread_self();
    SLSPostCoordinatedDistributedNotificationFenced(SLSMainConnectionID(), kGlassAppearanceType, port, ^{
        if (atomic_load(&inCall) && pthread_equal(pthread_self(), me)) atomic_store(&rejected, 1);
        else if (completion) completion(0);
    }, 0.5);
    atomic_store(&inCall, 0);
    if (port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    if (fence) ((void (*)(id, SEL))objc_msgSend)(fence, NSSelectorFromString(@"invalidate"));
    int err = atomic_load(&rejected) ? -1 : 0;
    if (err && completion) completion(err);
    return err;
}

int GGGlassSetSystemLegibility(float a, bool reset, void (^completion)(int err)) {
    ggWriteTint(a, reset);
    return ggPostCoordinated(completion);
}

void GGGlassPreviewSystemLegibility(float a, bool reset) {
    ggWriteTint(a, reset);
    ggApply(NO);   // 27 0x18b31ef24: only a local post of NSGlassEffectDiffusionDidChangeNotification, this process rebuilds itself
}

int GGGlassCommitSystemLegibility(void (^completion)(int err)) {
    return ggPostCoordinated(completion);   // 27 0x18b31efc8: the value written during preview, broadcast to every app
}

static const char *gLegState = "loaded";
const char *gg_legibility_state(void) { return gLegState; }

void gg_legibility_install(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLegState = "installed";
        gg_legibility_current();
        Method m = class_getInstanceMethod([CALayer class], @selector(setFilters:));
        gOrigSetFilters = method_setImplementation(m, (IMP)ggSetFilters);
        gg_recipe_install();
        SLSRegisterNotifyProc(ggCoordProc, kCoordNotifyType, NULL);
        static int dumpToken;
        notify_register_dispatch("com.goldengate.legibility.dump", &dumpToken, dispatch_get_main_queue(), ^(int t) { ggDump(); });
        static int traceToken;
        notify_register_dispatch("com.goldengate.legibility.trace", &traceToken, dispatch_get_main_queue(), ^(int t) { ggTrace(); });
        [SLSCoordinatedLocalNotificationCenter() addObserverForName:kCoordName object:nil queue:nil
                                                         usingBlock:^(NSNotification *n) { ggApply(YES); }];
        // WindowServer only delivers to apps with visible windows: catch up when the app becomes active or a window is uncovered.
        for (NSString *name in @[@"NSApplicationDidBecomeActiveNotification", @"NSWindowDidChangeOcclusionStateNotification"])
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                          usingBlock:^(NSNotification *n) { ggApply(NO); }];
    });
}

/// System processes where GGAppLoader loads GGLegibility directly (no GGApp, no AppKit). Must match the list in Stage1.c.
const char *const gg_system_ui_apps[] = {"/Dock.app/Contents/MacOS/", "/ControlCenter.app/Contents/MacOS/",
                                         "/NotificationCenter.app/Contents/MacOS/", "/SystemUIServer.app/Contents/MacOS/",
                                         "/Spotlight.app/Contents/MacOS/", 0};

__attribute__((constructor)) static void ggLegibilityInit(void) {
    char exe[PATH_MAX]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return;
    BOOL sys = NO;
    for (int i = 0; gg_system_ui_apps[i]; i++) if (strstr(exe, gg_system_ui_apps[i])) sys = YES;
    if (!sys) return;   // regular apps: GGApp.dylib calls gg_legibility_install per GGApp.legibility
    @autoreleasepool {
        const char *alt = getenv("GG_PREFS");
        NSDictionary *s = alt ? [NSDictionary dictionaryWithContentsOfFile:@(alt)]
                              : [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
        id systemUI = s[@"GGApp.systemUI"];
        BOOL on = (systemUI ? [systemUI boolValue] : YES) && ![s[@"GGApp.disable"] boolValue];
        gLegState = on ? "installed" : "systemui:off";
        if (on) {
            // Crash guard (system processes do not go through GGApp): counts launches that did not live past 60 s; at 3
            // it stops installing. Same guard directory as GGApp, cleared by `ggapp on`.
            const char *home = getenv("GG_HOME");
            NSString *dir = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Library/Logs/GoldenGate/guard"];
            NSString *file = [dir stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"%@.legibility-boots", @(exe).stringByDeletingLastPathComponent
                                                                                     .stringByDeletingLastPathComponent
                                                                                     .stringByDeletingLastPathComponent.lastPathComponent]];
            int boots = [[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil] intValue];
            if (boots >= 3) { gLegState = "systemui:guard"; return; }
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [@(boots + 1).stringValue writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [@"0" writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
            });
        }
        // Install on the first run loop pass (do not call SkyLight in the constructor, before the process has a WindowServer connection).
        if (on) dispatch_async(dispatch_get_main_queue(), ^{ gg_legibility_install(); });
    }
}
