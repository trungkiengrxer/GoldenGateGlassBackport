// Glass 27 recipes at the CA level and recipe codes. Same branches as gg27_params in
// glass-harness/shaders/glass26_replica.metal but at the CA level (QuartzCore applies the texel factor and inverts height).
// Simplification: hand copy of the shader, locked by ggapp/tests/recipe.m and classify.swift; change one side, change both.
#include "Recipe27.h"
#include <math.h>
#include <stdlib.h>

static float lin(float x, float x0, float x1, float y0, float y1) {   // ClampedLinearMap, upper = nil
    float t = fminf(fmaxf((x - x0) / (x1 - x0), 0), 1);
    return y0 + (y1 - y0) * t;
}
static float clampf(float v, float lo, float hi) { return fminf(fmaxf(v, lo), hi); }
static const float kNeutral = 3.4526698e-4f;   // RegularDiffusionAmount is skipped when |a - 0.5| < this value (0x39b504f3)

/// 27 ChicletRecipe, P branch: ClearSpec (BaseSpec) + Modifier + DiffusionBlur.
/// inactive: ApplyLegacySubvariant rebuilds the legacy style 0x195e7b764 (face, blur 48..120 -> 5..10, opacities 1, distances 0).
static GG27Params gg27_chiclet(bool dark, bool inactive, float a, float x) {
    GG27Params p = {0};
    p.innerAmount = fmaxf(-0.65f * x, -60); p.innerHeight = fmaxf(clampf(0.15f * x, 0, 20), 1e-6f);
    p.outerAmount = 0.35f * x; p.outerHeight = fmaxf(0.13f * x, 1e-6f);   // outer opacity 0 (ClearSpec), kept to match 27
    float t = a <= 0 ? 0 : a <= 0.5f ? 2 * a : 1;                          // DiffusionBlur (0.5, 1.0), not scaled by pixelLength
    p.blurRadius = inactive ? lin(x, 48, 120, 5, 10) : 0.5f + 0.5f * t;
    float op[4] = {1, inactive ? 1 : 0.5f, inactive ? 1 : 0.5f, 1}, di[4] = {inactive ? 0 : -0.5f * x, inactive ? 0 : -1, 0, 0};
    for (int i = 0; i < 4; i++) { p.blurOpacity[i] = op[i]; p.blurDistance[i] = di[i]; }
    if (inactive) {
        p.faceBlack = dark ? 0.05f : 0.2f; p.faceWhite = dark ? 0.8f : 0.95f; p.faceSat = 1;
        p.faceFill[0] = p.faceFill[1] = p.faceFill[2] = 1; p.faceFill[3] = dark ? 0.05f : 0.1f;
    } else { p.faceBlack = dark ? 0.05f : 0.12f; p.faceWhite = dark ? 0.3f : 0.8f; p.faceSat = dark ? 0.8f : 1.2f; }
    p.bleedBlack = 0.75f; p.bleedWhite = 1; p.bleedSat = 1.2f;   // BaseSpec; edge bleed opacity 0
    p.bleedAmount = p.bleedHeight = 0.35f * x;
    p.shadowRadius = lin(x, 64, 160, 4, 24);                     // shadow opacity 0
    return p;
}

void gg27_subdued(GG27Params *p, bool dark) {
    p->blurRadius *= 2; p->refractionOpacity *= 0.7f; p->shadowOpacity *= 0.6f; p->shadowRadius *= 0.6f; p->bleedOpacity *= 0.5f;
    if (dark) p->faceBlack = fmaxf(p->faceBlack - 0.05f, 0); else p->faceWhite -= 0.07f;
}

float gg27_backdrop_scale(float blur, float faceFill, float blurFill, float pl) {
    const float buckets[2] = {0.25f, 0.5f}, ratio = 2;
    float vis = (1 - clampf(faceFill, 0, 1)) * (1 - clampf(blurFill, 0, 1));
    if (vis <= 1.1920929e-7f) return buckets[0];
    float needed = ratio * blur / vis;
    for (int i = 0; i < 2; i++) if (pl / buckets[i] <= needed) return buckets[i];
    return buckets[1];
}

