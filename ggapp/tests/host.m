// Test process for the GGApp loader: runs with DYLD_INSERT_LIBRARIES=GGApp.dylib and prints the loader state.
// HOST_CRASH=1: abort() (a real crash; run with GG_GUARD_TEST so the handler exits at once without a crash report).
// HOST_EXIT=1: _exit(1) (like sudden termination: dies early but is not a crash). HOST_TWICE=1: install the hooks again.
// Built and packaged as an .app by run-tests.sh.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

int main(void) {
    @autoreleasepool {
        const char *(*state)(void) = dlsym(RTLD_DEFAULT, "gg_state");
        if (getenv("HOST_TWICE")) {
            void (*again)(void) = dlsym(RTLD_DEFAULT, "gg_install_all");
            if (again) again();
        }
        printf("GGAPP:%s\n", state ? state() : "nodylib");
        printf("ENV:%s\n", getenv("DYLD_INSERT_LIBRARIES") ? "present" : "removed");
        const char *(*leg)(void) = dlsym(RTLD_DEFAULT, "gg_legibility_state");   // GGLegibility.dylib (27 slider path)
        printf("LEG:%s\n", leg ? leg() : "nolib");
        printf("APPKIT:%s\n", NSClassFromString(@"NSApplication") ? "yes" : "no");
        if (getenv("HOST_APPEXENV")) {   // environment the host app sends to an extension (Sources/AppexEnv.m)
            // A real _EXLaunchConfiguration cannot be built here (plain init() is forbidden, it needs an extension identity),
            // so call the merge function the hooks use directly. The hook path was verified on the real System Settings.
            NSDictionary *(*merge)(NSDictionary *) = dlsym(RTLD_DEFAULT, "gg_appex_env_merge");
            NSDictionary *a = merge ? merge(nil) : nil, *b = merge ? merge(@{@"DYLD_INSERT_LIBRARIES": @"/x.dylib", @"K": @"v"}) : nil;
            NSDictionary *c = merge ? merge(b) : nil;
            printf("APPEXENV:%s|%s|%s|%s\n", [a[@"DYLD_INSERT_LIBRARIES"] ?: @"-" UTF8String], [b[@"DYLD_INSERT_LIBRARIES"] ?: @"-" UTF8String],
                   [b[@"K"] ?: @"-" UTF8String], [c isEqual:b] ? "no duplicate" : "duplicate");
        }
        fflush(stdout);
        if (getenv("HOST_EXIT")) _exit(1);
        if (getenv("HOST_CRASH")) abort();
        if (getenv("HOST_TRAP")) __builtin_trap();   // ud2 -> SIGILL, like Swift's fatalError
    }
    return 0;
}
