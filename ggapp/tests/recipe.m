// Headless test of Recipe27 (in-app glass 27 recipes + recipe codes).
// Prints "OK  ..." / "FAIL ..." and exits 1 if any case fails.
// Build: clang -arch x86_64 -fobjc-arc -framework Foundation -I ggapp/Legibility ggapp/Legibility/Recipe27.c recipe.m
#import <Foundation/Foundation.h>
#import <math.h>
#import "Recipe27.h"

static int gFail, gCount;
static void expect(BOOL ok, NSString *name, NSString *got) {
    gCount++;
    printf("%s %s%s\n", ok ? "OK " : "FAIL", name.UTF8String, ok ? "" : [NSString stringWithFormat:@" (got: %@)", got].UTF8String);
    if (!ok) gFail = 1;
}
static BOOL near(float a, float b) { return fabsf(a - b) <= 1e-4f * fmaxf(1, fabsf(b)); }
static BOOL near4(const float *a, float x, float y, float z, float w) { return near(a[0], x) && near(a[1], y) && near(a[2], z) && near(a[3], w); }
static NSString *dump(GG27Params p) {
    return [NSString stringWithFormat:@"face %g/%g/%g fill %g,%g,%g,%g bleed %g/%g/%g blur %g op %g,%g,%g,%g dist %g,%g,%g,%g "
            "in %g/%g out %g/%g refr %g bleed %g/%g/%g shadow %g/%g",
            p.faceBlack, p.faceWhite, p.faceSat, p.faceFill[0], p.faceFill[1], p.faceFill[2], p.faceFill[3], p.bleedBlack,
            p.bleedWhite, p.bleedSat, p.blurRadius, p.blurOpacity[0], p.blurOpacity[1], p.blurOpacity[2], p.blurOpacity[3],
            p.blurDistance[0], p.blurDistance[1], p.blurDistance[2], p.blurDistance[3], p.innerAmount, p.innerHeight,
            p.outerAmount, p.outerHeight, p.refractionOpacity, p.bleedAmount, p.bleedHeight, p.bleedOpacity, p.shadowOpacity,
            p.shadowRadius];
}