GG27Params gg27_recipe_params(int recipe, bool dark, bool inactive, float a, float x) {
    GG27Params p = {0};
    a = isnan(a) ? 0.5f : clampf(a, 0, 1);
    x = fmaxf(isnan(x) ? 0 : x, 0);
    if (recipe == GG_R_CHICLET) return gg27_chiclet(dark, inactive, a, x);
    if (recipe == GG_R_NOTIF) {   // NotificationCenterRecipe: regular active + ShadowVibrancy, never inactive
        p = gg27_recipe_params(GG_R_REGULAR, dark, false, a, x);
        p.shadowVibrancy = 1;
        return p;
    }
    bool clear = recipe == GG_R_CLEAR, sidebar = recipe == GG_R_SIDEBAR, menu = recipe == GG_R_MENU, dock = recipe == GG_R_DOCK,
         cc = recipe == GG_R_CC, popover = recipe == GG_R_POPOVER;
    bool regLike = recipe == GG_R_REGULAR || menu || popover, clearFam = clear || dock || cc;
    // Spec level inactive: RegularRecipe.Inactive, MenuRecipe.Inactive. Popover only changes the Parameters level (shader).
    bool inact = inactive && (recipe == GG_R_REGULAR || menu);
    bool slid = fabsf(a - 0.5f) >= kNeutral;

    p.innerAmount = cc ? fmaxf(-2 * x, -80) : fmaxf((dock ? -0.18f : clear ? -0.65f : -0.5f) * x, -60);
    p.innerHeight = popover ? 5 : cc ? clampf(0.225f * x, 0, 25) : clampf((dock ? 0.08f : clear ? 0.36f : 0.25f) * x, 0, 20);
    p.outerAmount = cc ? 0.0714f * x : fmaxf((dock ? 0.42f : 0.25f) * x, 16);
    p.outerHeight = cc ? 0.0357f * x : fmaxf((dock ? 0.13f : 0.2f) * x, 16);
    if (inact) { p.outerAmount = 0; p.outerHeight = 16; }   // DisableOuterRefaction (height kept finite, amount 0)
    p.innerHeight = fmaxf(p.innerHeight, 1e-6f); p.outerHeight = fmaxf(p.outerHeight, 1e-6f);
    p.refractionOpacity = cc ? 0.1525f : dock ? 0.2f : (regLike && !inact) ? 0.6f : 0;

    float clearBlur = (cc ? 4.0f : dock ? 1.5f : 0.75f) * (slid && a < 0.5f ? 2 * a : 1);
    p.blurRadius = clearFam ? clearBlur : inact ? lin(x, 64, 160, menu ? 6 : 2, menu ? 12 : 4) : lin(x, 64, 160, 0, 4);
    float op[4] = {1, inact ? 1 : cc ? 0.1f : 0.5f, inact ? 1 : 0.5f, 1};
    float di[4] = {inact ? 0 : cc ? -100 : -0.5f * x, inact ? 0 : -1, 0, 0};
    for (int i = 0; i < 4; i++) { p.blurOpacity[i] = op[i]; p.blurDistance[i] = di[i]; }

    float b, w, s, f[4] = {0, 0, 0, 0};
    if (cc) { b = 0.125f; w = 0.8f; s = 1.2f; }
    else if (dock) { b = dark ? 0.05f : 0.15f; w = dark ? 0.92f : 0.9f; s = 1.25f; if (dark) f[3] = 0.02f; else f[0] = f[1] = f[2] = 1; }
    else if (clear) { b = 0.125f; w = 1.08f; s = 1.06f; f[0] = f[1] = f[2] = 1; }
    else if (dark) { b = sidebar ? 0.1f : 0.125f; w = sidebar ? 0.5f : 1.125f; s = sidebar ? 0.6f : 1.3f; }
    else { b = 0.4f; w = 1.03f; s = 1.2f; f[0] = f[1] = f[2] = 1; f[3] = 0.2f; }
    if (regLike && slid) {   // RegularDiffusionAmount on the face fill: toward (tint, 0) as a -> 0, (tint, 0.5) as a -> 1
        float t = dark ? b : 1;
        float k = a < 0.5f ? clampf(2 * a, 0, 1) : clampf(2 * (a - 0.5f), 0, 1);
        float from[4] = {t, t, t, 0}, to[4] = {t, t, t, 0.5f};
        for (int i = 0; i < 4; i++) f[i] = a < 0.5f ? from[i] + (f[i] - from[i]) * k : f[i] + (to[i] - f[i]) * k;
    }
    if (inact && menu) {
        b = dark ? 0.15f : 0.8f; w = dark ? 0.3f : 0.96f;
        if (dark) f[0] = f[1] = f[2] = f[3] = 0; else { f[0] = f[1] = f[2] = 0.96f; f[3] = 0.04f; }
    } else if (inact) { if (dark) b = 0.08f; else w = 0.96f; }
    p.faceBlack = b; p.faceWhite = w; p.faceSat = s;
    for (int i = 0; i < 4; i++) p.faceFill[i] = f[i];

    if (sidebar) { p.bleedBlack = dark ? 0.1f : 0.75f; p.bleedWhite = dark ? 0.5f : 0.9f; p.bleedSat = 1.5f; }
    else if (dark) { p.bleedBlack = 0.125f; p.bleedWhite = 0.5f; p.bleedSat = 1; }
    else { p.bleedBlack = 0.9f; p.bleedWhite = 1; p.bleedSat = 1.2f; }
    p.bleedAmount = p.bleedHeight = 0.35f * x;
    p.bleedOpacity = (clearFam || inact) ? 0 : lin(x, 64, 160, 0, dark ? 0.8f : 0.5f);
    p.shadowOpacity = (regLike && !inact) ? lin(x, 64, 160, 0.04f, dark ? 0.6f : 0.4f) : 0;
    p.shadowRadius = lin(x, 64, 160, 4, 24);
    return p;
}

