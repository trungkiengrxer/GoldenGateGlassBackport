// GGApp loader: runs in the dylib constructor (loaded via DYLD_INSERT_LIBRARIES into GUI apps).
// Enabled only when: build 25G72 x86_64; the process is an .app bundle (or a UI .appex, GGApp.appex) with a bundle ID;
// global defaults have no GGApp.disable = YES; the bundle ID is not in the default list or GGApp.exclude; the crash guard
// has not excluded it. Then calls each part per global defaults key (default YES): GGApp.flex, GGApp.trafficLights,
// GGApp.pocket, GGApp.toolbarPress, GGApp.sidebar, GGApp.windowCorners, GGApp.menuGlass (GGApp.sidebarGlass default NO).
// Log: <home>/Library/Logs/GoldenGate/ggapp.log (home = $GG_HOME or NSHomeDirectory(), the container for sandboxed apps).
// Crash guard: see crashGuardTrips (counts fault signals, not early exits).
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/mman.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

static NSString *gLogDir, *gBid;
static NSDictionary *gSettings;
static const char *gState = "inactive:init";

const char *gg_state(void) { return gState; }

void ggLog(NSString *fmt, ...) {
    if (!gLogDir) return;
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"%@ %@[%d] %@\n", [NSDate date], gBid ?: @"?", getpid(), msg];
    NSString *path = [gLogDir stringByAppendingPathComponent:@"ggapp.log"];
    @synchronized ([NSFileManager class]) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
        [h seekToEndOfFile];
        [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}

void gg_log_c(const char *s) { ggLog(@"%@", @(s)); }   // %s uses the system encoding and breaks non-ASCII text

BOOL ggSettingDefault(NSString *key, BOOL def) {
    id v = gSettings[key];
    return v ? [v boolValue] : def;
}

BOOL ggSetting(NSString *key) { return ggSettingDefault(key, YES); }

BOOL gg_setting_c(const char *key) { return ggSetting(@(key)); }

/// Replaces the selector's IMP on exactly class c (adds the method to c if inherited, so the superclass is untouched).
/// NO if the class/selector is missing, or it is already our IMP (second call).
BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig) {
    if (!c) return NO;
    Method m = class_getInstanceMethod(c, s);
    if (!m || method_getImplementation(m) == imp) return NO;
    IMP old = method_getImplementation(m);
    if (class_addMethod(c, s, imp, method_getTypeEncoding(m))) *orig = old;
    else *orig = method_setImplementation(m, imp);
    return YES;
}

/// Calls f(image name, GOT slot) for each x86_64 stub `jmp *slot(%rip)` (FF 25 rel32) in __TEXT,__stubs of every image.
static void eachStubSlot(void (^f)(const char *image, void **slot)) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        unsigned long sz = 0;
        uint8_t *s = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__TEXT", "__stubs", &sz);
        for (unsigned long k = 0; s && k + 6 <= sz && s[k] == 0xff && s[k + 1] == 0x25; k += 6) {
            int32_t rel; memcpy(&rel, s + k + 2, 4);
            f(_dyld_get_image_name(i), (void **)(s + k + 6 + rel));
        }
    }
}

static BOOL hasSuffix(const char *s, const char *suf) {
    size_t a = strlen(s), b = strlen(suf);
    return a >= b && strcmp(s + a - b, suf) == 0;
}

