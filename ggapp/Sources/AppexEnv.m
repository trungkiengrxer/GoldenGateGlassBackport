// Brings ggapp into extensions (.appex) launched by a host app, for example System Settings panes. Measured: a pane
// launched on behalf of the host app does not get launchd's DYLD_INSERT_LIBRARIES (not even GGAppLoader). ExtensionFoundation
// 26.6 already has `additionalEnvironmentVariables` on _EXHostConfiguration and _EXLaunchConfiguration (NSSecureCoding, sent
// over XPC and then applied to RBSLaunchContext). In the host app (which already has ggapp), add DYLD_INSERT_LIBRARIES
// pointing at GGAppLoader.dylib in the same directory to those variables; the stage 1 loader in the extension filters
// by itself (only UI panes load GGApp.dylib).
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>

BOOL ggSwizzle(Class c, SEL s, IMP imp, IMP *orig);
void ggLog(NSString *fmt, ...);

static NSString *gLoader;
static IMP oLaunchGet, oHostGet, oEncode, oSetCtx, oSetCtxAdd;
static int gLogged;

/// Adds the loader to d's DYLD_INSERT_LIBRARIES (keeps existing libraries, never adds twice). Exported for tests/host.m.
NSDictionary *gg_appex_env_merge(NSDictionary *d) {
    if (!gLoader) return d;
    NSMutableDictionary *m = d ? [d mutableCopy] : [NSMutableDictionary dictionary];
    NSString *cur = m[@"DYLD_INSERT_LIBRARIES"];
    if (![cur containsString:gLoader]) m[@"DYLD_INSERT_LIBRARIES"] = cur.length ? [cur stringByAppendingFormat:@":%@", gLoader] : gLoader;
    return m;
}
#define withOurs gg_appex_env_merge

static void note(NSString *where, id obj) {
    if (gLogged++ < 12) ggLog(@"appex: %@ (%@)", where, [[obj description] substringToIndex:MIN((NSUInteger)160, [obj description].length)]);
}

static NSDictionary *hLaunchGet(id self, SEL _cmd) {
    return withOurs(((NSDictionary *(*)(id, SEL))oLaunchGet)(self, _cmd));
}
static NSDictionary *hHostGet(id self, SEL _cmd) {
    return withOurs(((NSDictionary *(*)(id, SEL))oHostGet)(self, _cmd));
}
// Encoding reads the ivar directly: store the value with our variable added before it is sent over XPC.
static void hEncode(id self, SEL _cmd, NSCoder *c) {
    note(@"encoding _EXLaunchConfiguration", self);
    ((void (*)(id, SEL, id))objc_msgSend)(self, @selector(setAdditionalEnvironmentVariables:), withOurs(((NSDictionary *(*)(id, SEL))oLaunchGet)(self, @selector(additionalEnvironmentVariables))));
    ((void (*)(id, SEL, id))oEncode)(self, _cmd, c);
}
// In case the host app builds the RBSLaunchContext itself (not through another process).
static void hSetCtx(id self, SEL _cmd, NSDictionary *env) {
    note(@"RBSLaunchContext setEnvironment:", env);
    ((void (*)(id, SEL, id))oSetCtx)(self, _cmd, withOurs(env));
}
static void hSetCtxAdd(id self, SEL _cmd, NSDictionary *env) {
    note(@"RBSLaunchContext _setAdditionalEnvironment:", env);
    ((void (*)(id, SEL, id))oSetCtxAdd)(self, _cmd, withOurs(env));
}

void gg_appex_env_install(void) {
    if (gLoader) return;
    Dl_info me;
    if (!dladdr((const void *)gg_appex_env_install, &me) || !me.dli_fname) return;
    gLoader = [[@(me.dli_fname) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"GGAppLoader.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:gLoader]) { ggLog(@"appex: missing %@, not injecting", gLoader); return; }
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    Class lc = NSClassFromString(@"_EXLaunchConfiguration"), hc = NSClassFromString(@"_EXHostConfiguration");
    Class rc = NSClassFromString(@"RBSLaunchContext");
    BOOL a = ggSwizzle(lc, @selector(additionalEnvironmentVariables), (IMP)hLaunchGet, &oLaunchGet);
    BOOL b = ggSwizzle(hc, @selector(additionalEnvironmentVariables), (IMP)hHostGet, &oHostGet);
    BOOL c = a && ggSwizzle(lc, @selector(encodeWithCoder:), (IMP)hEncode, &oEncode);
    BOOL d = ggSwizzle(rc, @selector(setEnvironment:), (IMP)hSetCtx, &oSetCtx);
    BOOL e = ggSwizzle(rc, NSSelectorFromString(@"_setAdditionalEnvironment:"), (IMP)hSetCtxAdd, &oSetCtxAdd);
    ggLog(@"appex: injecting %@ (launch get %d, host get %d, encode %d, rbs env %d/%d)", gLoader, a, b, c, d, e);
}
