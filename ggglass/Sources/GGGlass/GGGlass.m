// GGGlass: replaces QuartzCore 26.6's glass functions with an adapter of the 27 algorithm (glass-harness/shaders/glass26_replica.metal).
//
// Loaded into the process via DYLD_INSERT_LIBRARIES. Swizzles the function-creation APIs of every MTLLibrary class; when
// the function name is in the replacement table (same content as glass-harness/shaders/gg27-entries.txt) it returns our
// function, compiled from source at runtime and specialized with function constants. Every error path returns the original.
//
// Safety:
// - only runs on build 25G72 (sysctl kern.osversion);
// - does nothing if <root>/disable exists or settings enabled = false;
// - crash guard: on the 3rd consecutive load with none surviving 120 s, creates <root>/disable by itself.
//
// <root> = $GG_ROOT or /Users/Shared/GoldenGate; shader source = $GG_SOURCE or /Library/GoldenGate/gg27.metal;
// log and boots.plist in $GG_STATE or /Library/Logs/WindowServer/GoldenGate.
// Settings <root>/settings.plist: enabled (Bool), tintAmount (0..1, default 0.5), pixelLength (default 1.0),
// trace (Bool: log every requested function name; also enabled by the GG_TRACE environment variable).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <pwd.h>
#import <stdatomic.h>
#import <os/lock.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>

// gRoot: settings and kill-switch (read-only for WindowServer). gState: log and boots.plist. The WindowServer sandbox
// (/System/Library/Sandbox/Profiles/com.apple.WindowServer.sb) only allows writes to /Library/Logs/WindowServer, /private/tmp
// and caches; the constructor runs as root before the sandbox is applied, so it can create this directory.
static NSString *gRoot, *gState, *gSource;
static BOOL gActive, gTrace, gDebugColor, gDebugSize, gDebugEdge, gDebugScale, gNoHighlight27, gTraceDraws;
static float gTint = 0.5f, gPixelLength = 1.0f;
// Global fallback slider amount (float bits), bound at buffer 28 with the appearance flag; changed at runtime via Darwin notify.
static _Atomic uint32_t gLiveTintBits;
static float ggLiveTint(void) { uint32_t b = atomic_load(&gLiveTintBits); float f; memcpy(&f, &b, 4); return f; }
static void ggSetLiveTint(float f) { uint32_t b; memcpy(&b, &f, 4); atomic_store(&gLiveTintBits, b); }
static NSMutableDictionary<NSString *, NSValue *> *gOriginals;   // "Class/selector" -> original IMP
static NSMutableDictionary<NSString *, id<MTLFunction>> *gCache; // Apple name -> replacement function
static id<MTLLibrary> gOurLib;
static dispatch_group_t gCompile, gWarmGroup;
static NSLock *gLock, *gOrigLock;
static BOOL gDumpUniforms;
static void ggInstallDump(id<MTLDevice> dev);
static void ggInstallLiveAppearance(id<MTLDevice> dev);

// Replacement table: Apple function name -> our function name (same as shaders/gg27-entries.txt).
static NSString *ggReplacementName(NSString *apple) {
    static NSDictionary *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{ @"glass_background_sdf_lpf": @"gg27_glass_background_sdf_lpf",
                 @"glass_background_sdf_no_bleed_lpf": @"gg27_glass_background_sdf_no_bleed_lpf",
                 @"glass_background_sdf_lph": @"gg27_glass_background_sdf_lph",
                 @"glass_background_sdf_no_bleed_lph": @"gg27_glass_background_sdf_no_bleed_lph",
                 // Texture SDF variants: QuartzCore uses them for large glass and while the shape changes (Dock
                 // magnification, button hover, menu redraw regions). Without them the same glass flickers between 27 and 26.6.
                 @"glass_background_lpf": @"gg27_glass_background_lpf",
                 @"glass_background_no_bleed_lpf": @"gg27_glass_background_no_bleed_lpf",
                 @"glass_background_lph": @"gg27_glass_background_lph",
                 @"glass_background_no_bleed_lph": @"gg27_glass_background_no_bleed_lph" };
    });
    return apple ? map[apple] : nil;
}

// WindowServer runs the constructor as root, then drops to _windowserver; files we create must be writable by every user.
static void ggShare(NSString *path) { chmod(path.fileSystemRepresentation, 0666); }

static void ggLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ [%d] %@\n", [NSDate date], getpid(), msg];
    NSString *path = [gState stringByAppendingPathComponent:@"ggglass.log"];
    // O_APPEND: each line is one intact appending write, so concurrent threads do not overwrite each other
    // (seekToEndOfFile then write used to truncate lines in the WindowServer log).
    BOOL existed = [[NSFileManager defaultManager] fileExistsAtPath:path];
    FILE *f = fopen(path.fileSystemRepresentation, "a");
    if (!f) return;
    fputs(line.UTF8String, f);
    fclose(f);
    if (!existed) ggShare(path);
}

static NSString *ggBuild(void) {
    const char *fake = getenv("GG_FAKE_BUILD");
    if (fake) return @(fake);
    char buf[32] = {0}; size_t n = sizeof buf;
    return sysctlbyname("kern.osversion", buf, &n, NULL, 0) == 0 ? @(buf) : @"";
}

/// Crash guard: boots.plist keeps the consecutive loads that did not survive 120 s (no limit on spacing, to also catch
/// panic-and-reboot loops longer than 120 s). Returns NO if it disabled itself.
static BOOL ggCrashGuard(void) {
    NSString *path = [gState stringByAppendingPathComponent:@"boots.plist"];
    NSMutableArray *recent = [NSMutableArray array];
    for (NSDate *d in [NSArray arrayWithContentsOfFile:path] ?: @[])
        if ([d isKindOfClass:[NSDate class]]) [recent addObject:d];
    [recent addObject:[NSDate date]];
    // If the history cannot be written the crash guard cannot protect: do not enable.
    if (![recent writeToFile:path atomically:YES]) { ggLog(@"crash guard: cannot write %@, not enabling", path); return NO; }
    ggShare(path);
    if (recent.count >= 3) {
        [[NSFileManager defaultManager] createFileAtPath:[gRoot stringByAppendingPathComponent:@"disable"] contents:nil attributes:nil];
        ggLog(@"crash guard: %lu consecutive loads did not survive 120 s, disabling (created disable file)", (unsigned long)recent.count);
        return NO;
    }
    // Survived 120 s: consider it stable, clear the history.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if ([@[] writeToFile:path atomically:YES]) ggShare(path);
        else ggLog(@"crash guard: cannot clear history %@", path);
    });
    return YES;
}

static void ggStartCompile(void);

/// Our library, compiled from source (once, starting at the first request: no Metal device is created at load time,
/// while WindowServer is still initializing and drivers are loading). Waits up to 5 s if a background compile is running.
static id<MTLLibrary> ggOurLibrary(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ggStartCompile(); });
    if (dispatch_group_wait(gCompile, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) != 0) {
        ggLog(@"compile wait exceeded 5 s, using the original function");
        return nil;
    }
    return gOurLib;
}

static void ggWarm(void);