/// Redirects calls to target from one image to replacement. In the shared cache an image's stubs point to coalesced GOT
/// slots outside its own __got (DesignLibrary: all 780 stubs), so slots are found through __stubs. Only patches slots no
/// other image shares (checks every loaded image). Returns the number of patched slots, -1 if a slot is shared.
/// Simplification: an image loaded later (dlopen) sharing a slot would be affected; recheck in a _dyld_register callback if seen.
int gg_patch_got(const char *imageSuffix, void *target, void *replacement) {
    if (!target || !replacement) return 0;
    NSMutableSet<NSValue *> *mine = [NSMutableSet set];
    eachStubSlot(^(const char *image, void **slot) {
        if (hasSuffix(image, imageSuffix) && *slot == target) [mine addObject:[NSValue valueWithPointer:slot]];
    });
    __block BOOL shared = NO;
    eachStubSlot(^(const char *image, void **slot) {
        if (!hasSuffix(image, imageSuffix) && [mine containsObject:[NSValue valueWithPointer:slot]]) {
            ggLog(@"GOT slot %p shared with %s, not patching", slot, image);
            shared = YES;
        }
    });
    if (shared) return -1;
    int n = 0;
    for (NSValue *v in mine) {
        void **slot = v.pointerValue;
        uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
        // Restore the exact previous page protection (read with mach_vm_region), do not assume read-only.
        mach_vm_address_t addr = page; mach_vm_size_t size = 0;
        vm_region_basic_info_data_64_t info; mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64; mach_port_t obj;
        if (mach_vm_region(mach_task_self(), &addr, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS
            || addr > page) { ggLog(@"cannot read the page protection of GOT slot %p", slot); continue; }
        int old = (info.protection & VM_PROT_READ ? PROT_READ : 0) | (info.protection & VM_PROT_WRITE ? PROT_WRITE : 0);
        if (!(old & PROT_WRITE) && mprotect((void *)page, getpagesize(), old | PROT_WRITE)) { ggLog(@"mprotect of GOT slot failed %d", errno); continue; }
        *slot = replacement;
        if (!(old & PROT_WRITE)) mprotect((void *)page, getpagesize(), old);
        ggLog(@"patched GOT slot %p (previous page protection %d)", slot, old);
        n++;
    }
    return n;
}

static NSString *buildVersion(void) {
    const char *fake = getenv("GG_FAKE_BUILD");
    if (fake) return @(fake);
    char b[32] = {0}; size_t len = sizeof b;
    return sysctlbyname("kern.osversion", b, &len, NULL, 0) == 0 ? @(b) : @"";
}

static NSString *guardPath(NSString *ext) {
    return [[gLogDir stringByAppendingPathComponent:@"guard"] stringByAppendingPathComponent:[gBid stringByAppendingPathExtension:ext]];
}

// The crash guard counts real crashes: the fault signal handler appends 1 byte to <bundleID>.crashes and then lets the
// default signal action run (the handler restores SIG_DFL and returns: the faulting instruction reruns, and the system
// crash report keeps the original state). "Early deaths" are no longer counted: apps/appex using sudden termination get
// SIGKILL on quit (measured with System Settings) and appex are often ended quickly by the system, so the old approach
// excluded wrongly. After 3 consecutive crashes with no run surviving 60 s or exiting normally, <bundleID>.excluded is created.
static char gCrashFile[PATH_MAX];
static int gGuardTest;   // GG_GUARD_TEST: the handler calls _exit(1) right after recording, so tests produce no crash report

static void onCrash(int sig) {
    // Restore SIG_DFL manually: SA_RESETHAND does not apply to SIGILL/SIGTRAP (POSIX), otherwise the rerun trap enters the
    // handler forever (seen: a Swift fatalError hung the process and the counter file grew). sigaction is handler-safe.
    struct sigaction dfl = {0};
    dfl.sa_handler = SIG_DFL;
    sigaction(sig, &dfl, NULL);
    int fd = open(gCrashFile, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) { (void)write(fd, "x", 1); close(fd); }
    if (gGuardTest) _exit(1);
}

static void clearGuard(void) { unlink(gCrashFile); }

/// YES if the app has been excluded by the crash guard (or was just excluded now).
static BOOL crashGuardTrips(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[gLogDir stringByAppendingPathComponent:@"guard"] withIntermediateDirectories:YES attributes:nil error:nil];
    if ([fm fileExistsAtPath:guardPath(@"excluded")]) return YES;
    strlcpy(gCrashFile, guardPath(@"crashes").fileSystemRepresentation, sizeof gCrashFile);
    unsigned long long crashes = [fm attributesOfItemAtPath:guardPath(@"crashes") error:nil].fileSize;
    if (crashes >= 3) {
        [fm createFileAtPath:guardPath(@"excluded") contents:nil attributes:nil];
        clearGuard();
        ggLog(@"crash guard: %llu consecutive crashes (none survived 60 s), self-excluded (delete %@ to re-enable)",
              crashes, guardPath(@"excluded"));
        return YES;
    }
    gGuardTest = getenv("GG_GUARD_TEST") != NULL;
    struct sigaction sa = {0};
    sa.sa_handler = onCrash;
    sa.sa_flags = SA_RESETHAND | SA_NODEFER;
    for (int s = 0, sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP}; s < 6; s++) {
        struct sigaction old;
        // Do not override a handler the process already installed (the app's own crash reporter): skip that signal.
        if (sigaction(sigs[s], NULL, &old) == 0 && old.sa_handler == SIG_DFL) sigaction(sigs[s], &sa, NULL);
    }
    atexit(clearGuard);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ clearGuard(); });
    return NO;
}

static void callInstall(const char *name) {
    void (*f)(void) = dlsym(RTLD_SELF, name);
    if (f) f(); else ggLog(@"missing %s, skipping", name);
}

/// SwiftUI/SwiftUICore symbols the dylib uses (generated by build.sh from nm -u, NULL terminated). Weak linked, so a
/// missing symbol does not make dyld stop the app; checked here before running the Swift parts that use SPI.
extern const char *const gg_spi_syms[];

static BOOL spiComplete(void) {
    for (int i = 0; gg_spi_syms[i]; i++)
        if (!dlsym(RTLD_DEFAULT, gg_spi_syms[i])) { ggLog(@"missing SPI symbol %s: flex and traffic lights disabled", gg_spi_syms[i]); return NO; }
    return YES;
}

