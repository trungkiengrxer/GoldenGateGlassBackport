// ggtint <0..1> | --reset: the writer side of the transparency slider, playing the role of macOS 27's
// NSGlassEffectView.Legibility.setSystemLegibility:
//   1. tintAmount in $GG_ROOT/settings.plist (GGGlass's fallback value) + Darwin notify com.goldengate.glass.tint;
//   2. NSGlassTintAmount in the global domain + coordinated notification type 12 with a fence (GGLegibility in apps receives it and recommits).
// Compiled together with ggapp/Legibility/Legibility.m (code shared with the app). GG_PREFS_WRITE, GG_TINT_NOPOST: for tests.
#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/stat.h>
#import "Legibility.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        BOOL reset = argc == 2 && strcmp(argv[1], "--reset") == 0;
        char *end = NULL;
        double a = argc == 2 && !reset ? strtod(argv[1], &end) : NAN;
        if (!reset && (argc != 2 || !end || *end || !(a >= 0 && a <= 1))) {
            fprintf(stderr, "usage: ggtint <0..1> | --reset\n");
            return 1;
        }
        NSString *root = getenv("GG_ROOT") ? @(getenv("GG_ROOT")) : @"/Users/Shared/GoldenGate";
        NSString *path = [root stringByAppendingPathComponent:@"settings.plist"];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        NSMutableDictionary *s = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
        s[@"tintAmount"] = @(reset ? 0.5 : a);   // double, like the former `defaults write -float`
        if (![s writeToFile:path atomically:YES]) { fprintf(stderr, "cannot write %s\n", path.UTF8String); return 1; }
        chmod(path.fileSystemRepresentation, 0644);   // GGGlass rereads it at runtime as user _windowserver
        notify_post("com.goldengate.glass.tint");
        int err = GGGlassSetSystemLegibility((float)a, reset, nil);   // NSGlassTintAmount as float, like AppKit 27
        printf("tintAmount = %.2f\n", reset ? 0.5 : a);
        if (getenv("GG_TINT_NOPOST")) printf("coordinated notification not sent (GG_TINT_NOPOST)\n");
        else if (err == 0) printf("coordinated notification sent: apps with ggapp update immediately\n");
        else printf("WindowServer rejected type 12 (coordinatedGlass not enabled): only GGGlass's fallback value was updated\n");
    }
    return 0;
}