/// <shader>.metallib (precompiled by ggglass/build.sh) if present and not older than <shader>.metal; nil if source must be compiled.
/// Reinstalling only the .metal (stale metallib left over) makes the metallib older: compile source so the old shader never runs.
static NSString *ggMetallibPath(void) {
    NSString *path = [[gSource stringByDeletingPathExtension] stringByAppendingPathExtension:@"metallib"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *lib = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
    NSDate *src = [fm attributesOfItemAtPath:gSource error:nil].fileModificationDate;
    return lib && (!src || [lib compare:src] != NSOrderedAscending) ? path : nil;
}

static void ggStartCompile(void) {
    dispatch_group_enter(gCompile);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        NSError *e = nil;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLLibrary> lib = nil;
        NSString *mpath = ggMetallibPath();
        if (mpath) {
            lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:mpath] error:&e];
            if (lib) ggLog(@"loaded metallib %@ (%.0f ms)", mpath, (CFAbsoluteTimeGetCurrent() - t) * 1000);
            else ggLog(@"cannot load metallib %@: %@", mpath, e.localizedDescription);
        }
        if (!lib) {
            ggLog(@"compiling %@", gSource);
            t = CFAbsoluteTimeGetCurrent();
            NSString *src = [NSString stringWithContentsOfFile:gSource encoding:NSUTF8StringEncoding error:&e];
            lib = src ? [dev newLibraryWithSource:src options:nil error:&e] : nil;
            if (lib) ggLog(@"compiled %@ (%.0f ms)", gSource, (CFAbsoluteTimeGetCurrent() - t) * 1000);
            else ggLog(@"cannot compile %@: %@", gSource, e.localizedDescription ?: @"missing file");
        }
        gOurLib = lib;
        if (lib) dispatch_group_enter(gWarmGroup);   // before releasing gCompile: any later request sees warm-up in progress
        dispatch_group_leave(gCompile);
        if (lib) { ggWarm(); dispatch_group_leave(gWarmGroup); }
    });
}

/// Appearance file: .GlobalPreferences of the logged-in user (owner of /dev/console); GG_GLOBAL_PREFS overrides it for tests.
static NSString *ggPrefsPath(void) {
    const char *env = getenv("GG_GLOBAL_PREFS");
    if (env) return @(env);
    struct stat st;
    struct passwd *pw = stat("/dev/console", &st) == 0 && st.st_uid != 0 ? getpwuid(st.st_uid) : NULL;
    return pw ? [@(pw->pw_dir) stringByAppendingPathComponent:@"Library/Preferences/.GlobalPreferences.plist"] : nil;
}

/// System appearance is dark: AppleInterfaceStyle = Dark.
static BOOL ggSystemDark(void) {
    NSString *path = ggPrefsPath();
    return path && [[NSDictionary dictionaryWithContentsOfFile:path][@"AppleInterfaceStyle"] isEqual:@"Dark"];
}

// Current appearance flag (1 = dark) that the pipeline-bind hook puts into shader buffer 28: read at startup, then follows
// the Dock. Only a fallback for adaptive glass that carries no appearance of its own (processes without ggapp): as in 27,
// recognized glass takes its appearance from the face itself, and adaptive glass with ggapp takes it from the negative code
// in preserve_hue (the view's effectiveAppearance).
static _Atomic uint32_t gSysDarkFlag;

/// The 26.6 highlight layer (CASDFKeyFillHighlightEffect: white alpha 1 when the window is key, alpha 0 otherwise) is drawn
/// by QuartzCore's uber shader: fixed_frag_* with constant 28 (fc_texture_function) = 66 (UberShader::sdf_key_fill_highlight,
/// AIR 26.6). It draws over the glass edge, covering the dark 27 ring in white; the 27 highlight is already drawn in the glass
/// shader. Constants are read via the private API of MTLFunctionConstantValuesInternal (newIndexedConstantArray /
/// newNamedConstantArray: index or name, dataType, data); without that API it is not recognized (Apple function kept).
/// First byte of function constant `index` (or name `name`) of type `type` in `cv`; -1 if absent or of another type.
static int ggConstantByte(MTLFunctionConstantValues *cv, NSUInteger index, NSString *name, MTLDataType type) {
    if (!cv) return -1;
    typedef NSArray *(*NewArray)(id, SEL) __attribute__((ns_returns_retained));
    for (NSString *selName in @[@"newIndexedConstantArray", @"newNamedConstantArray"]) {
        SEL s = NSSelectorFromString(selName);
        if (![cv respondsToSelector:s]) continue;
        BOOL indexed = [selName hasPrefix:@"newIndexed"];
        for (id c in ((NewArray)objc_msgSend)(cv, s)) {
            BOOL hit = indexed ? ([c respondsToSelector:@selector(index)] && ((NSUInteger (*)(id, SEL))objc_msgSend)(c, @selector(index)) == index)
                               : ([c respondsToSelector:@selector(name)] && [((id (*)(id, SEL))objc_msgSend)(c, @selector(name)) isEqual:name]);
            if (!hit || ![c respondsToSelector:@selector(dataType)] || ![c respondsToSelector:@selector(data)]) continue;
            if (((NSUInteger (*)(id, SEL))objc_msgSend)(c, @selector(dataType)) != type) return -1;
            const uint8_t *d = ((const void *(*)(id, SEL))objc_msgSend)(c, @selector(data));
            return d ? d[0] : -1;
        }
    }
    return -1;
}

static BOOL ggKeyFillHighlight(NSString *name, MTLFunctionConstantValues *cv) {
    return [name hasPrefix:@"fixed_frag_"] && ggConstantByte(cv, 28, @"fc_texture_function", MTLDataTypeUChar) == 66;
}

// MARK: - 26.6 highlight via the generic uber shader
// The generic uber shader (constant 0 fc_generic = true) reads FragmentShaderConfig (52 bytes) at fragment buffer 0 at draw
// time: two packed 16-byte Images, field 1 at byte 32, texture function at byte 33 (AIR 26.6 m004). This variant cannot be
// replaced by the name table; any draw with texture function 66 (key/fill highlight) is skipped. Generic pipelines/functions
// are few (a handful per session); read without locking on the draw path, like gOurPSOs.
static void *gGenericFns[16], *gGenericPSOs[64];
static _Atomic int gGenericFnCount, gGenericPSOCount, gSkipCount;
static os_unfair_lock gGenericLock = OS_UNFAIR_LOCK_INIT;
static __thread BOOL tGenericBound;   // a generic uber pipeline is bound on this thread's encoder
static __thread BOOL tOurPSOBound;    // one of our glass pipelines is bound (also used by the sdf_texture capture)
static __thread int tCfgFn = -1;      // texture function of the config bound at fragment buffer 0
static __thread void *tCfgBuf;

static BOOL ggInList(void **list, _Atomic int *count, const void *p) {
    int n = atomic_load(count);
    for (int i = 0; i < n; i++) if (list[i] == p) return YES;
    return NO;
}

static void ggAddToList(void **list, _Atomic int *count, int cap, id obj) {
    os_unfair_lock_lock(&gGenericLock);
    int n = atomic_load(count);
    if (n < cap && !ggInList(list, count, (__bridge void *)obj)) { list[n] = (__bridge_retained void *)obj; atomic_store(count, n + 1); }
    os_unfair_lock_unlock(&gGenericLock);
}

// MARK: - traceDraws (diagnostics)
// Logs the sequence of up to 6 draws right after each of our glass draws on the same encoder (label = fragment function
// name; uber with its texture function), one line per distinct sequence, at most 100 lines: shows what WindowServer draws
// over the glass.
static NSMutableDictionary<NSValue *, NSString *> *gTags;   // function / pipeline -> label
static NSMutableSet<NSString *> *gSeqSeen;
static __thread void *tCurTag;   // label of the bound pipeline (owned by gTags)
static __thread void *tSeq;      // NSMutableString being recorded (manually retained), or NULL
static __thread int tSeqLeft;

static void ggTag(id obj, NSString *tag) {
    if (!obj || !tag) return;
    [gLock lock]; gTags[[NSValue valueWithPointer:(__bridge void *)obj]] = tag; [gLock unlock];
}

static NSString *ggTagOf(id obj) {
    [gLock lock]; NSString *t = gTags[[NSValue valueWithPointer:(__bridge void *)obj]]; [gLock unlock];
    return t;
}

static void ggFlushSeq(void) {
    if (!tSeq) return;
    NSString *s = CFBridgingRelease(tSeq);
    tSeq = NULL; tSeqLeft = 0;
    [gLock lock];
    BOOL fresh = gSeqSeen.count < 100 && ![gSeqSeen containsObject:s];
    if (fresh) [gSeqSeen addObject:s];
    [gLock unlock];
    if (fresh) ggLog(@"after glass: %@", s);
}

