// Glass 27 recipes computed in-app (CA level, like DesignLibrary 27 applying Parameters to the glassBackground filter) and
// recipe codes that carry the 27-only parameter groups to the GGGlass shader through inputClampPreserveHue.
// Plain C (no Foundation) so it is shared by GGLegibility and the tests.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Recipe numbers match the shader's kVariant (0..5); 6 is CartouchePopoverRecipe (popover with an arrow); 7 ChicletRecipe
/// (widget), 8 NotificationCenterRecipe (notification card). For 7 and 8 the inactive bit of the code means subdued: these two
/// recipes have no Spec level inactive, and for inactive widgets the app writes the legacy values directly.
enum { GG_R_REGULAR = 0, GG_R_CLEAR = 1, GG_R_SIDEBAR = 2, GG_R_MENU = 3, GG_R_DOCK = 4, GG_R_CC = 5, GG_R_POPOVER = 6,
       GG_R_CHICLET = 7, GG_R_NOTIF = 8 };

/// CA level values of the keys shared by 26.6/27 (QuartzCore converts them to uniforms). Heights are clamped >= 1e-6.
typedef struct {
    float faceBlack, faceWhite, faceSat, faceFill[4];          // inputFaceColorMatrix{Black,White,Saturation,FillColor}
    float bleedBlack, bleedWhite, bleedSat;                    // inputBleedColorMatrix{Black,White,Saturation}
    float blurRadius, blurOpacity[4], blurDistance[4];         // inputBlurRadius, inputBlurOpacity0..3, inputBlurDistance0..3
    float innerAmount, innerHeight, outerAmount, outerHeight;  // inputInner/OuterRefraction{Amount,Height}
    float refractionOpacity;                                   // inputRefractionOpacity
    float bleedAmount, bleedHeight, bleedOpacity;              // inputBleed{Amount,Height,Opacity}
    float shadowOpacity, shadowRadius;                         // inputShadow{Opacity,Radius}
    float shadowVibrancy;                                      // inputShadowVibrancyContribution (written only when > 0)
} GG27Params;

/// 27 glass recipe: dark = dark appearance, inactive = inactive window, a = slider (0..1, 0.5 neutral),
/// x = glass short side (points, Environment.dimensions). Inactive only changes the Spec level for regular and menu; popover
/// inactive only changes the Parameters level (27-only group, handled by the shader).
GG27Params gg27_recipe_params(int recipe, bool dark, bool inactive, float a, float x);
/// Subdued (ApplyLegacySubvariant -> 0x195e79e30, CA level part): blur x2, refraction opacity x0.7, edge bleed opacity x0.5,
/// shadow opacity/radius x0.6, light white -0.07, dark black -0.05 (highlight x0.4 is handled by the shader).
void gg27_subdued(GG27Params *p, bool dark);
/// backdropScale resolutionAdequacy(2.0, [0.25, 0.5]) (BackdropScaleResolutionEstimator 0x195e9fd78): first bucket with
/// pixelLength / scale <= 2 blur / ((1 - faceFill)(1 - blurFill)); last bucket if none qualifies; first bucket if invisible.
float gg27_backdrop_scale(float blurRadius, float faceFillOpacity, float blurFillOpacity, float pixelLength);
/// 26.6 glass face in NotificationCenter: GG_R_CHICLET (widget), GG_R_NOTIF (card, "x" button), -1 no match.
/// inactive: legacy style widget (inactive window); boost: white 1.0 (boostWhitePoint or tinted, light appearance).
int gg_face_nc(double black, double white, double sat, const double fill[4], bool *dark, bool *inactive, bool *subdued, bool *boost);

/// Recipe code: q = round(a 78), n = ((recipe 2 + inactive) 2 + flag) 79 + q, value = the n-th integer exactly
/// representable as a half from 2048 (2048..65504), negative when dark. |P| < 2048 is an old code (Legibility.h).
int32_t gg_recipe_encode(int recipe, bool inactive, bool dark, int32_t flag, float a);
/// Decodes; false when |p| < 2048 or not a valid code.
bool gg_recipe_decode(int32_t p, int *recipe, bool *inactive, bool *dark, int32_t *flag, float *a);

/// Recipe from the 26.6 face read from the filter (same table as the shader's kSigs26, tolerance 2e-3 on black/white/sat and
/// premultiplied fill). Returns recipe >= 0 and writes dark/inactive; -1 adaptive glass or unknown face; -2 keep 26.6.
int gg_face_recipe(double black, double white, double sat, const double fill[4], bool *dark, bool *inactive);

#ifdef __OBJC__
@class CALayer;
/// Recipe.m (GGLegibility): writes the 27 recipe and code into glass filter `f` about to be set on layer `l` (in setFilters:).
/// false: nothing written (off, ABI not 2, no bounds yet, unknown kind): the caller writes the old code.
bool gg_recipe_apply(id f, CALayer *l, float a);
/// Rewrites every glass filter of `l` through key paths using the remembered identity (slider, window, bounds change).
/// false: none.
bool gg_recipe_recode(CALayer *l, float a);
/// NotificationCenter: makes the widget excludingPlatter layer transparent (vibrantColorMatrix YCC on the !P branch, which
/// 27 does not build). true when f was changed.
bool gg_recipe_foreground(id f);
/// Hooks CABackdropLayer setBounds: and listens for window notifications (only when enabled and ABI = 2).
void gg_recipe_install(void);
#endif

#ifdef __cplusplus
}
#endif