/// Installs the parts per settings. Safe to call again (each part skips itself if already installed).
void gg_install_all(void) {
    static int spi = -1;
    if (spi < 0) spi = spiComplete();
    if (spi && ggSetting(@"GGApp.flex")) callInstall("gg_flex_install");
    if (spi && ggSetting(@"GGApp.trafficLights")) callInstall("gg_wc_install");
    if (ggSetting(@"GGApp.pocket")) callInstall("gg_pocket_install");
    if (ggSetting(@"GGApp.toolbarPress")) callInstall("gg_toolbar_press_install");   // no SwiftUI SPI
    if (ggSetting(@"GGApp.sidebar")) callInstall("gg_sidebar_install");              // sidebar 27 (GGApp.sidebarGlass off by default)
    if (ggSetting(@"GGApp.windowCorners")) callInstall("gg_corners_install");        // 27 window corner radius
    if (ggSetting(@"GGApp.menuGlass")) callInstall("gg_menu_glass_install");         // 27 interactive menu glass (MenuGlass.swift)
    if (ggSetting(@"GGApp.appex")) callInstall("gg_appex_env_install");             // inject the loader into extensions the host app launches
    if (ggSetting(@"GGApp.settingsSlider")) callInstall("gg_settings_slider_install"); // 27 Liquid Glass slider in the Appearance pane
    if (ggSetting(@"GGApp.legibility")) {   // 27 slider path (GGLegibility.dylib in the same directory)
        Dl_info me;
        if (dladdr((const void *)gg_install_all, &me) && me.dli_fname) {
            NSString *p = [[@(me.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"GGLegibility.dylib"];
            void *h = dlopen(p.fileSystemRepresentation, RTLD_NOW);
            void (*f)(void) = h ? dlsym(h, "gg_legibility_install") : NULL;
            if (f) f(); else ggLog(@"cannot load %@: %s", p, dlerror() ?: "missing gg_legibility_install");
        }
    }
}

static NSArray *kDefaultExclude(void) {
    return @[@"com.apple.loginwindow", @"com.apple.dock", @"com.apple.WindowServer", @"com.apple.SecurityAgent",
             @"com.apple.LocalAuthentication.UIAgent", @"com.apple.UserNotificationCenter", @"com.apple.ScreenSaver.Engine",
             @"com.apple.systemuiserver", @"com.apple.controlcenter", @"com.apple.notificationcenterui",
             @"com.apple.Spotlight", @"com.apple.WindowManager"];
}

__attribute__((constructor)) static void ggAppInit(void) {
    @autoreleasepool {
#if !defined(__x86_64__)
        gState = "inactive:arch"; return;
#endif
        if (![buildVersion() isEqualToString:@"25G72"]) { gState = "inactive:build"; return; }
        NSBundle *mb = [NSBundle mainBundle];
        gBid = mb.bundleIdentifier;
        // .appex: UI panes only (the stage 1 loader already filtered by extension point); GGApp.appex turns it off separately.
        BOOL appex = [mb.bundlePath hasSuffix:@".appex"];
        if ((![mb.bundlePath hasSuffix:@".app"] && !appex) || !gBid) { gState = "inactive:nobundle"; return; }
        const char *home = getenv("GG_HOME");
        gLogDir = [(home ? @(home) : NSHomeDirectory()) stringByAppendingPathComponent:@"Library/Logs/GoldenGate"];
        [[NSFileManager defaultManager] createDirectoryAtPath:gLogDir withIntermediateDirectories:YES attributes:nil error:nil];
        // Settings and the kill switch live in global defaults (GGApp.* keys): sandboxed apps cannot read /Users/Shared
        // (EPERM, tested) but can read the global domain through cfprefsd. GG_PREFS: replacement plist file (tests).
        const char *prefs = getenv("GG_PREFS");
        gSettings = prefs ? [NSDictionary dictionaryWithContentsOfFile:@(prefs)]
                          : [[NSUserDefaults standardUserDefaults] persistentDomainForName:NSGlobalDomain];
        if ([gSettings[@"GGApp.disable"] boolValue]) { gState = "inactive:disabled"; return; }
        if (appex && !ggSetting(@"GGApp.appex")) { gState = "inactive:appex"; return; }
        NSArray *excl = [kDefaultExclude() arrayByAddingObjectsFromArray:gSettings[@"GGApp.exclude"] ?: @[]];
        if ([excl containsObject:gBid]) { gState = "inactive:excluded"; return; }
        if (crashGuardTrips()) { gState = "inactive:guard"; return; }
        gState = "active";
        ggLog(@"loaded into %@", mb.bundlePath);
        gg_install_all();
    }
}