static void ggTraceDraw(BOOL ourPSO, BOOL generic, int cfgFn) {
    if (!gTraceDraws) return;
    NSString *cur = tCurTag ? (__bridge NSString *)tCurTag : @"?";
    if (generic) cur = [NSString stringWithFormat:@"%@(generic, tf %d)", cur, cfgFn];
    if (ourPSO) { ggFlushSeq(); tSeq = (void *)CFBridgingRetain([NSMutableString stringWithString:cur]); tSeqLeft = 6; return; }
    if (!tSeq) return;
    [(__bridge NSMutableString *)tSeq appendFormat:@" -> %@", cur];
    if (--tSeqLeft == 0) ggFlushSeq();
}

/// Records a generic uber function Apple just created (to recognize pipelines using it); with traceDraws, labels uber functions.
static void ggNoteGeneric(NSString *name, MTLFunctionConstantValues *cv, id fn) {
    if (!gActive || !fn || ![name hasPrefix:@"fixed_frag_"]) return;
    BOOL generic = ggConstantByte(cv, 0, @"fc_generic", MTLDataTypeBool) == 1;
    if (gTraceDraws) ggTag(fn, generic ? name : [NSString stringWithFormat:@"%@(tf %d)", name, ggConstantByte(cv, 28, @"fc_texture_function", MTLDataTypeUChar)]);
    if (!generic) return;
    ggAddToList(gGenericFns, &gGenericFnCount, 16, fn);
    ggLog(@"uber generic: %@ (watching for 26.6 highlight draws)", name);
}

static int ggCfgByte(id<MTLBuffer> buf, NSUInteger offset) {
    const uint8_t *p = buf.contents;
    return p && offset + 33 < buf.length ? p[offset + 33] : -1;
}

/// Skips the current draw if it is the 26.6 highlight via the generic uber shader (the original draw is not called).
static BOOL ggSkipDraw(void) {
    ggTraceDraw(tOurPSOBound, tGenericBound, tCfgFn);
    if (!tGenericBound || tCfgFn != 66) return NO;
    int n = atomic_fetch_add(&gSkipCount, 1) + 1;
    if (n <= 20) ggLog(@"skip 26.6 highlight draw (uber generic, texture function 66)%@", n == 20 ? @", no further logging" : @"");
    return YES;
}

static NSString *const kNoKFHighlight = @"gg_no_kf_highlight";

/// Builds the replacement specialized for Apple name `name` (or kNoKFHighlight) from `lib` and stores it in gCache.
/// Function constants only hold values fixed for the session: tint (27) and appearance (46) are not baked in because the
/// shader reads them at runtime from buffer 28 (GGLive, constant 47 on); baking them in would make every startup with a
/// different tint/appearance a different function, missing Metal's disk cache and forcing WindowServer to recompile the
/// function and pipeline (0.2-1.2 s each) on the draw path.
static id<MTLFunction> ggSpecialize(id<MTLLibrary> lib, NSString *name) {
    NSError *e = nil;
    if ([name isEqualToString:kNoKFHighlight]) {
        id<MTLFunction> none = [lib newFunctionWithName:kNoKFHighlight constantValues:[MTLFunctionConstantValues new] error:&e];
        if (!none) { ggLog(@"cannot create gg_no_kf_highlight: %@", e.localizedDescription); return nil; }
        [gLock lock]; gCache[name] = none; [gLock unlock];
        return none;
    }
    NSString *ours = ggReplacementName(name);
    MTLFunctionConstantValues *fc = [MTLFunctionConstantValues new];
    float pl = gPixelLength, headroom = 1;
    [fc setConstantValue:&pl type:MTLDataTypeFloat atIndex:36];
    [fc setConstantValue:&headroom type:MTLDataTypeFloat atIndex:40];
    BOOL debug = gDebugColor, debugSize = gDebugSize, debugEdge = gDebugEdge, debugScale = gDebugScale;
    if (debugScale) [fc setConstantValue:&debugScale type:MTLDataTypeBool atIndex:49];
    BOOL noHl = gNoHighlight27;
    if (noHl) [fc setConstantValue:&noHl type:MTLDataTypeBool atIndex:50];
    if (debug) [fc setConstantValue:&debug type:MTLDataTypeBool atIndex:42];
    if (debugSize) [fc setConstantValue:&debugSize type:MTLDataTypeBool atIndex:45];
    if (debugEdge) [fc setConstantValue:&debugEdge type:MTLDataTypeBool atIndex:48];
    BOOL sysDark = atomic_load(&gSysDarkFlag) != 0, useFlag = YES;
    [fc setConstantValue:&useFlag type:MTLDataTypeBool atIndex:47];   // appearance and tint read from buffer 28 (live)
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    id<MTLFunction> fn = [lib newFunctionWithName:ours constantValues:fc error:&e];
    if (!fn) { ggLog(@"cannot create %@: %@", ours, e.localizedDescription); return nil; }
    ggLog(@"replace %@ -> %@ (tint %.2f, pixelLength %.2f, %.0f ms%@)", name, ours, ggLiveTint(), pl, (CFAbsoluteTimeGetCurrent() - t) * 1000,
          [NSString stringWithFormat:@"%@%@%@%@%@, %@ appearance", debug ? @", debugColor" : @"", debugSize ? @", debugSize" : @"",
                                     debugEdge ? @", debugEdge" : @"", debugScale ? @", debugScale" : @"",
                                     noHl ? @", noHighlight27" : @"", sysDark ? @"dark" : @"light"]);
    [gLock lock];
    gCache[name] = fn;
    [gLock unlock];
    return fn;
}

/// Warm-up (background thread, right after the library exists at the first request): prebuilds every replacement so that
/// when QuartzCore asks (opening the Dock, Control Center) it is returned from gCache, with no specialization on the draw path.
static void ggWarm(void) {
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    NSArray *names = [@[kNoKFHighlight] arrayByAddingObjectsFromArray:@[
        @"glass_background_sdf_lpf", @"glass_background_sdf_no_bleed_lpf", @"glass_background_sdf_lph",
        @"glass_background_sdf_no_bleed_lph", @"glass_background_lpf", @"glass_background_no_bleed_lpf",
        @"glass_background_lph", @"glass_background_no_bleed_lph"]];
    __block _Atomic int made = 0;
    dispatch_apply(names.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
        [gLock lock]; BOOL have = gCache[names[i]] != nil; [gLock unlock];
        if (have || ggSpecialize(gOurLib, names[i])) atomic_fetch_add(&made, 1);
    });
    ggLog(@"warm-up done (%d/%lu functions, %.0f ms)", atomic_load(&made), (unsigned long)names.count, (CFAbsoluteTimeGetCurrent() - t) * 1000);
}

