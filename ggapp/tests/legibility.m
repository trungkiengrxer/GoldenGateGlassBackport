// Headless test of GGLegibility.dylib.
// Settings source: GG_PREFS (plist replacing the global domain). Prints "OK  ..." / "FAIL ..." and exits 1 if any case fails.
// Build: clang -arch x86_64 -fobjc-arc -framework Foundation -I ggapp/Legibility <build>/GGLegibility.dylib legibility.m
// Run with DYLD_LIBRARY_PATH=<build> (the install name points at /Users/Shared/GoldenGate).
#import <Foundation/Foundation.h>
#import <notify.h>
#import <objc/message.h>
#import <CoreGraphics/CoreGraphics.h>
#import "Legibility.h"
#import "Recipe27.h"

static int gFail;
static void expect(BOOL ok, NSString *name, NSString *got) {
    printf("%s %s%s\n", ok ? "OK " : "FAIL", name.UTF8String, ok ? "" : [NSString stringWithFormat:@" (got: %@)", got].UTF8String);
    if (!ok) gFail = 1;
}
static void setTint(NSString *path, NSNumber *v) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    if (v) d[@"NSGlassTintAmount"] = v; else [d removeObjectForKey:@"NSGlassTintAmount"];
    [d writeToFile:path atomically:YES];
}