int main(void) {
    @autoreleasepool {
        // Encoding: every combination decodes correctly, even after QuartzCore converts int -> float -> half (_lph).
        int bad = 0, below = 0;
        for (int r = 0; r < 16; r++) for (int in = 0; in < 2; in++) for (int f = 0; f < 2; f++) for (int dk = 0; dk < 2; dk++)
            for (int q = 0; q <= 78; q++) {
                int32_t p = gg_recipe_encode(r, in, dk, f, q / 78.0f);
                if (abs(p) < 2048) below++;
                int32_t ph = (int32_t)(float)(_Float16)(float)p;
                int rr; bool ii, dd; int32_t ff; float aa;
                if (ph != p || !gg_recipe_decode(ph, &rr, &ii, &dd, &ff, &aa) || rr != r || ii != in || dd != dk || ff != f
                    || fabsf(aa - q / 78.0f) > 1e-6f) bad++;
            }
        expect(bad == 0 && below == 0, @"recipe code: 16 x 2 x 2 x 2 x 79 combinations, |P| >= 2048, decodes correctly through half",
               [NSString stringWithFormat:@"wrong %d, below 2048 %d", bad, below]);
        int rr; bool ii, dd; int32_t ff; float aa;
        expect(!gg_recipe_decode(2003, &rr, &ii, &dd, &ff, &aa) && !gg_recipe_decode(-2005, &rr, &ii, &dd, &ff, &aa)
               && !gg_recipe_decode(0, &rr, &ii, &dd, &ff, &aa), @"old codes (|P| < 2048) are not recipe codes", @"true");
        expect(!gg_recipe_decode(2049, &rr, &ii, &dd, &ff, &aa), @"2049 (not exactly representable as half) is rejected", @"true");
        bool okHalf = gg_recipe_decode(gg_recipe_encode(GG_R_REGULAR, 0, 0, 0, 0.5f), &rr, &ii, &dd, &ff, &aa) && aa == 0.5f;
        expect(okHalf, @"a = 0.5 decodes to exactly 0.5 (q = 39/78)", @(aa).stringValue);
        expect(gg_recipe_encode(GG_R_REGULAR, 0, 1, 0, 0.5f) < 0 && gg_recipe_encode(GG_R_REGULAR, 0, 0, 0, 0.5f) > 0,
               @"sign: negative when dark", @"wrong");

        // Recipes (CA level), per values measured from 27.
        GG27Params p = gg27_recipe_params(GG_R_REGULAR, false, false, 0.5f, 36);
        expect(near(p.blurRadius, 0) && near4(p.blurOpacity, 1, 0.5, 0.5, 1) && near4(p.blurDistance, -18, -1, 0, 0)
               && near(p.innerAmount, -18) && near(p.innerHeight, 9) && near(p.outerAmount, 16) && near(p.outerHeight, 16)
               && near(p.refractionOpacity, 0.6f) && near(p.faceBlack, 0.4f) && near(p.faceWhite, 1.03f) && near(p.faceSat, 1.2f)
               && near4(p.faceFill, 1, 1, 1, 0.2f) && near(p.bleedBlack, 0.9f) && near(p.bleedWhite, 1) && near(p.bleedSat, 1.2f)
               && near(p.bleedOpacity, 0) && near(p.bleedAmount, 12.6f) && near(p.bleedHeight, 12.6f)
               && near(p.shadowOpacity, 0.04f) && near(p.shadowRadius, 4), @"regular light x 36", dump(p));
        p = gg27_recipe_params(GG_R_REGULAR, true, true, 0.5f, 200);
        expect(near(p.blurRadius, 4) && near4(p.blurOpacity, 1, 1, 1, 1) && near4(p.blurDistance, 0, 0, 0, 0)
               && near(p.faceBlack, 0.08f) && near(p.faceWhite, 1.125f) && near(p.faceSat, 1.3f) && near4(p.faceFill, 0, 0, 0, 0)
               && near(p.outerAmount, 0) && near(p.refractionOpacity, 0) && near(p.bleedOpacity, 0) && near(p.shadowOpacity, 0)
               && near(p.bleedBlack, 0.125f) && near(p.bleedWhite, 0.5f) && near(p.bleedSat, 1), @"regular dark inactive x 200", dump(p));
        p = gg27_recipe_params(GG_R_REGULAR, false, false, 1, 36);
        expect(near4(p.faceFill, 1, 1, 1, 0.5f), @"regular light a 1: fill (1,1,1,0.5)", dump(p));
        p = gg27_recipe_params(GG_R_REGULAR, true, false, 0, 36);
        expect(near4(p.faceFill, 0.125f, 0.125f, 0.125f, 0), @"regular dark a 0: fill (black, 0)", dump(p));
        p = gg27_recipe_params(GG_R_CLEAR, false, false, 0.25f, 36);
        expect(near(p.blurRadius, 0.375f) && near(p.faceBlack, 0.125f) && near(p.faceWhite, 1.08f) && near(p.faceSat, 1.06f)
               && near4(p.faceFill, 1, 1, 1, 0) && near(p.innerAmount, -23.4f) && near(p.innerHeight, 12.96f)
               && near(p.refractionOpacity, 0) && near(p.bleedOpacity, 0) && near(p.shadowOpacity, 0), @"clear a 0.25", dump(p));
        p = gg27_recipe_params(GG_R_POPOVER, false, true, 0.5f, 36);
        expect(near(p.innerHeight, 5) && near(p.blurRadius, 0) && near4(p.blurOpacity, 1, 0.5, 0.5, 1) && near(p.faceWhite, 1.03f)
               && near(p.refractionOpacity, 0.6f) && near(p.shadowOpacity, 0.04f), @"popover inactive: inner 5, Spec level as active", dump(p));
        p = gg27_recipe_params(GG_R_MENU, false, true, 0.5f, 200);
        expect(near(p.blurRadius, 12) && near(p.faceBlack, 0.8f) && near(p.faceWhite, 0.96f) && near(p.faceSat, 1.2f)
               && near4(p.faceFill, 0.96f, 0.96f, 0.96f, 0.04f) && near(p.shadowOpacity, 0), @"menu inactive light x 200", dump(p));
        p = gg27_recipe_params(GG_R_DOCK, true, false, 0.5f, 60);
        expect(near(p.blurRadius, 1.5f) && near(p.faceBlack, 0.05f) && near(p.faceWhite, 0.92f) && near(p.faceSat, 1.25f)
               && near4(p.faceFill, 0, 0, 0, 0.02f) && near(p.innerAmount, -10.8f) && near(p.innerHeight, 4.8f)
               && near(p.outerAmount, 25.2f) && near(p.outerHeight, 16) && near(p.refractionOpacity, 0.2f) && near(p.shadowOpacity, 0),
               @"Dock dark x 60", dump(p));
        p = gg27_recipe_params(GG_R_CC, false, false, 0.5f, 50);
        expect(near(p.blurRadius, 4) && near4(p.blurOpacity, 1, 0.1f, 0.5f, 1) && near4(p.blurDistance, -100, -1, 0, 0)
               && near(p.innerAmount, -80) && near(p.innerHeight, 11.25f) && near(p.outerAmount, 3.57f) && near(p.outerHeight, 1.785f)
               && near(p.refractionOpacity, 0.1525f) && near(p.faceBlack, 0.125f) && near(p.faceWhite, 0.8f) && near(p.faceSat, 1.2f)
               && near4(p.faceFill, 0, 0, 0, 0), @"Control Center x 50", dump(p));
        p = gg27_recipe_params(GG_R_SIDEBAR, true, false, 0.5f, 200);
        expect(near(p.faceBlack, 0.1f) && near(p.faceWhite, 0.5f) && near(p.faceSat, 0.6f) && near4(p.faceFill, 0, 0, 0, 0)
               && near(p.bleedBlack, 0.1f) && near(p.bleedWhite, 0.5f) && near(p.bleedSat, 1.5f) && near(p.refractionOpacity, 0)
               && near(p.shadowOpacity, 0) && near(p.blurRadius, 4) && near(p.bleedOpacity, 0.8f), @"sidebar dark x 200", dump(p));
        p = gg27_recipe_params(GG_R_REGULAR, false, false, 0.5f, 0);
        expect(p.innerHeight >= 1e-6f && p.outerHeight >= 1e-6f, @"x 0: height clamped >= 1e-6", dump(p));

        // 26.6 face -> recipe (kSigs26 table).
        struct { double b, w, s, f[4]; int r; bool d, i; } sigs[] = {
            {0.5, 0.95, 1, {1, 1, 1, 0.35}, 0, 0, 1}, {0.2, 0.6, 1, {0, 0, 0, 0.35}, 0, 1, 1}, {0.2, 0.95, 1, {1, 1, 1, 0.1}, 1, 0, 0},
            {0.05, 0.8, 1, {1, 1, 1, 0.05}, 1, 1, 0}, {0.5, 1.03, 1, {1, 1, 1, 0.4}, 0, 0, 0}, {0.8, 0.97, 1, {1, 1, 1, 0.25}, -1, 0, 0},
            {0.75, 0.97, 1.1, {0, 0, 0, 0}, -1, 0, 0}, {0.5, 1.0, 1, {0, 0, 0, 0}, -1, 0, 0}, {0.2, 0.6, 1, {0, 0, 0, 0.4}, 0, 1, 0},
            {0.15, 0.9, 1.05, {1, 1, 1, 0.1}, 4, 0, 0}, {0.075, 0.9, 1.06, {0, 0, 0, 0.1}, 4, 1, 0},
            {0.8, 0.96, 1, {0.96, 0.96, 0.96, 0.04}, 3, 0, 1}, {0.15, 0.3, 1, {1, 1, 1, 0}, 3, 1, 1}, {0.075, 1.15, 1.06, {1, 1, 1, 0}, 1, 0, 0},
            {0.125, 0.8, 1.3, {0, 0, 0, 0}, 5, 0, 0}, {0.16, 1.05, 1.3, {0, 0, 0, 0}, -2, 0, 0}, {0.2, 1.1, 1.6, {0, 0, 0, 0}, -2, 0, 0},
            {0.4, 1.03, 1.2, {1, 1, 1, 0.2}, 2, 0, 0}, {0.1, 0.5, 0.6, {0, 0, 0, 0}, 2, 1, 0},
        };
        int sbad = 0;
        for (int i = 0; i < 19; i++) {
            bool d = 0, in = 0;
            int r = gg_face_recipe(sigs[i].b, sigs[i].w, sigs[i].s, sigs[i].f, &d, &in);
            if (r != sigs[i].r || (r >= 0 && (d != sigs[i].d || in != sigs[i].i))) { sbad++; printf("    face #%d -> %d %d %d\n", i, r, d, in); }
        }
        expect(sbad == 0, @"26.6 face -> recipe: 19 signatures", @(sbad).stringValue);
        double lum[4] = {1, 1, 1, 0.589};
        bool d = 0, in = 0;
        expect(gg_face_recipe(0.127, 0.723, 1, lum, &d, &in) == -1, @"adaptive face (button at rest) -> -1", @"other");
        // 26.6 show/hide animation frames (Control Center returning to the grid): black/white/sat move linearly from the
        // original face (0, 1, 1) to the recipe face. Not adaptive glass: -2 (keep 26.6, the shader interpolates), otherwise
        // the app writes the 27 regular recipe onto a cell that is appearing (an opaque white hollow cell before the animation runs).
        double none[4] = {0, 0, 0, 0}, white4[4] = {1, 1, 1, 0.4 * 0.5};
        int rid = gg_face_recipe(0, 1, 1, none, &d, &in), rcc = gg_face_recipe(0.0859, 0.8626, 1.206, none, &d, &in);
        int rreg = gg_face_recipe(0.25, 1.015, 1, white4, &d, &in);   // regular light (0.5, 1.03, 1, white fill 0.4) at t = 0.5
        expect(rid == -2 && rcc == -2 && rreg == -2, @"original face and interpolated faces (CC t 0.687, regular t 0.5) -> -2",
               [NSString stringWithFormat:@"%d %d %d", rid, rcc, rreg]);
        // Widget (27 ChicletRecipe, P branch): ClearSpec + Modifier + DiffusionBlur.
        p = gg27_recipe_params(GG_R_CHICLET, false, false, 0.5f, 164);
        expect(near(p.faceBlack, 0.12f) && near(p.faceWhite, 0.8f) && near(p.faceSat, 1.2f) && near4(p.faceFill, 0, 0, 0, 0)
               && near(p.blurRadius, 1) && near4(p.blurOpacity, 1, 0.5f, 0.5f, 1) && near4(p.blurDistance, -82, -1, 0, 0)
               && near(p.innerAmount, -60) && near(p.innerHeight, 20) && near(p.outerAmount, 57.4f) && near(p.outerHeight, 21.32f)
               && near(p.refractionOpacity, 0) && near(p.bleedOpacity, 0) && near(p.shadowOpacity, 0) && near(p.shadowVibrancy, 0),
               @"widget light x 164 a 0.5", dump(p));
        p = gg27_recipe_params(GG_R_CHICLET, true, false, 0.25f, 164);
        expect(near(p.faceBlack, 0.05f) && near(p.faceWhite, 0.3f) && near(p.faceSat, 0.8f) && near(p.blurRadius, 0.75f),
               @"widget dark a 0.25: DiffusionBlur 0.5 + 0.5 (2a)", dump(p));
        p = gg27_recipe_params(GG_R_CHICLET, false, false, 1, 164);
        expect(near(p.blurRadius, 1), @"widget a 1: blur 1 (the a > 0.5 part is blur fill, handled by the shader)", dump(p));
        p = gg27_recipe_params(GG_R_CHICLET, false, true, 0.5f, 164);
        expect(near(p.faceBlack, 0.2f) && near(p.faceWhite, 0.95f) && near(p.faceSat, 1) && near4(p.faceFill, 1, 1, 1, 0.1f)
               && near(p.blurRadius, 10) && near4(p.blurOpacity, 1, 1, 1, 1) && near4(p.blurDistance, 0, 0, 0, 0)
               && near(p.refractionOpacity, 0), @"inactive widget: legacy style (0x195e7b764) x 164", dump(p));
        p = gg27_recipe_params(GG_R_CHICLET, true, true, 0.5f, 48);
        expect(near(p.faceBlack, 0.05f) && near(p.faceWhite, 0.8f) && near4(p.faceFill, 1, 1, 1, 0.05f) && near(p.blurRadius, 5),
               @"inactive widget dark x 48: blur 5", dump(p));
        // Notifications (NotificationCenterRecipe): 27 regular active + shadow vibrancy 1; cards use x = 166 (surfaceSize .medium).
        p = gg27_recipe_params(GG_R_NOTIF, false, true, 0.5f, 166);
        expect(near(p.blurRadius, 4) && near(p.faceBlack, 0.4f) && near(p.faceWhite, 1.03f) && near(p.outerAmount, 41.5f)
               && near(p.outerHeight, 33.2f) && near(p.refractionOpacity, 0.6f) && near(p.bleedOpacity, 0.5f)
               && near(p.shadowOpacity, 0.4f) && near(p.shadowRadius, 24) && near(p.shadowVibrancy, 1),
               @"notification light x 166: regular active (inactive ignored) + vibrancy 1", dump(p));
        // Subdued (ApplyLegacySubvariant -> 0x195e79e30): blur x2, refraction x0.7, shadow x0.6, light white -0.07, dark black -0.05.
        gg27_subdued(&p, false);
        expect(near(p.blurRadius, 8) && near(p.refractionOpacity, 0.42f) && near(p.shadowOpacity, 0.24f) && near(p.shadowRadius, 14.4f)
               && near(p.faceWhite, 0.96f) && near(p.faceBlack, 0.4f) && near(p.bleedOpacity, 0.25f),
               @"notification light subdued (edge bleed x0.5: Parameters+0x180 0x195e7a02c)", dump(p));
        p = gg27_recipe_params(GG_R_NOTIF, true, false, 0.5f, 166); gg27_subdued(&p, true);
        expect(near(p.faceBlack, 0.075f) && near(p.faceWhite, 1.125f) && near(p.shadowOpacity, 0.36f), @"notification dark subdued", dump(p));
        p = gg27_recipe_params(GG_R_CHICLET, true, false, 0.5f, 164); gg27_subdued(&p, true);
        expect(near(p.faceBlack, 0) && near(p.blurRadius, 2), @"widget dark subdued: black 0, blur 2", dump(p));
        // backdropScale = resolutionAdequacy(2.0, [0.25, 0.5]) (BackdropScaleResolutionEstimator 0x195e9fd78).
        float bs[] = {gg27_backdrop_scale(1, 0, 0, 1), gg27_backdrop_scale(1, 0, 0, 0.5f), gg27_backdrop_scale(0.5f, 0, 0, 1),
                      gg27_backdrop_scale(1, 0, 0.5f, 1), gg27_backdrop_scale(1, 0, 1, 1)};
        expect(near(bs[0], 0.5f) && near(bs[1], 0.25f) && near(bs[2], 0.5f) && near(bs[3], 0.25f) && near(bs[4], 0.25f),
               @"backdropScale: 1x 0.5, 2x 0.25, blur 0.5 capped 0.5, blur fill 0.5 -> 0.25, visibility 0 -> 0.25",
               [NSString stringWithFormat:@"%g %g %g %g %g", bs[0], bs[1], bs[2], bs[3], bs[4]]);
        // 26.6 faces in NotificationCenter (measured).
        struct { double b, w, s, f[4]; int r; bool d, i, sub, boost; } nc[] = {
            {0.12, 0.8, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 0, 0}, {0.05, 0.3, 0.8, {0, 0, 0, 0}, GG_R_CHICLET, 1, 0, 0, 0},
            {0.12, 1.0, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 0, 1}, {0.12, 0.73, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 1, 0},
            {0.0, 0.3, 0.8, {0, 0, 0, 0}, GG_R_CHICLET, 1, 0, 1, 0}, {0.12, 0.93, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 1, 1},
            {0.2, 0.95, 1, {1, 1, 1, 0.1}, GG_R_CHICLET, 0, 1, 0, 0}, {0.05, 0.8, 1, {1, 1, 1, 0.05}, GG_R_CHICLET, 1, 1, 0, 0},
            {0.2, 0.88, 1, {1, 1, 1, 0.1}, GG_R_CHICLET, 0, 1, 1, 0}, {0.0, 0.8, 1, {1, 1, 1, 0.05}, GG_R_CHICLET, 1, 1, 1, 0},
            {0.5, 1.03, 1, {1, 1, 1, 0.4}, GG_R_NOTIF, 0, 0, 0, 0}, {0.2, 0.6, 1, {0, 0, 0, 0.4}, GG_R_NOTIF, 1, 0, 0, 0},
            {0.5, 0.96, 1, {1, 1, 1, 0.4}, GG_R_NOTIF, 0, 0, 1, 0}, {0.15, 0.6, 1, {0, 0, 0, 0.4}, GG_R_NOTIF, 1, 0, 1, 0},
            {0.5, 0.95, 1, {1, 1, 1, 0.35}, -1, 0, 0, 0, 0}, {0.8, 0.97, 1, {1, 1, 1, 0.25}, -1, 0, 0, 0, 0},
        };
        int nbad = 0;
        for (int k = 0; k < 16; k++) {
            bool dd = 0, ii2 = 0, sb = 0, bo = 0;
            int r = gg_face_nc(nc[k].b, nc[k].w, nc[k].s, nc[k].f, &dd, &ii2, &sb, &bo);
            if (r != nc[k].r || (r >= 0 && (dd != nc[k].d || ii2 != nc[k].i || sb != nc[k].sub || bo != nc[k].boost))) {
                nbad++; printf("    nc #%d -> %d %d %d %d %d\n", k, r, dd, ii2, sb, bo);
            }
        }
        expect(nbad == 0, @"26.6 NotificationCenter face -> widget/notification: 16 signatures", @(nbad).stringValue);
        printf(gFail ? "TOTAL: some failed\n" : "TOTAL: %d/%d passed\n", gCount, gCount);
    }
    return gFail;
}