/// The built function (gCache) for `name`; while warm-up runs, waits (up to 5 s) instead of building a duplicate; otherwise builds it.
static id<MTLFunction> ggCachedOrSpecialize(NSString *name) {
    [gLock lock]; id<MTLFunction> fn = gCache[name]; [gLock unlock];
    if (fn) return fn;
    id<MTLLibrary> lib = ggOurLibrary();
    if (!lib) return nil;
    dispatch_group_wait(gWarmGroup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    [gLock lock]; fn = gCache[name]; [gLock unlock];
    return fn ?: ggSpecialize(lib, name);
}

/// Replacement for `name` (nil if not replaced). `cv`: function constants passed by QuartzCore (nil if none).
static id<MTLFunction> ggReplacement(id<MTLLibrary> from, NSString *name, MTLFunctionConstantValues *cv) {
    if (!gActive) return nil;
    if (gTrace) ggLog(@"requested %@", name);
    if (gDumpUniforms && [name containsString:@"glass_"]) ggInstallDump(from.device);
    if (ggKeyFillHighlight(name, cv)) {
        id<MTLFunction> none = ggCachedOrSpecialize(kNoKFHighlight);
        if (none) ggLog(@"drop 26.6 highlight: %@ (constant 28 = 66) -> gg_no_kf_highlight", name);
        return none;
    }
    if (!ggReplacementName(name)) return nil;
    ggInstallLiveAppearance(from.device);
    return ggCachedOrSpecialize(name);
}

static IMP ggOriginal(id self, SEL sel) {
    IMP imp = NULL;
    [gOrigLock lock];   // diagnostic hooks may be installed while another thread is looking up the table
    for (Class c = object_getClass(self); c && !imp; c = class_getSuperclass(c)) {
        NSValue *v = gOriginals[[NSString stringWithFormat:@"%s/%s", class_getName(c), sel_getName(sel)]];
        if (v) imp = (IMP)v.pointerValue;
    }
    [gOrigLock unlock];
    return imp;
}

// MARK: - Replacement implementations
// The "newFunction..." selectors belong to the new family: the caller receives a +1 object. The replacements and the
// pointer types to the originals must be declared ns_returns_retained, otherwise ARC returns +0 and the object is over-released.
#define GG_RETAINED __attribute__((ns_returns_retained))
typedef id (*NewByName)(id, SEL, NSString *) GG_RETAINED;
typedef id (*NewByNameCV)(id, SEL, NSString *, MTLFunctionConstantValues *, NSError **) GG_RETAINED;
typedef id (*NewByDesc)(id, SEL, MTLFunctionDescriptor *, NSError **) GG_RETAINED;

static id ggNewFunctionWithName(id self, SEL sel, NSString *name) GG_RETAINED;
static id ggNewFunctionWithName(id self, SEL sel, NSString *name) {
    id<MTLFunction> r = ggReplacement(self, name, nil);
    if (r) return r;
    return ((NewByName)ggOriginal(self, sel))(self, sel, name);
}

static id ggNewFunctionWithNameConstants(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) GG_RETAINED;
static id ggNewFunctionWithNameConstants(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv, NSError **err) {
    id<MTLFunction> r = ggReplacement(self, name, cv);
    if (r) return r;
    id fn = ((NewByNameCV)ggOriginal(self, sel))(self, sel, name, cv, err);
    ggNoteGeneric(name, cv, fn);
    return fn;
}

static void ggNewFunctionWithNameConstantsAsync(id self, SEL sel, NSString *name, MTLFunctionConstantValues *cv,
                                                void (^done)(id<MTLFunction>, NSError *)) {
    id<MTLFunction> r = ggReplacement(self, name, cv);
    if (r) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ done(r, nil); }); return; }
    void (^noted)(id<MTLFunction>, NSError *) = ^(id<MTLFunction> f, NSError *e) { ggNoteGeneric(name, cv, f); done(f, e); };
    ((void (*)(id, SEL, NSString *, MTLFunctionConstantValues *, id))ggOriginal(self, sel))(self, sel, name, cv, noted);
}

static id ggNewFunctionWithDescriptor(id self, SEL sel, MTLFunctionDescriptor *d, NSError **err) GG_RETAINED;
static id ggNewFunctionWithDescriptor(id self, SEL sel, MTLFunctionDescriptor *d, NSError **err) {
    id<MTLFunction> r = ggReplacement(self, d.name, d.constantValues);
    if (r) return r;
    id fn = ((NewByDesc)ggOriginal(self, sel))(self, sel, d, err);
    ggNoteGeneric(d.name, d.constantValues, fn);
    return fn;
}

static void ggNewFunctionWithDescriptorAsync(id self, SEL sel, MTLFunctionDescriptor *d, void (^done)(id<MTLFunction>, NSError *)) {
    id<MTLFunction> r = ggReplacement(self, d.name, d.constantValues);
    if (r) { dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ done(r, nil); }); return; }
    NSString *name = d.name; MTLFunctionConstantValues *cv = d.constantValues;
    void (^noted)(id<MTLFunction>, NSError *) = ^(id<MTLFunction> f, NSError *e) { ggNoteGeneric(name, cv, f); done(f, e); };
    ((void (*)(id, SEL, MTLFunctionDescriptor *, id))ggOriginal(self, sel))(self, sel, d, noted);
}

typedef struct { SEL sel; IMP imp; } GGHook;

/// Swizzles every class conforming to `proto` that has its own implementation (declared on the class itself) of the
/// selectors in `hooks`. Returns the number of methods replaced. Subclasses that only inherit go through the superclass
/// (ggOriginal walks the class tree).
static int ggSwizzleProtocol(Protocol *proto, const GGHook *hooks, size_t nhooks) {
    unsigned count = 0;
    Class *classes = objc_copyClassList(&count);
    int swizzled = 0;
    for (unsigned i = 0; i < count; i++) {
        Class c = classes[i];
        // Only classes that declare the protocol themselves (_MTLLibrary, _MTLMLLibrary, MTLToolsLibrary): no parent-child
        // pair is hooked together, so a subclass calling [super ...] cannot make ggOriginal (walking from the object's
        // class) call itself again.
        if (!class_conformsToProtocol(c, proto)) continue;
        unsigned n = 0;
        Method *ms = class_copyMethodList(c, &n);
        for (size_t k = 0; k < nhooks; k++)
            for (unsigned j = 0; j < n; j++) if (method_getName(ms[j]) == hooks[k].sel) {
                NSString *key = [NSString stringWithFormat:@"%s/%s", class_getName(c), sel_getName(hooks[k].sel)];
                [gOrigLock lock];
                BOOL todo = !gOriginals[key];   // never swizzle twice (the original IMP would become the hook itself: infinite recursion)
                // Save the original IMP before swapping: another thread may enter the hook right after method_setImplementation.
                if (todo) gOriginals[key] = [NSValue valueWithPointer:(void *)method_getImplementation(ms[j])];
                [gOrigLock unlock];
                if (todo) { method_setImplementation(ms[j], hooks[k].imp); swizzled++; }
                break; }
        free(ms);
    }
    free(classes);
    return swizzled;
}

static void ggSwizzleLibraries(void) {
    GGHook hooks[] = {
        { @selector(newFunctionWithName:), (IMP)ggNewFunctionWithName },
        { @selector(newFunctionWithName:constantValues:error:), (IMP)ggNewFunctionWithNameConstants },
        { @selector(newFunctionWithName:constantValues:completionHandler:), (IMP)ggNewFunctionWithNameConstantsAsync },
        { @selector(newFunctionWithDescriptor:error:), (IMP)ggNewFunctionWithDescriptor },
        { @selector(newFunctionWithDescriptor:completionHandler:), (IMP)ggNewFunctionWithDescriptorAsync },
    };
    ggLog(@"swizzled %d methods on MTLLibrary classes", ggSwizzleProtocol(@protocol(MTLLibrary), hooks, 5));
}

// MARK: - dumpUniforms diagnostics
// Logs the distinct uniform sets QuartzCore binds (buffer index 1) for pipelines with a glass_* fragment, to tune
// classify_glass26 against real values inside WindowServer. Only installed when settings dumpUniforms = true.
// Simplification: the current pipeline state is kept per thread (QuartzCore uses an encoder on one thread); enough for diagnostics.
static NSMutableDictionary<NSValue *, NSString *> *gGlassPipelines;   // pipeline -> Apple function name
static NSMutableDictionary<NSString *, NSMutableSet<NSData *> *> *gDumped;   // function name -> sets already logged
static __thread void *tGlassName;   // NSString (owned by gGlassPipelines) of the bound pipeline, or NULL
static __thread void *tBuffer1;     // MTLBuffer bound at index 1

// Pipelines using our replacements (to bind the appearance flag). Few (a few dozen per session); read without locking on the draw path.
// Simplification: at most 128 pipelines; beyond that new pipelines get no flag (the shader reads the encoder's stale buffer 28).
static void *gOurPSOs[128];
static _Atomic int gOurPSOCount;
static os_unfair_lock gOurPSOLock = OS_UNFAIR_LOCK_INIT;

static BOOL ggIsOurPSO(id pso) {
    int n = atomic_load(&gOurPSOCount);
    for (int i = 0; i < n; i++) if (gOurPSOs[i] == (__bridge void *)pso) return YES;
    return NO;
}