int main(void) {
    @autoreleasepool {
        NSString *prefs = @(getenv("GG_PREFS"));
        setenv("GG_ABI_FAKE", "2", 1);   // app recipe codes on as with GGGlass ABI 2 (does not read the machine's real notify state)
        // Encoding P = 2 + 2 round(clamp(a) 1000) + (flag & 1).
        expect(gg_tint_encode(0.3f, 0) == 602, @"encode(0.3, 0) = 602", @(gg_tint_encode(0.3f, 0)).stringValue);
        expect(gg_tint_encode(0.3f, 1) == 603, @"encode(0.3, 1) = 603", @(gg_tint_encode(0.3f, 1)).stringValue);
        expect(gg_tint_encode(-1, 0) == 2, @"encode(-1, 0) = 2 (clamped)", @(gg_tint_encode(-1, 0)).stringValue);
        expect(gg_tint_encode(2, 1) == 2003, @"encode(2, 1) = 2003 (clamped)", @(gg_tint_encode(2, 1)).stringValue);
        float a = -1; int32_t flag = -1;
        BOOL dec = gg_tint_decode(603, &a, &flag);
        expect(dec && fabsf(a - 0.3f) < 1e-6f && flag == 1, @"decode(603) = (0.3, 1)", [NSString stringWithFormat:@"%d %g %d", dec, a, flag]);
        expect(!gg_tint_decode(1, &a, &flag), @"decode(1) = no code", @"true");
        // Code carrying the glass appearance (negative): -(2 + 4 round(a 500) + 2 dark + flag). Old positive code: appearance unknown (-1).
        expect(gg_tint_encode_app(0.3f, 0, 1) == -604, @"encode_app(0.3, 0, dark) = -604", @(gg_tint_encode_app(0.3f, 0, 1)).stringValue);
        expect(gg_tint_encode_app(1, 1, 0) == -2003, @"encode_app(1, 1, light) = -2003", @(gg_tint_encode_app(1, 1, 0)).stringValue);
        dec = gg_tint_decode(-605, &a, &flag);
        expect(dec && fabsf(a - 0.3f) < 1e-6f && flag == 1 && gg_tint_appearance(-605) == 1, @"decode(-605) = (0.3, 1, dark)",
               [NSString stringWithFormat:@"%d %g %d %d", dec, a, flag, gg_tint_appearance(-605)]);
        expect(gg_tint_appearance(603) == -1 && gg_tint_appearance(-603) == 0 && gg_tint_appearance(1) == -1,
               @"appearance: positive code unknown, -603 light, Apple value unknown", @"wrong");
        expect(!gg_tint_decode(-1, &a, &flag), @"decode(-1) = no code", @"true");
        // Reading NSGlassTintAmount (default 0.5).
        setTint(prefs, nil);
        expect(GGGlassSystemLegibility() == 0.5f, @"no key: 0.5", @(GGGlassSystemLegibility()).stringValue);
        setTint(prefs, @0.2);
        expect(fabsf(GGGlassSystemLegibility() - 0.2f) < 1e-6f, @"NSGlassTintAmount 0.2", @(GGGlassSystemLegibility()).stringValue);
        // needs_update like 27 +[NSGlassEffectView _legibilityNeedsUpdate]: compares with the applied value.
        expect(!gg_legibility_needs_update(), @"needs_update first call: unchanged", @"true");
        setTint(prefs, @0.7);
        BOOL changed = gg_legibility_needs_update();
        expect(changed && fabsf(gg_legibility_current() - 0.7f) < 1e-6f, @"change to 0.7: changed, current 0.7",
               [NSString stringWithFormat:@"%d %g", changed, gg_legibility_current()]);
        expect(!gg_legibility_needs_update(), @"call again: unchanged", @"true");

        // Receiving the coordinated notification (synthetic payload, uint32 type first) -> NSGlassEffectDiffusionDidChangeNotification
        // only for type 12 with a changed value; short payloads or other types do nothing (and do not crash).
        gg_legibility_install();
        // Regression (Finder hung on Quick Look video): layer.filters contains a CIFilter (Quick Look attaches CIGaussianBlur).
        // A CIFilter throws NSUnknownKeyException for unknown keys (valueForKey:@"type"); the setFilters hook must not throw,
        // and a glass filter after it must still get the code.
        {
            id ci = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CIFilter"), NSSelectorFromString(@"filterWithName:"), @"CIGaussianBlur");
            id glass = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            id layer = [NSClassFromString(@"CALayer") new];
            NSString *thrown = nil;
            @try { ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[ci, glass]); }
            @catch (NSException *e) { thrown = e.name; }
            int32_t gp = [[glass valueForKey:@"inputClampPreserveHue"] intValue];
            expect(ci && glass && !thrown && (gp >= 2 || gp <= -2), @"setFilters with a CIFilter: does not throw, glass still carries the code",
                   [NSString stringWithFormat:@"ci %@ threw %@ code %d", ci, thrown, gp]);
        }
        // Regression (Control Center flashed when returning to the grid): the 26.6 animation changes the face on the very
        // filter object that already carries the app recipe code, then reassigns it. The app must not overwrite that
        // interpolated face with the recipe target values (drawing the final state before the animation runs: the glass cell
        // shows at full strength and then disappears).
        {
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            CGRect bnd = CGRectMake(0, 0, 120, 60);
            [layer setValue:[NSValue valueWithBytes:&bnd objCType:@encode(CGRect)] forKey:@"bounds"];
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.125 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.3 forKey:@"inputFaceColorMatrixSaturation"]; [f setValue:@4 forKey:@"inputBlurRadius"];
            SEL set = NSSelectorFromString(@"setFilters:");
            ((void (*)(id, SEL, id))objc_msgSend)(layer, set, @[f]);   // 26.6 Control Center face -> app writes recipe 5
            int r = -1; bool ri, rd; int32_t rf; float ra;
            BOOL coded = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &ri, &rd, &rf, &ra) && r == GG_R_CC;
            [f setValue:@0.0859 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8626 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.206 forKey:@"inputFaceColorMatrixSaturation"]; [f setValue:@2.75 forKey:@"inputBlurRadius"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, set, @[f]);   // one 26.6 animation frame on the same filter
            double b = [[f valueForKey:@"inputFaceColorMatrixBlack"] doubleValue], s = [[f valueForKey:@"inputFaceColorMatrixSaturation"] doubleValue];
            expect(coded && fabs(b - 0.0859) < 1e-4 && fabs(s - 1.206) < 1e-4, @"filter with a recipe code whose face 26.6 changed: interpolated face kept",
                   [NSString stringWithFormat:@"recipe %d, face %g/%g", r, b, s]);
        }
        // Same bug through the rewrite path: 26.6 changes the face via key paths on the layer (animation), then a bounds change
        // (cells resizing when returning to the grid) triggers a rewrite from the remembered identity. The interpolated face
        // must not be overwritten with the target values.
        {
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            CGRect bnd = CGRectMake(0, 0, 120, 60);
            [layer setValue:[NSValue valueWithBytes:&bnd objCType:@encode(CGRect)] forKey:@"bounds"];
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.125 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.3 forKey:@"inputFaceColorMatrixSaturation"]; [f setValue:@4 forKey:@"inputBlurRadius"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
            [layer setValue:@0.0859 forKeyPath:@"filters.glassBackground.inputFaceColorMatrixBlack"];
            [layer setValue:@1.206 forKeyPath:@"filters.glassBackground.inputFaceColorMatrixSaturation"];
            ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, 140, 70));   // like AppKit (KVC bounds does not go through setBounds:)
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];   // the rewrite runs on a later pass
            double b = [[layer valueForKeyPath:@"filters.glassBackground.inputFaceColorMatrixBlack"] doubleValue];
            double s = [[layer valueForKeyPath:@"filters.glassBackground.inputFaceColorMatrixSaturation"] doubleValue];
            expect(fabs(b - 0.0859) < 1e-4 && fabs(s - 1.206) < 1e-4, @"26.6 changes the face via key path, bounds change: rewrite does not overwrite the face",
                   [NSString stringWithFormat:@"face %g/%g", b, s]);
        }
        // A cell appearing: 26.6 assigns a NEW filter carrying an interpolated face (keep 26.6), then bounds change: a rewrite
        // from the old identity (R5 from before) must not overwrite that animation frame.
        {
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, 120, 60));
            SEL set = NSSelectorFromString(@"setFilters:");
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.125 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.3 forKey:@"inputFaceColorMatrixSaturation"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, set, @[f]);   // R5
            id g = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [g setValue:@0.0859 forKey:@"inputFaceColorMatrixBlack"]; [g setValue:@0.8626 forKey:@"inputFaceColorMatrixWhite"];
            [g setValue:@1.206 forKey:@"inputFaceColorMatrixSaturation"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, set, @[g]);   // animation frame on a new filter
            ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, 150, 80));
            [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
            double b = [[layer valueForKeyPath:@"filters.glassBackground.inputFaceColorMatrixBlack"] doubleValue];
            expect(fabs(b - 0.0859) < 1e-4, @"new filter with an interpolated face, bounds change: no rewrite from the old identity",
                   [NSString stringWithFormat:@"black %g", b]);
        }
        // Regression (Control Center refraction jumped once modules finished appearing): the Control Center module grid is one
        // glass of 13 shapes (CASDFElementLayer under SwiftUI.SDFLayer) with short sides 28/64/140; 27 has one glass per module
        // with its own short side. There is no single x: the app writes no recipe (old code), the shader measures x per cell
        // from the SDF. A single shape (popover, the "System Services" pill) or shapes with the same short side (toolbar
        // button groups): write the recipe.
        for (NSArray *sides in @[@[@64, @140], @[@64], @[@36, @36]]) {
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, 292, 554));
            id shape = [NSClassFromString(@"CALayer") new];
            for (NSNumber *x in sides) {
                id el = [NSClassFromString(@"CASDFElementLayer") new];
                ((void (*)(id, SEL, CGRect))objc_msgSend)(el, @selector(setBounds:), CGRectMake(0, 0, 200, x.doubleValue));
                ((void (*)(id, SEL, id))objc_msgSend)(shape, @selector(addSublayer:), el);
            }
            [layer setValue:shape forKey:@"delegate"];
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.125 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.3 forKey:@"inputFaceColorMatrixSaturation"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
            int r = -1; bool ri, rd; int32_t rf; float ra;
            BOOL coded = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &ri, &rd, &rf, &ra);
            [layer setValue:nil forKey:@"delegate"];
            BOOL mixed = sides.count > 1 && ![sides.firstObject isEqual:sides.lastObject];
            expect(mixed ? !coded : coded, [NSString stringWithFormat:@"glass with shapes of short side %@: %@", [sides componentsJoinedByString:@"/"],
                                                                        mixed ? @"no recipe written" : @"recipe written"],
                   [NSString stringWithFormat:@"code %d", [[f valueForKey:@"inputClampPreserveHue"] intValue]]);
        }
        // Regression (menu bar Wi-Fi panel had a dark square-cornered area): for glass without a 26.6 shadow (panels, menus:
        // the window draws the shadow) the app does not enable the 27 recipe shadow (0.6, radius 24): QuartzCore does not grow
        // the drawing bounds for the shadow, so it is clipped straight at the bounds. Glass with a 26.6 shadow gets the recipe
        // shadow as before.
        for (NSNumber *had in @[@0, @0.4]) {
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            CGRect bnd = CGRectMake(0, 0, 300, 290);
            [layer setValue:[NSValue valueWithBytes:&bnd objCType:@encode(CGRect)] forKey:@"bounds"];
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.2 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.6 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1 forKey:@"inputFaceColorMatrixSaturation"];   // regular active dark (#8)
            CGColorRef black = CGColorCreateGenericRGB(0, 0, 0, 0.4);
            [f setValue:(__bridge id)black forKey:@"inputFaceColorMatrixFillColor"]; CGColorRelease(black);
            [f setValue:had forKey:@"inputShadowOpacity"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
            int r = -1; bool ri, rd; int32_t rf; float ra;
            BOOL coded = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &ri, &rd, &rf, &ra) && r == GG_R_REGULAR;
            double so = [[f valueForKey:@"inputShadowOpacity"] doubleValue];
            BOOL ok = coded && (had.doubleValue > 0 ? so > 0.5 : so == 0);
            expect(ok, [NSString stringWithFormat:@"regular dark, 26.6 shadow %@: recipe shadow %@", had, had.doubleValue > 0 ? @"0.6" : @"0"],
                   [NSString stringWithFormat:@"recipe %d, shadow %g", r, so]);
        }
        // Widgets and notification cards in NotificationCenter. GG_HOST_NC: treat the test process as NotificationCenter. Each
        // case: a CABackdropLayer of size w x h, a glass filter carrying the measured 26.6 face, assigned via setFilters: (hook),
        // then the code and the values the app wrote are read back.
        {
            typedef struct { NSString *name; double b, w, s, f[4], shadow, cw, ch; int r; bool dark, sub; double wantB, wantW, blur,
                             refr, vib, scale; } NCCase;
            NCCase cases[] = {
                {@"widget light 164: chiclet, blur 1, refraction 0, scale 0.5", 0.12, 0.8, 1.2, {0, 0, 0, 0}, 0, 164, 164,
                 GG_R_CHICLET, 0, 0, 0.12, 0.8, 1, 0, -1, 0.5},
                {@"widget dark: light/dark from the face", 0.05, 0.3, 0.8, {0, 0, 0, 0}, 0, 344, 164, GG_R_CHICLET, 1, 0, 0.05, 0.3, 1, 0, -1, 0.5},
                {@"widget light subdued: white 0.73, blur 2, scale 0.25", 0.12, 0.73, 1.2, {0, 0, 0, 0}, 0, 164, 164,
                 GG_R_CHICLET, 0, 1, 0.12, 0.73, 2, 0, -1, 0.25},
                {@"widget boost/tint light: white 1.0", 0.12, 1.0, 1.2, {0, 0, 0, 0}, 0, 164, 164, GG_R_CHICLET, 0, 0, 0.12, 1.0, 1, 0, -1, 0.5},
                {@"inactive widget: legacy blur 10", 0.2, 0.95, 1, {1, 1, 1, 0.1}, 0, 164, 164, GG_R_CHICLET, 0, 0, 0.2, 0.95, 10, 0, -1, -1},
                {@"notification card light 344x99: x 166 -> blur 4, vibrancy 1", 0.5, 1.03, 1, {1, 1, 1, 0.4}, 0.46, 344, 99,
                 GG_R_NOTIF, 0, 0, 0.4, 1.03, 4, 0.6, 1, -1},
                {@"notification card dark covered (subdued) 344x99: blur 8, black 0.075", 0.15, 0.6, 1, {0, 0, 0, 0.4}, 0.28, 344, 99,
                 GG_R_NOTIF, 1, 1, 0.075, 1.125, 8, 0.42, 1, -1},
                {@"x button subdued 20x20: real x, white 0.96", 0.5, 0.96, 1, {1, 1, 1, 0.4}, 0.3, 20, 20, GG_R_NOTIF, 0, 1, 0.4, 0.96, 0, 0.42, 1, -1},
            };
            setenv("GG_HOST_NC", "1", 1);
            for (int k = 0; k < (int)(sizeof cases / sizeof cases[0]); k++) {
                NCCase c = cases[k];
                id layer = [NSClassFromString(@"CABackdropLayer") new];
                ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, c.cw, c.ch));
                [layer setValue:@9.6 forKey:@"marginWidth"];   // 26.6 SwiftUI: margin = its own outer refraction (9.6 on a card)
                id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
                [f setValue:@(c.b) forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@(c.w) forKey:@"inputFaceColorMatrixWhite"];
                [f setValue:@(c.s) forKey:@"inputFaceColorMatrixSaturation"]; [f setValue:@(c.shadow) forKey:@"inputShadowOpacity"];
                CGColorRef fc = CGColorCreateGenericRGB(c.f[0], c.f[1], c.f[2], c.f[3]);
                [f setValue:(__bridge id)fc forKey:@"inputFaceColorMatrixFillColor"]; CGColorRelease(fc);
                ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
                int r = -1; bool ri = 0, rd = 0; int32_t rf; float ra;
                BOOL coded = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &ri, &rd, &rf, &ra);
                double B = [[f valueForKey:@"inputFaceColorMatrixBlack"] doubleValue], W = [[f valueForKey:@"inputFaceColorMatrixWhite"] doubleValue];
                double blur = [[f valueForKey:@"inputBlurRadius"] doubleValue], refr = [[f valueForKey:@"inputRefractionOpacity"] doubleValue];
                id vibv = [f valueForKey:@"inputShadowVibrancyContribution"];
                double vib = vibv ? [vibv doubleValue] : -1, scale = [[layer valueForKey:@"scale"] doubleValue];
                // The backdrop margin must cover the outer refraction written (a 9.6 margin under a 41.5 refraction clips the
                // card shadow into a square-edged halo); it never shrinks.
                double outer = [[f valueForKey:@"inputOuterRefractionAmount"] doubleValue], margin = [[layer valueForKey:@"marginWidth"] doubleValue];
                BOOL ok = coded && r == c.r && rd == c.dark && ri == c.sub && fabs(B - c.wantB) < 1e-3 && fabs(W - c.wantW) < 1e-3
                       && fabs(blur - c.blur) < 1e-3 && fabs(refr - c.refr) < 1e-3 && (c.vib < 0 || fabs(vib - c.vib) < 1e-3)
                       && (c.scale < 0 || fabs(scale - c.scale) < 1e-3) && fabs(margin - fmax(outer, 9.6)) < 1e-3;
                expect(ok, [@"NotificationCenter: " stringByAppendingString:c.name],
                       [NSString stringWithFormat:@"code %d recipe %d dark %d subdued %d face %g/%g blur %g refr %g vib %g scale %g outer %g margin %g",
                        coded, r, rd, ri, B, W, blur, refr, vib, scale, outer, margin]);
            }
            // Widget excludingPlatter layer (vibrantColorMatrix YCC black 0.6/0.7, white 1, saturation 1.1/1.2, the !P branch of
            // ChicletRecipe.PostProcess): 27 does not build it, the app makes this layer transparent (alpha row 0). Other
            // matrices (tint) stay unchanged.
            typedef struct CAColorMatrix { float m[20]; } CAColorMatrix;
            CAColorMatrix fg = {{0.951f, -0.501f, -0.050f, 0, 0.6f, -0.149f, 0.599f, -0.051f, 0, 0.6f, -0.149f, -0.501f, 1.049f, 0, 0.6f, 0, 0, 0, 1, 0}};
            CAColorMatrix tint = {{0.202f, 0.679f, 0.069f, 0, 0.05f, 0.04f, 0.136f, 0.014f, 0, 0.01f, 0.02f, 0.068f, 0.007f, 0, 0.005f, 0, 0, 0, 1, 0}};
            for (int k = 0; k < 2; k++) {
                id layer = [NSClassFromString(@"CALayer") new];
                id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"vibrantColorMatrix");
                CAColorMatrix m = k == 0 ? fg : tint;
                [f setValue:[NSValue value:&m withObjCType:@encode(CAColorMatrix)] forKey:@"inputColorMatrix"];
                ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
                CAColorMatrix out = {{0}};
                [[f valueForKey:@"inputColorMatrix"] getValue:&out size:sizeof out];
                BOOL hidden = out.m[15] == 0 && out.m[16] == 0 && out.m[17] == 0 && out.m[18] == 0 && out.m[19] == 0;
                BOOL same = memcmp(&out, &m, sizeof m) == 0;
                expect(k == 0 ? hidden : same, k == 0 ? @"NotificationCenter: widget excludingPlatter layer is transparent"
                                                      : @"NotificationCenter: tint matrix unchanged",
                       [NSString stringWithFormat:@"alpha %g %g %g %g %g", out.m[15], out.m[16], out.m[17], out.m[18], out.m[19]]);
            }
            unsetenv("GG_HOST_NC");
            // Outside NotificationCenter: a widget face is not a chiclet.
            id layer = [NSClassFromString(@"CABackdropLayer") new];
            ((void (*)(id, SEL, CGRect))objc_msgSend)(layer, @selector(setBounds:), CGRectMake(0, 0, 164, 164));
            id f = ((id (*)(id, SEL, id))objc_msgSend)(NSClassFromString(@"CAFilter"), NSSelectorFromString(@"filterWithType:"), @"glassBackground");
            [f setValue:@0.12 forKey:@"inputFaceColorMatrixBlack"]; [f setValue:@0.8 forKey:@"inputFaceColorMatrixWhite"];
            [f setValue:@1.2 forKey:@"inputFaceColorMatrixSaturation"];
            ((void (*)(id, SEL, id))objc_msgSend)(layer, NSSelectorFromString(@"setFilters:"), @[f]);
            int r = -1; bool ri, rd; int32_t rf; float ra;
            BOOL coded = gg_recipe_decode([[f valueForKey:@"inputClampPreserveHue"] intValue], &r, &ri, &rd, &rf, &ra);
            expect(!(coded && r == GG_R_CHICLET), @"outside NotificationCenter: a widget face does not become a chiclet", @(r).stringValue);
        }
        __block int posts = 0;
        [[NSNotificationCenter defaultCenter] addObserverForName:@"NSGlassEffectDiffusionDidChangeNotification" object:nil
                                                           queue:nil usingBlock:^(NSNotification *n) { posts++; }];
        void (^pump)(void) = ^{ [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]]; };
        uint32_t p12[4] = {12, 0, 0, 0}, p3[4] = {3, 0, 0, 0};
        gg_legibility_test_receive(p12, 2); pump();
        expect(posts == 0, @"2 byte payload: ignored", @(posts).stringValue);
        setTint(prefs, @0.4);
        gg_legibility_test_receive(p3, 16); pump();
        expect(posts == 0, @"type 3: ignored", @(posts).stringValue);
        gg_legibility_test_receive(p12, 16); pump();
        expect(posts == 1, @"type 12 after a change: posted exactly once", @(posts).stringValue);
        gg_legibility_test_receive(p12, 16); pump();
        expect(posts == 1, @"type 12 with an unchanged value: not posted", @(posts).stringValue);

        // Write API like 27 NSGlassEffectView.Legibility.setSystemLegibility (GG_PREFS_WRITE replaces the global domain,
        // GG_TINT_NOPOST: no coordinated notification to WindowServer).
        setenv("GG_PREFS_WRITE", getenv("GG_PREFS"), 1); setenv("GG_TINT_NOPOST", "1", 1);
        int err = GGGlassSetSystemLegibility(0.45f, false, nil);
        NSNumber *w = [NSDictionary dictionaryWithContentsOfFile:prefs][@"NSGlassTintAmount"];
        expect(err == 0 && fabsf(w.floatValue - 0.45f) < 1e-6f, @"setSystemLegibility writes 0.45", [NSString stringWithFormat:@"%d %@", err, w]);
        GGGlassSetSystemLegibility(0, true, nil);
        expect([NSDictionary dictionaryWithContentsOfFile:prefs][@"NSGlassTintAmount"] == nil, @"reset: deletes the key", @"key remains");

        // Diagnostics: Darwin notify com.goldengate.legibility.dump -> writes the applied value and the codes on the process
        // glass filters to <GG_HOME>/Library/Logs/GoldenGate/legibility.log.
        notify_post("com.goldengate.legibility.dump");
        pump();
        NSString *logPath = [@(getenv("GG_HOME")) stringByAppendingPathComponent:@"Library/Logs/GoldenGate/legibility.log"];
        NSString *log = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        expect([log containsString:[NSString stringWithFormat:@"pid %d", getpid()]] && [log containsString:@"current 0.40"] &&
               [log containsString:@"codes []"] && [log containsString:@"filter []"] && [log containsString:@"context 0"],
               @"diagnostic dump writes pid, applied value, codes, filter types, context count", log ?: @"(no log)");

        // Trace (Darwin notify com.goldengate.legibility.trace): records glass filter parameters (model and presentation) per
        // frame for 4 s to legibility-trace.log, starting with a "trace start" line and ending with "trace end".
        notify_post("com.goldengate.legibility.trace");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:4.5]];
        NSString *tracePath = [@(getenv("GG_HOME")) stringByAppendingPathComponent:@"Library/Logs/GoldenGate/legibility-trace.log"];
        NSString *trace = [NSString stringWithContentsOfFile:tracePath encoding:NSUTF8StringEncoding error:nil];
        expect([trace containsString:@"trace start"] && [trace containsString:@"trace end"], @"trace writes start and end",
               trace ?: @"(no log)");

        // 27 previewSystemLegibility (0x18b31ef24): writes defaults, only this process changes (local post), no broadcast
        // to other apps; commitSystemLegibility (0x18b31efc8): broadcasts the coordinated notification with the previewed value.
        int before = posts;
        GGGlassPreviewSystemLegibility(0.3f, false);
        pump();
        NSNumber *pv = [NSDictionary dictionaryWithContentsOfFile:prefs][@"NSGlassTintAmount"];
        expect(fabsf(pv.floatValue - 0.3f) < 1e-6f && fabsf(gg_legibility_current() - 0.3f) < 1e-6f && posts == before + 1,
               @"preview: writes 0.3, applies immediately in the process, one local post",
               [NSString stringWithFormat:@"%@ %.2f %d", pv, gg_legibility_current(), posts - before]);
        __block int cerr = -9;
        expect(GGGlassCommitSystemLegibility(^(int e) { cerr = e; }) == 0 && cerr == 0 &&
               fabsf([[NSDictionary dictionaryWithContentsOfFile:prefs][@"NSGlassTintAmount"] floatValue] - 0.3f) < 1e-6f,
               @"commit: keeps 0.3 and calls completion", @(cerr).stringValue);
    }
    return gFail;
}