int32_t gg_recipe_encode(int recipe, bool inactive, bool dark, int32_t flag, float a) {
    float c = isnan(a) ? 0.5f : clampf(a, 0, 1);
    int32_t q = (int32_t)lroundf(c * 78);
    int32_t n = (((recipe & 15) * 2 + (inactive ? 1 : 0)) * 2 + (flag & 1)) * 79 + q;
    int32_t e = 11 + n / 1024, k = n % 1024;
    int32_t m = (1 << e) + k * (1 << (e - 10));
    return dark ? -m : m;
}

bool gg_recipe_decode(int32_t p, int *recipe, bool *inactive, bool *dark, int32_t *flag, float *a) {
    int32_t m = abs(p);
    if (m < 2048 || m > 65504) return false;
    int32_t e = 31 - __builtin_clz((unsigned)m), step = 1 << (e - 10), rem = m - (1 << e);
    if (rem % step) return false;
    int32_t n = (e - 11) * 1024 + rem / step, q = n % 79, rest = n / 79;
    if (rest >= 64) return false;
    if (recipe) *recipe = rest >> 2;
    if (inactive) *inactive = (rest >> 1) & 1;
    if (flag) *flag = rest & 1;
    if (dark) *dark = p < 0;
    if (a) *a = q / 78.0f;
    return true;
}

// Same table as kSigs26 (glass26_replica.metal): black, white, sat, fill, recipe (-1 adaptive, -2 keep 26.6), dark, inactive.
static const struct { double b, w, s, f[4]; int r; bool d, i; } kSigs[] = {
    {0.5, 0.95, 1.0, {1, 1, 1, 0.35}, 0, 0, 1},           {0.2, 0.6, 1.0, {0, 0, 0, 0.35}, 0, 1, 1},
    {0.2, 0.95, 1.0, {1, 1, 1, 0.1}, 1, 0, 0},            {0.05, 0.8, 1.0, {1, 1, 1, 0.05}, 1, 1, 0},
    {0.5, 1.03, 1.0, {1, 1, 1, 0.4}, 0, 0, 0},            {0.8, 0.97, 1.0, {1, 1, 1, 0.25}, -1, 0, 0},
    {0.75, 0.97, 1.1, {0, 0, 0, 0}, -1, 0, 0},            {0.5, 1.0, 1.0, {0, 0, 0, 0}, -1, 0, 0},
    {0.2, 0.6, 1.0, {0, 0, 0, 0.4}, 0, 1, 0},             {0.15, 0.9, 1.05, {1, 1, 1, 0.1}, 4, 0, 0},
    {0.075, 0.9, 1.06, {0, 0, 0, 0.1}, 4, 1, 0},          {0.8, 0.96, 1.0, {0.96, 0.96, 0.96, 0.04}, 3, 0, 1},
    {0.15, 0.3, 1.0, {0, 0, 0, 0}, 3, 1, 1},              {0.075, 1.15, 1.06, {0, 0, 0, 0}, 1, 0, 0},
    {0.125, 0.8, 1.3, {0, 0, 0, 0}, 5, 0, 0},             {0.16, 1.05, 1.3, {0, 0, 0, 0}, -2, 0, 0},
    {0.2, 1.1, 1.6, {0, 0, 0, 0}, -2, 0, 0},              {0.4, 1.03, 1.2, {1, 1, 1, 0.2}, 2, 0, 0},
    {0.1, 0.5, 0.6, {0, 0, 0, 0}, 2, 1, 0},
};