typedef id (*NewPSO)(id, SEL, MTLRenderPipelineDescriptor *, NSError **) GG_RETAINED;
static id ggNewPSO(id self, SEL sel, MTLRenderPipelineDescriptor *d, NSError **err) GG_RETAINED;
static id ggNewPSO(id self, SEL sel, MTLRenderPipelineDescriptor *d, NSError **err) {
    CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
    id pso = ((NewPSO)ggOriginal(self, sel))(self, sel, d, err);
    if (pso && d.fragmentFunction && ggInList(gGenericFns, &gGenericFnCount, (__bridge void *)d.fragmentFunction))
        ggAddToList(gGenericPSOs, &gGenericPSOCount, 64, pso);
    if (gTraceDraws && pso) ggTag(pso, ggTagOf(d.fragmentFunction) ?: d.fragmentFunction.name);
    NSString *name = d.fragmentFunction.name;
    if (pso && [name hasPrefix:@"gg27_"]) {
        os_unfair_lock_lock(&gOurPSOLock);
        int n = atomic_load(&gOurPSOCount);
        if (n < 128 && !ggIsOurPSO(pso)) { gOurPSOs[n] = (__bridge_retained void *)pso; atomic_store(&gOurPSOCount, n + 1); }
        os_unfair_lock_unlock(&gOurPSOLock);
        name = [name substringFromIndex:5];
    }
    if (pso && [name containsString:@"glass_"]) {
        [gLock lock]; gGlassPipelines[[NSValue valueWithPointer:(__bridge void *)pso]] = name; [gLock unlock];
        // A replacement pipeline missing from Metal's disk cache (shader or constants just changed) compiles for 0.2-1.2 s
        // on WindowServer's main thread; binary archives do not match on this Intel driver. Log the time to correlate with
        // moments when glass renders wrong (gray dialog right after it appears).
        ggLog(@"pipeline %@: %.0f ms, pixelFormat %lu, %@", name, (CFAbsoluteTimeGetCurrent() - t) * 1000,
              (unsigned long)d.colorAttachments[0].pixelFormat, [NSThread isMainThread] ? @"main" : @"bg");
    }
    return pso;
}

static void ggDump(NSUInteger offset) {
    id<MTLBuffer> b = (__bridge id<MTLBuffer>)tBuffer1;
    const uint8_t *p = b.contents;
    if (!tGlassName || !p || offset >= b.length) return;
    NSString *name = (__bridge NSString *)tGlassName;
    NSUInteger n = MIN((NSUInteger)272, b.length - offset);
    // Deduplicate by the face matrix (face_cm0..2, 24 bytes at offset 80 of the glass part; the sdf variant has 48 bytes
    // of SdfFragmentUniforms before it): one line per recipe per function. Deduplicating on all bytes lets glass that
    // moves every frame (lock screen clock) fill every slot before other recipes get a chance to appear.
    NSUInteger fo = ([name containsString:@"_sdf_"] ? 48 : 0) + 80;
    if (n < fo + 24) return;
    // Rounding: drop the 4 low mantissa bits of the 12 halfs (under ~1.6% difference), so the steps of a moving glass
    // (face changing gradually each frame) collapse into one instead of taking every slot from other recipes.
    uint16_t q[12];
    memcpy(q, p + offset + fo, sizeof q);
    for (int i = 0; i < 12; i++) q[i] &= 0xFFF0;
    NSData *key = [NSData dataWithBytes:q length:sizeof q];
    [gLock lock];
    NSMutableSet *seen = gDumped[name] ?: (gDumped[name] = [NSMutableSet set]);   // at most 64 faces per function
    BOOL fresh = seen.count < 64 && ![seen containsObject:key];
    if (fresh) [seen addObject:key];
    [gLock unlock];
    if (!fresh) return;
    // Full hex (exact): uniforms mix float and half, so no decimal printing.
    NSMutableString *hex = [NSMutableString stringWithCapacity:n * 2];
    for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", p[offset + i]];
    ggLog(@"uniform %@ off %lu hex: %@", name, (unsigned long)offset, hex);
}

// MARK: - Capture real sdf_texture (once)
// The Settings toolbar button has a white rim on the machine, but the harness (self-built sdf_texture) always has the
// dark ring: capture the real sdf_texture and uniforms of texture-variant glass to rebuild them exactly in the harness.
// Only in the first session (directory <state>/sdf-capture absent), at most 24 distinct sets (by texture size + face),
// copied on a background thread.
static BOOL gCaptureOn;
static NSString *gCaptureDir;
static NSMutableSet<NSString *> *gCaptureKeys;
static __thread void *tCapTex, *tCapBuf;
static __thread NSUInteger tCapOff;

static NSUInteger ggBytesPerPixel(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatRGBA32Float: return 16;
        case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: return 8;
        case MTLPixelFormatRG16Float: case MTLPixelFormatR32Float: case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatBGRA8Unorm: return 4;
        case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm: return 2;
        case MTLPixelFormatR8Unorm: return 1;
        default: return 0;
    }
}

