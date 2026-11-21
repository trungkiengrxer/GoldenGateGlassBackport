// GGAppLoader.dylib: stage 1, loaded via DYLD_INSERT_LIBRARIES (ggapp session-on). Plain C, libSystem only, so every
// process launchd starts in the session (agents, XPC services, command line tools) does not have to load AppKit/SwiftUI.
// dlopens GGApp.dylib from the same directory when the process is:
// - an app: the executable path contains ".app/Contents/MacOS/";
// - an extension with UI inside an app window: ".appex/Contents/MacOS/" and its Info.plist declares an extension point
//   listed in kUIPoints (System Settings panes). Most appex run in the background (widgets, thumbnails, speech, intents,
//   Spotlight), so they are skipped. Raw string search in Info.plist: ASCII strings appear verbatim in both XML and binary plists.
// All remaining conditions are checked by GGApp.dylib. Removes DYLD_INSERT_LIBRARIES from the process environment so child
// processes (shells in Terminal, helpers) do not inherit it; apps and appex still get the variable from launchd when opened.
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *const kUIPoints[] = {"com.apple.Settings.extension.ui", 0};
// System processes: load only GGLegibility.dylib (27 slider path, no AppKit), which checks GGApp.systemUI itself.
// Must match gg_system_ui_apps in Legibility/Legibility.m.
static const char *const kSystemUI[] = {"/Dock.app/Contents/MacOS/", "/ControlCenter.app/Contents/MacOS/",
                                        "/NotificationCenter.app/Contents/MacOS/", "/SystemUIServer.app/Contents/MacOS/",
                                        "/Spotlight.app/Contents/MacOS/", 0};

static int uiExtension(const char *exe) {
    const char *mark = strstr(exe, ".appex/Contents/MacOS/");
    if (!mark) return 0;
    char plist[PATH_MAX];
    size_t base = (size_t)(mark - exe) + strlen(".appex/Contents/");
    if (base + sizeof "Info.plist" > sizeof plist) return 0;
    memcpy(plist, exe, base);
    strlcpy(plist + base, "Info.plist", sizeof plist - base);
    int fd = open(plist, O_RDONLY);
    if (fd < 0) return 0;
    static char buf[256 * 1024];
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    for (int i = 0; n > 0 && kUIPoints[i]; i++)
        if (memmem(buf, (size_t)n, kUIPoints[i], strlen(kUIPoints[i]))) return 1;
    return 0;
}

__attribute__((constructor)) static void ggStage1(void) {
    unsetenv("DYLD_INSERT_LIBRARIES");
    char exe[PATH_MAX]; uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) return;
    if (!strstr(exe, ".app/Contents/MacOS/") && !uiExtension(exe)) return;
    const char *lib = "GGApp.dylib";
    for (int i = 0; kSystemUI[i]; i++) if (strstr(exe, kSystemUI[i])) lib = "GGLegibility.dylib";
    Dl_info me;
    if (!dladdr((const void *)ggStage1, &me) || !me.dli_fname) return;
    char path[PATH_MAX];
    strlcpy(path, me.dli_fname, sizeof path);
    char *slash = strrchr(path, '/');
    if (!slash) return;
    strlcpy(slash + 1, lib, sizeof path - (size_t)(slash + 1 - path));
    dlopen(path, RTLD_NOW | RTLD_GLOBAL);
}