// 26.6 faces in NotificationCenter (measured with a test app, key window): ChicletRecipe widgets on the !P branch and
// notification cards (26.6 regular active), including subdued (0x195e79e30) and inactive widgets (legacy).
// Boost+subdued light 0.93 = 1.0 - 0.07 [I].
static const struct { double b, w, s, f[4]; int r; bool d, i, sub, boost; } kNC[] = {
    {0.12, 0.8, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 0, 0},     {0.05, 0.3, 0.8, {0, 0, 0, 0}, GG_R_CHICLET, 1, 0, 0, 0},
    {0.12, 1.0, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 0, 1},     {0.12, 0.73, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 1, 0},
    {0.0, 0.3, 0.8, {0, 0, 0, 0}, GG_R_CHICLET, 1, 0, 1, 0},      {0.12, 0.93, 1.2, {0, 0, 0, 0}, GG_R_CHICLET, 0, 0, 1, 1},
    {0.2, 0.95, 1, {1, 1, 1, 0.1}, GG_R_CHICLET, 0, 1, 0, 0},     {0.05, 0.8, 1, {1, 1, 1, 0.05}, GG_R_CHICLET, 1, 1, 0, 0},
    {0.2, 0.88, 1, {1, 1, 1, 0.1}, GG_R_CHICLET, 0, 1, 1, 0},     {0.0, 0.8, 1, {1, 1, 1, 0.05}, GG_R_CHICLET, 1, 1, 1, 0},
    {0.5, 1.03, 1, {1, 1, 1, 0.4}, GG_R_NOTIF, 0, 0, 0, 0},       {0.2, 0.6, 1, {0, 0, 0, 0.4}, GG_R_NOTIF, 1, 0, 0, 0},
    {0.5, 0.96, 1, {1, 1, 1, 0.4}, GG_R_NOTIF, 0, 0, 1, 0},       {0.15, 0.6, 1, {0, 0, 0, 0.4}, GG_R_NOTIF, 1, 0, 1, 0},
};

static bool ggFaceIs(double black, double white, double sat, const double fill[4], double b, double w, double s, const double f[4]) {
    const double tol = 2e-3;
    if (fabs(black - b) > tol || fabs(white - w) > tol || fabs(sat - s) > tol || fabs(fill[3] - f[3]) > tol) return false;
    for (int c = 0; c < 3; c++) if (fabs(fill[c] * fill[3] - f[c] * f[3]) > tol) return false;
    return true;
}

int gg_face_nc(double black, double white, double sat, const double fill[4], bool *dark, bool *inactive, bool *subdued, bool *boost) {
    for (unsigned i = 0; i < sizeof kNC / sizeof kNC[0]; i++) {
        if (!ggFaceIs(black, white, sat, fill, kNC[i].b, kNC[i].w, kNC[i].s, kNC[i].f)) continue;
        if (dark) *dark = kNC[i].d;
        if (inactive) *inactive = kNC[i].i;
        if (subdued) *subdued = kNC[i].sub;
        if (boost) *boost = kNC[i].boost;
        return kNC[i].r;
    }
    return -1;
}

int gg_face_recipe(double black, double white, double sat, const double fill[4], bool *dark, bool *inactive) {
    const double tol = 2e-3;
    for (unsigned i = 0; i < sizeof kSigs / sizeof kSigs[0]; i++) {
        if (fabs(black - kSigs[i].b) > tol || fabs(white - kSigs[i].w) > tol || fabs(sat - kSigs[i].s) > tol) continue;
        if (fabs(fill[3] - kSigs[i].f[3]) > tol) continue;
        bool same = true;
        for (int c = 0; c < 3; c++) if (fabs(fill[c] * fill[3] - kSigs[i].f[c] * kSigs[i].f[3]) > tol) same = false;
        if (!same) continue;
        if (kSigs[i].r >= 0) { if (dark) *dark = kSigs[i].d; if (inactive) *inactive = kSigs[i].i; }
        return kSigs[i].r;
    }
    // 26.6 show/hide animation frames (like the shader's interp_sig26): face = mix(original face, recipe face, t), i.e. black = t B,
    // white = 1 + t (W - 1), sat = 1 + t (S - 1) (including the original face 0/1/1 itself at t = 0). Keep 26.6 (-2) so the
    // shader interpolates toward the target recipe; treating it as adaptive glass would make the app write the full 27 regular
    // recipe onto a cell that just started appearing (an opaque white hollow cell for a few frames). Fill is only checked not
    // to exceed the recipe fill (how 26.6 interpolates the fill color is not measured).
    for (unsigned i = 0; i < sizeof kSigs / sizeof kSigs[0]; i++) {
        double t = black / kSigs[i].b;
        if (t < -tol || t > 1 - 1e-3) continue;
        if (fabs(white - (1 + t * (kSigs[i].w - 1))) > tol || fabs(sat - (1 + t * (kSigs[i].s - 1))) > tol) continue;
        if (fill[3] > kSigs[i].f[3] + tol) continue;
        return -2;
    }
    return -1;
}