static void ggTryCapture(void) {
    if (!gCaptureOn || !tCapTex || !tCapBuf) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)tCapTex;
    id<MTLBuffer> buf = (__bridge id<MTLBuffer>)tCapBuf;
    NSUInteger bpp = ggBytesPerPixel(tex.pixelFormat);
    if (!bpp || tCapOff >= buf.length) return;
    NSData *uni = [NSData dataWithBytes:(const uint8_t *)buf.contents + tCapOff length:MIN((NSUInteger)272, buf.length - tCapOff)];
    NSString *key = [NSString stringWithFormat:@"%lux%lu-%@", (unsigned long)tex.width, (unsigned long)tex.height,
                     uni.length >= 104 ? [uni subdataWithRange:NSMakeRange(80, 24)] : uni];
    [gLock lock];
    BOOL fresh = gCaptureKeys.count < 24 && ![gCaptureKeys containsObject:key];
    if (fresh) [gCaptureKeys addObject:key];
    NSUInteger idx = gCaptureKeys.count;
    [gLock unlock];
    tCapTex = tCapBuf = NULL;
    if (!fresh) return;
    static dispatch_queue_t q;
    static id<MTLCommandQueue> cq;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("ggglass.capture", DISPATCH_QUEUE_SERIAL); cq = [tex.device newCommandQueue]; });
    dispatch_async(q, ^{
        NSUInteger w = tex.width, h = tex.height, row = w * bpp;
        id<MTLBuffer> out = [tex.device newBufferWithLength:row * h options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [cq commandBuffer];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:tex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
                  toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row * h];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        NSString *base = [gCaptureDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%02lu", (unsigned long)idx]];
        [[NSData dataWithBytesNoCopy:out.contents length:row * h freeWhenDone:NO] writeToFile:[base stringByAppendingString:@".bin"] atomically:YES];
        NSMutableString *hex = [NSMutableString string];
        const uint8_t *p = uni.bytes;
        for (NSUInteger i = 0; i < uni.length; i++) [hex appendFormat:@"%02x", p[i]];
        NSString *meta = [NSString stringWithFormat:@"%lux%lu pixelFormat %lu, %lu byte/pixel, mipmap %lu, storage %lu\nuniform hex: %@\n",
                          (unsigned long)w, (unsigned long)h, (unsigned long)tex.pixelFormat, (unsigned long)bpp,
                          (unsigned long)tex.mipmapLevelCount, (unsigned long)tex.storageMode, hex];
        [meta writeToFile:[base stringByAppendingString:@".txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if (idx == 1) ggLog(@"sdf_texture capture: writing to %@", gCaptureDir);
    });
}

static void ggSetFragTex(id self, SEL sel, id tex, NSUInteger index) {
    ((void (*)(id, SEL, id, NSUInteger))ggOriginal(self, sel))(self, sel, tex, index);
    if (index == 4 && tOurPSOBound && gCaptureOn) { tCapTex = (__bridge void *)tex; ggTryCapture(); }
}

static void ggSetPSO(id self, SEL sel, id pso) {
    if (gDumpUniforms) {
        [gLock lock]; NSString *name = gGlassPipelines[[NSValue valueWithPointer:(__bridge void *)pso]]; [gLock unlock];
        tGlassName = (__bridge void *)name;
    }
    ((void (*)(id, SEL, id))ggOriginal(self, sel))(self, sel, pso);
    tOurPSOBound = ggIsOurPSO(pso);
    tGenericBound = ggInList(gGenericPSOs, &gGenericPSOCount, (__bridge void *)pso);
    if (gTraceDraws) tCurTag = (__bridge void *)ggTagOf(pso);
    tCapTex = tCapBuf = NULL;
    if (tOurPSOBound) {   // our glass pipeline: bind GGLive {appearance flag, slider amount} for the shader
        struct { uint32_t appearance; float diffusion; } v = {atomic_load(&gSysDarkFlag), ggLiveTint()};
        [(id<MTLRenderCommandEncoder>)self setFragmentBytes:&v length:sizeof v atIndex:28];
        static dispatch_once_t once;
        dispatch_once(&once, ^{ ggLog(@"bind GGLive (%@, tint %.2f, %lu bytes) at buffer 28 when binding a glass pipeline",
                                      v.appearance ? @"dark" : @"light", v.diffusion, (unsigned long)sizeof v); });
    }
}

// MARK: - Appearance from the Dock
// WindowServer runs as _windowserver: after startup it cannot read the appearance file in ~/Library (mode 700), so the
// file is not watched (the flag used to get stuck on dark when Auto appearance switched). The Dock always follows the
// system appearance and uses two dedicated 26.6 recipes (#9 light 0.15/0.9/1.05 white .1, #10 dark 0.075/0.9/1.06 black .1,
// as in kSigs26): when a Dock face shows up in our glass uniforms, set the flag from it. While the Dock is hidden the old
// value is kept until it shows again.
static float ggHalf(const uint8_t *p) {
    uint16_t h = (uint16_t)(p[0] | p[1] << 8);
    int e = (h >> 10) & 0x1f; float m = h & 0x3ff, s = (h & 0x8000) ? -1 : 1;
    return e == 0 ? s * m * 0x1p-24f : e == 31 ? s * INFINITY : s * (1 + m / 1024) * ldexpf(1, e - 15);
}

/// Whether the face (12 halfs at p) matches the black/white/sat/fill recipe (computed like the shader's ycc_face).
static BOOL ggFaceIs(const uint8_t *p, float B, float W, float S, float f, float a) {
    const float L[3] = {0.2126f, 0.7152f, 0.0722f}, k = 1 - a;
    for (int i = 0; i < 3; i++)
        for (int j = 0; j < 4; j++) {
            float want = j < 3 ? (W - B - S) * L[j] * k + (i == j ? S * k : 0) : B * k + f * a;
            if (fabsf(ggHalf(p + (i * 4 + j) * 2) - want) > 2e-3f) return NO;
        }
    return YES;
}

static void ggWatchDock(id<MTLBuffer> buf, NSUInteger offset) {
    const uint8_t *base = buf.contents;
    if (!base) return;
    for (NSUInteger fo = 80; fo <= 128; fo += 48) {   // texture variant: face at byte 80; sdf variant: 48 + 80
        if (offset + fo + 24 > buf.length) return;
        const uint8_t *p = base + offset + fo;
        int dark = ggFaceIs(p, 0.075f, 0.9f, 1.06f, 0, 0.1f) ? 1 : ggFaceIs(p, 0.15f, 0.9f, 1.05f, 1, 0.1f) ? 0 : -1;
        if (dark < 0) continue;
        if (atomic_exchange(&gSysDarkFlag, (uint32_t)dark) != (uint32_t)dark) ggLog(@"appearance changed: %@ (from Dock)", dark ? @"dark" : @"light");
        return;
    }
}

static void ggSetFragBuffer(id self, SEL sel, id buf, NSUInteger offset, NSUInteger index) {
    if (index == 0) { tCfgBuf = (__bridge void *)buf; tCfgFn = ggCfgByte(buf, offset); }
    if (index == 1) {
        tBuffer1 = (__bridge void *)buf;
        if (gDumpUniforms) ggDump(offset);
        if (tOurPSOBound) {
            ggWatchDock(buf, offset);
            if (gCaptureOn) { tCapBuf = (__bridge void *)buf; tCapOff = offset; ggTryCapture(); }
        }
    }
    ((void (*)(id, SEL, id, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, buf, offset, index);
}

static void ggSetFragBufferOffset(id self, SEL sel, NSUInteger offset, NSUInteger index) {
    if (index == 0) tCfgFn = tCfgBuf ? ggCfgByte((__bridge id<MTLBuffer>)tCfgBuf, offset) : -1;
    if (index == 1) {
        if (gDumpUniforms) ggDump(offset);
        if (tOurPSOBound && tBuffer1) {
            ggWatchDock((__bridge id<MTLBuffer>)tBuffer1, offset);
            if (gCaptureOn) { tCapBuf = tBuffer1; tCapOff = offset; ggTryCapture(); }
        }
    }
    ((void (*)(id, SEL, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, offset, index);
}

static void ggSetFragBytes(id self, SEL sel, const void *bytes, NSUInteger length, NSUInteger index) {
    if (index == 0) { tCfgBuf = NULL; tCfgFn = bytes && length > 33 ? ((const uint8_t *)bytes)[33] : -1; }
    ((void (*)(id, SEL, const void *, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, bytes, length, index);
}

// Draw calls: skip the 26.6 highlight draw via the generic uber shader (ggSkipDraw), otherwise call the original.
static void ggDraw3(id self, SEL sel, MTLPrimitiveType t, NSUInteger s, NSUInteger c) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, t, s, c);
}
static void ggDraw4(id self, SEL sel, MTLPrimitiveType t, NSUInteger s, NSUInteger c, NSUInteger i) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, t, s, c, i);
}
static void ggDraw5(id self, SEL sel, MTLPrimitiveType t, NSUInteger s, NSUInteger c, NSUInteger i, NSUInteger b) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, NSUInteger, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, t, s, c, i, b);
}
static void ggDrawIdx5(id self, SEL sel, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger o) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger))ggOriginal(self, sel))(self, sel, t, c, it, ib, o);
}
static void ggDrawIdx6(id self, SEL sel, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger o, NSUInteger i) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger))ggOriginal(self, sel))(self, sel, t, c, it, ib, o, i);
}
static void ggDrawIdx8(id self, SEL sel, MTLPrimitiveType t, NSUInteger c, MTLIndexType it, id ib, NSUInteger o, NSUInteger i,
                       NSInteger bv, NSUInteger bi) {
    if (ggSkipDraw()) return;
    ((void (*)(id, SEL, MTLPrimitiveType, NSUInteger, MTLIndexType, id, NSUInteger, NSUInteger, NSInteger, NSUInteger))ggOriginal(self, sel))
        (self, sel, t, c, it, ib, o, i, bv, bi);
}

static void ggEndEncoding(id self, SEL sel) {
    ggFlushSeq();   // a traceDraws sequence ends at the end of the encoder
    ((void (*)(id, SEL))ggOriginal(self, sel))(self, sel);
}

/// Hooks exactly one concrete class (the object's real class). Inherited methods are added to this class (class_addMethod)
/// without touching the superclass. Saves the original IMP before swapping.
static BOOL ggHookClass(Class c, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    NSString *key = [NSString stringWithFormat:@"%s/%s", class_getName(c), sel_getName(sel)];
    [gOrigLock lock];
    BOOL todo = !gOriginals[key];
    if (todo) gOriginals[key] = [NSValue valueWithPointer:(void *)method_getImplementation(m)];
    [gOrigLock unlock];
    if (todo && !class_addMethod(c, sel, imp, method_getTypeEncoding(m))) method_setImplementation(m, imp);
    return todo;
}

/// The driver's real render encoder class (probe encoder, never committed).
static Class ggEncoderClass(id<MTLDevice> dev) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:td];
    id<MTLRenderCommandEncoder> enc = [[[dev newCommandQueue] commandBuffer] renderCommandEncoderWithDescriptor:rp];
    Class c = object_getClass(enc);
    [enc endEncoding];
    return c;
}

/// Live appearance (once, at the first replacement): hooks pipeline creation (records our pipelines), pipeline binding
/// (binds the appearance flag at buffer 28) and uniform binding (updates the flag from the Dock face) on the real
/// device/encoder classes. The initial value is read in the constructor (still running as root).
static void ggInstallLiveAppearance(id<MTLDevice> dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class encClass = ggEncoderClass(dev);
        ggHookClass(object_getClass(dev), @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)ggNewPSO);
        ggHookClass(encClass, @selector(setRenderPipelineState:), (IMP)ggSetPSO);
        ggHookClass(encClass, @selector(setFragmentBuffer:offset:atIndex:), (IMP)ggSetFragBuffer);
        ggHookClass(encClass, @selector(setFragmentBufferOffset:atIndex:), (IMP)ggSetFragBufferOffset);
        // 26.6 highlight via the generic uber shader: track the config at fragment buffer 0 and skip draws with texture function 66.
        ggHookClass(encClass, @selector(setFragmentBytes:length:atIndex:), (IMP)ggSetFragBytes);
        ggHookClass(encClass, @selector(drawPrimitives:vertexStart:vertexCount:), (IMP)ggDraw3);
        ggHookClass(encClass, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:), (IMP)ggDraw4);
        ggHookClass(encClass, @selector(drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:), (IMP)ggDraw5);
        ggHookClass(encClass, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:), (IMP)ggDrawIdx5);
        ggHookClass(encClass, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:), (IMP)ggDrawIdx6);
        ggHookClass(encClass, @selector(drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:), (IMP)ggDrawIdx8);
        if (gTraceDraws) {
            gTags = [NSMutableDictionary dictionary]; gSeqSeen = [NSMutableSet set];
            ggHookClass(encClass, @selector(endEncoding), (IMP)ggEndEncoding);
            ggLog(@"traceDraws: logging draw sequences after glass");
        }
        // Capture the real sdf_texture once: if the directory is absent, create it and enable (later sessions see it and skip).
        gCaptureDir = [gState stringByAppendingPathComponent:@"sdf-capture"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:gCaptureDir] &&
            [[NSFileManager defaultManager] createDirectoryAtPath:gCaptureDir withIntermediateDirectories:NO attributes:nil error:nil]) {
            chmod(gCaptureDir.fileSystemRepresentation, 0777);
            gCaptureKeys = [NSMutableSet set];
            ggHookClass(encClass, @selector(setFragmentTexture:atIndex:), (IMP)ggSetFragTex);
            gCaptureOn = YES;
            ggLog(@"sdf_texture capture: enabled for this session (%@)", gCaptureDir);
        }
    });
}

/// Installs the diagnostic hooks (once) on the real device and render encoder classes, taken from real objects.
static void ggInstallDump(id<MTLDevice> dev) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gGlassPipelines = [NSMutableDictionary dictionary];
        gDumped = [NSMutableDictionary dictionary];
        Class encClass = ggEncoderClass(dev);
        int n = ggHookClass(object_getClass(dev), @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)ggNewPSO)
              + ggHookClass(encClass, @selector(setRenderPipelineState:), (IMP)ggSetPSO)
              + ggHookClass(encClass, @selector(setFragmentBuffer:offset:atIndex:), (IMP)ggSetFragBuffer)
              + ggHookClass(encClass, @selector(setFragmentBufferOffset:atIndex:), (IMP)ggSetFragBufferOffset);
        ggLog(@"dumpUniforms: hooked %d methods on %s and %s", n, class_getName(object_getClass(dev)), class_getName(encClass));
    });
}

// MARK: - Coordinated notification type 12 via the MIG table
// WindowServer 26.6 rejects types > 10 in __CGXPostCoordinatedDistributedNotificationFenced; 27 allows up to 12
// (GlassAppearanceSettingsChange). Apple code is not modified (SkyLight's __TEXT pages in WindowServer are not writable, and
// patching bytes killed it on 2026-11-19): the stub_routine cell of msgh_id 30591 in __CGXCGXServices_subsystem
// (__DATA_CONST) is pointed at our stub. Type 12 enters the Apple function right after the type check via a trampoline;
// every other type goes to the original _X. Static addresses for 25G72.

static const uint64_t kMigCell = 0x7ff840ae72b8, kXPost = 0x7ff80967e88a, kCGXPost = 0x7ff809474eaa,
                      kCGXResume = 0x7ff809474f88, kConnForPort = 0x7ff80946b31c;
static const char kXPostHead[] =   // _XPostCoordinatedDistributedNotificationFenced, 144 byte
    "554889e54156534889f3b8d0feffff833f0079664989fe837f1801755d41837e043c7556410fb74e26c1e110b8d4feffff81f900001100"
    "7541418b7e0ce850cadeff418b561c418b7630f2410f104634488d4b244889c7e8c465dfff894320488b0d40659d36488b0948894b1885"
    "c0751ac743042c000000eb11894320488b0522659d36488b00488943185b415e5dc3";
static const char kCGXHead[] =     // __CGXPost... from the start through `cmpl $0xa, %esi; ja` (222 bytes)
    "554889e54157415641554154534881ec88000000f20f118558ffffff488b057be8bd36488b00488945d0bbeb0300004885ff0f84a5030000"
    "4989cd4189d48d46fb83f8030f8786000000f68788000000020f84860300004889bd70ffffff4889b568ffffff4531f64531ff31db4d85ff"
    "744a4d8b3f4d85ff0f84ab02000041f687f002000010750a41f6878b0000001074db4c89ffe806ffffff84c074cf4889df4c89fee8faced8"
    "ff4889c34c89f74c89fee8ecced8ff4989c6ebb1488b056bc4783a488b40204c8bb8b0000000eba2bbe903000083fe0a0f87ff020000";

__attribute__((visibility("default"))) int gg_mig_type12_calls;   // number of type 12 messages handled by the stub (read by tests)
uintptr_t gg_cgx_resume;   // 0x7ff809474f88 + slide, the trampoline jumps here
static void (*gOrigXPost)(mach_msg_header_t *, mach_msg_header_t *);
static void *(*gConnForPort)(mach_port_t);

// gg_cgx_unchecked(conn, type, fence, out, timeout): rebuilds exactly the state __CGXPost... has at 0x7ff809474f88 (rbp
// frame, 5 saved registers, 0x88 bytes of stack, timeout at -0xa8, canary at -0x30, ebx = 0x3e9, r13 = out, r12d = fence;
// rdi/rsi unchanged) and jumps there. The rest of the Apple function returns to the caller through its own epilogue.
int gg_cgx_unchecked(void *conn, uint32_t type, mach_port_t fence, void *out, double timeout);
__asm__(
    ".text\n"
    ".p2align 4\n"
    "_gg_cgx_unchecked:\n"
    "    pushq %rbp\n"
    "    movq %rsp, %rbp\n"
    "    pushq %r15\n"
    "    pushq %r14\n"
    "    pushq %r13\n"
    "    pushq %r12\n"
    "    pushq %rbx\n"
    "    subq $0x88, %rsp\n"
    "    movsd %xmm0, -0xa8(%rbp)\n"
    "    movq ___stack_chk_guard@GOTPCREL(%rip), %rax\n"
    "    movq (%rax), %rax\n"
    "    movq %rax, -0x30(%rbp)\n"
    "    movl $0x3e9, %ebx\n"
    "    movq %rcx, %r13\n"
    "    movl %edx, %r12d\n"
    "    jmpq *_gg_cgx_resume(%rip)\n");

/// Stub for msgh_id 30591, same contract as _XPostCoordinatedDistributedNotificationFenced (0x7ff80967e88a).
static void ggXPost(mach_msg_header_t *in, mach_msg_header_t *out) {
    const uint8_t *i = (const uint8_t *)in;
    uint8_t *o = (uint8_t *)out;
    BOOL valid = (int32_t)in->msgh_bits < 0 && *(const uint32_t *)(i + 0x18) == 1 && in->msgh_size == 0x3c &&
                 ((uint32_t)*(const uint16_t *)(i + 0x26) << 16) == 0x110000;
    if (!valid || *(const uint32_t *)(i + 0x30) != 12) { gOrigXPost(in, out); return; }
    gg_mig_type12_calls++;
    void *conn = gConnForPort(in->msgh_local_port);
    double timeout; memcpy(&timeout, i + 0x34, 8);
    int rc = conn ? gg_cgx_unchecked(conn, 12, *(const uint32_t *)(i + 0x1c), o + 0x24, timeout) : 0x3eb;
    *(int32_t *)(o + 0x20) = rc;
    memcpy(o + 0x18, &NDR_record, sizeof NDR_record);
    if (rc == 0) out->msgh_size = 0x2c;
}

static BOOL ggHexMatch(const uint8_t *p, const char *hex) {
    size_t n = strlen(hex) / 2;
    for (size_t k = 0; k < n; k++) { unsigned v = 0; sscanf(hex + 2 * k, "%2x", &v); if (p[k] != (uint8_t)v) return NO; }
    return YES;
}

/// Slide of the SkyLight image, found via one of its exported symbols. Not by path name: the WindowServer executable lives
/// in .../SkyLight.framework/Versions/A/Resources/, so it matches first and gives the wrong slide (WindowServer died 2026-11-19).
static BOOL ggSkyLightSlide(intptr_t *slide) {
    void *sym = dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
    Dl_info di;
    if (!sym || !dladdr(sym, &di) || !di.dli_fbase) return NO;
    *slide = (intptr_t)di.dli_fbase - (intptr_t)0x7ff8091fd000;   // static __TEXT of SkyLight 25G72
    return YES;
}

/// GG_MIG_EXPECT_CGX (hex) overrides the expected bytes, GG_PATCH_NOPROTECT skips the protection change: tests only.
static BOOL ggInstallMigRedirect(void) {
    intptr_t slide = 0;
    if (!ggSkyLightSlide(&slide)) { ggLog(@"MIG not redirected: SkyLight not found"); return NO; }
    uintptr_t *cell = (uintptr_t *)(kMigCell + slide);
    uintptr_t xpost = kXPost + slide;
    const char *ex = getenv("GG_MIG_EXPECT_CGX");
    if (*cell != xpost || !ggHexMatch((const uint8_t *)xpost, kXPostHead) ||
        !ggHexMatch((const uint8_t *)(kCGXPost + slide), ex ? ex : kCGXHead)) {
        ggLog(@"MIG not redirected: bytes differ (cell %#lx)", (unsigned long)*cell);
        return NO;
    }
    gOrigXPost = (void *)xpost;
    gConnForPort = (void *)(kConnForPort + slide);
    gg_cgx_resume = kCGXResume + slide;
    mach_vm_address_t page = (mach_vm_address_t)cell & ~(mach_vm_address_t)(vm_page_size - 1);
    kern_return_t kr = getenv("GG_PATCH_NOPROTECT") ? KERN_SUCCESS
                     : mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    uintptr_t stub = (uintptr_t)ggXPost;
    if (kr == KERN_SUCCESS) kr = mach_vm_write(mach_task_self(), (mach_vm_address_t)cell, (vm_offset_t)&stub, sizeof stub);
    mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ);
    if (kr != KERN_SUCCESS || *cell != stub) { ggLog(@"MIG not redirected: write failed %d", kr); return NO; }
    ggLog(@"redirected MIG 30591 (PostCoordinatedDistributedNotificationFenced): type 12 passes as in 27");
    return YES;
}

__attribute__((constructor)) static void ggInit(void) {
    @autoreleasepool {
        const char *root = getenv("GG_ROOT"), *state = getenv("GG_STATE"), *source = getenv("GG_SOURCE");
        gRoot = root ? @(root) : @"/Users/Shared/GoldenGate";
        gState = state ? @(state) : @"/Library/Logs/WindowServer/GoldenGate";
        gSource = source ? @(source) : @"/Library/GoldenGate/gg27.metal";
        [[NSFileManager defaultManager] createDirectoryAtPath:gState withIntermediateDirectories:YES attributes:nil error:nil];
        chmod(gState.fileSystemRepresentation, 0777);   // the ggglass tool (regular user) must be able to delete boots.plist
        gOriginals = [NSMutableDictionary dictionary];
        gCache = [NSMutableDictionary dictionary];
        gLock = [NSLock new];
        gOrigLock = [NSLock new];
        gCompile = dispatch_group_create();
        gWarmGroup = dispatch_group_create();

        NSString *build = ggBuild();
        if (![build isEqualToString:@"25G72"]) { ggLog(@"build %@ is not 25G72, doing nothing", build); return; }
        if ([[NSFileManager defaultManager] fileExistsAtPath:[gRoot stringByAppendingPathComponent:@"disable"]]) {
            ggLog(@"loaded, disabled (kill-switch)"); return;
        }
        NSDictionary *s = [NSDictionary dictionaryWithContentsOfFile:[gRoot stringByAppendingPathComponent:@"settings.plist"]];
        if (s[@"enabled"] && ![s[@"enabled"] boolValue]) { ggLog(@"settings enabled = false, doing nothing"); return; }
        if (!ggCrashGuard()) return;
        if ([s[@"tintAmount"] isKindOfClass:[NSNumber class]]) gTint = fminf(fmaxf([s[@"tintAmount"] floatValue], 0), 1);
        if ([s[@"pixelLength"] isKindOfClass:[NSNumber class]]) gPixelLength = [s[@"pixelLength"] floatValue];
        gTrace = getenv("GG_TRACE") != NULL || [s[@"trace"] boolValue];   // log every requested function name
        gDebugColor = [s[@"debugColor"] boolValue];   // color by branch: red 26.6, green regular, blue clear
        gDebugSize = [s[@"debugSize"] boolValue];   // color by the glass short side the adapter uses (constant 45)
        gDumpUniforms = [s[@"dumpUniforms"] boolValue];   // log real uniforms of glass pipelines
        gDebugEdge = [s[@"debugEdge"] boolValue];   // solid fill by SDF distance (constant 48)
        gNoHighlight27 = [s[@"noHighlight27"] boolValue];   // disable the 27 highlight in the shader (constant 50, A/B test)
        gDebugScale = [s[@"debugScale"] boolValue];   // encode texels/point and distance slope into color (constant 49)
        gTraceDraws = [s[@"traceDraws"] boolValue];   // log draw sequences right after our glass
        // Initial appearance: the constructor still runs as root, so it can read the user's appearance file; later it follows the Dock.
        atomic_store(&gSysDarkFlag, ggSystemDark() ? 1u : 0u);
        ggLog(@"initial appearance: %@", atomic_load(&gSysDarkFlag) ? @"dark" : @"light");
        if ([s[@"coordinatedGlass"] boolValue]) ggInstallMigRedirect();
        ggSetLiveTint(gTint);
        // ggtint (the writer, like 27's setSystemLegibility) posts a notify after writing settings.plist: reread tintAmount.
        static int tintToken;
        NSString *settingsPath = [gRoot stringByAppendingPathComponent:@"settings.plist"];
        notify_register_dispatch("com.goldengate.glass.tint", &tintToken,
                                 dispatch_queue_create("ggglass.tint", DISPATCH_QUEUE_SERIAL), ^(int t) {
            NSNumber *n = [NSDictionary dictionaryWithContentsOfFile:settingsPath][@"tintAmount"];
            if (![n isKindOfClass:[NSNumber class]]) return;
            ggSetLiveTint(fminf(fmaxf(n.floatValue, 0), 1));
            ggLog(@"runtime tint %.2f", ggLiveTint());
        });
        ggSwizzleLibraries();
        gActive = YES;
        // Handshake with ggapp: this shader understands the app's recipe codes (|preserve_hue| >= 2048). ggapp only writes
        // 27 values into the filter when state = 2. The token is kept for the lifetime of the process.
        static int abiToken;
        const char *abiName = getenv("GG_ABI_NAME") ?: "com.goldengate.glass.abi";
        if (notify_register_check(abiName, &abiToken) == NOTIFY_STATUS_OK) notify_set_state(abiToken, 2);
        ggLog(@"enabled (tint %.2f, pixelLength %.2f, shader %@, app ABI 2)", gTint, gPixelLength, gSource);
    }
}
