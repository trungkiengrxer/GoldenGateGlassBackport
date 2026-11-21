// QuartzCore glass shaders transcribed by hand from AIR (llvm-dis), used by the harness and by GGGlass:
//
// 1. replica_glass_background_sdf_lpf : macOS 26.6 (25G72) glass_background_sdf_lpf, 26 ABI:
//    buffer(1) = GlassBackgroundUniformsSdf (320 bytes), buffer(6) = edr_scale, texture(3) = source_texture.
//    Bit-exact with the original shader (compare.swift, 60/60 cases).
// 2. r27_glass_background_sdf_all_lpf : macOS 27.2.1 (26B131) glass_background_sdf_all_lpf, 27 ABI:
//    buffer(1) = GlassBackgroundUniformsSdf27 (368 bytes), buffer(9) = GlassBackgroundUniformsExt (28 bytes).
//    Cannot be pixel-compared with the original: 26.6's Metal rejects AIR v29 (MSL 4.1).
// 3. gg27_glass_background_sdf_lpf : the 27 algorithm (item 2) behind an adapter taking the 26 ABI, so that
//    WindowServer 26 can use it. 27-only parameters come from function constants.
#include <metal_stdlib>
using namespace metal;

struct GlassBackgroundUniforms {        // 272 bytes, order and offsets per air.struct_type_info
    float4 displacement_mat;            //   0
    float  inner_refraction_amount;     //  16
    float  inner_refraction_inv_height; //  20
    float  outer_refraction_amount;     //  24
    float  outer_refraction_inv_height; //  28
    float  refraction_threshold0;       //  32
    float  refraction_threshold1;       //  36
    float  blur_radius;                 //  40
    float  edge_bleed_blur_radius;      //  44
    float  edge_bleed_amount;           //  48
    float  edge_bleed_inv_height;       //  52
    float  shadow_amount;               //  56
    float  shadow_inv_height;           //  60
    float2 shadow_offset;               //  64
    float  shadow_blur_radius;          //  72
    float  shadow_inv_radius;           //  76
    half4  face_cm0, face_cm1, face_cm2;         //  80
    half4  bleed_cm0, bleed_cm1, bleed_cm2;      // 104
    half4  shadow_cm0, shadow_cm1, shadow_cm2;   // 128
    float  shadow_contribution;         // 152
    float  shadow_face_opacity;         // 156
    float  blur_alpha0, blur_alpha1, blur_alpha2, blur_alpha3;  // 160
    float  blur_dist0, blur_dist1, blur_dist2, blur_dist3;      // 176
    float  edge_bleed_dist0, edge_bleed_dist1;                  // 192
    float  edge_bleed_opacity;          // 200
    float  face_opacity;                // 204
    float2 bleed_darken;                // 208
    float  shadow_dist_offset;          // 216
    float  shadow_opacity;              // 220
    float  refraction_opacity;          // 224
    float  holding_tone_opacity;        // 228
    float  sdr_shadow_dist0;            // 232
    float  sdr_shadow_dist1;            // 236
    float  clamp_limit;                 // 240
    float  preserve_hue;                // 244
    float  sdr_white_value;             // 248
    float  x86_workaround;              // 252 (only read by the _lph variant)
    float  complex_refraction;          // 256
};

// Per-glass 27 slider amount: the app writes inputClampPreserveHue = P = 2 + 2 round(a 1000) + the original preserve
// flag, and QuartzCore passes it unchanged into preserve_hue. P < 2 is Apple's original value (0/1). A negative code
// P <= -2 also carries the glass appearance (ggapp, from the view's effectiveAppearance, as in 27 where each glass has
// its own appearance): -P = 2 + 4 round(a 500) + 2 dark + flag (at most 2005: the _lph half is still exact per integer).
// App recipe code (|P| >= 2048): the app computes the 27 recipe and writes the real values into the shared keys; the code
// carries the 27-only part. n = index of |P| among half-precision integers from 2048 (exact in both _lpf and _lph),
// n = ((recipe 2 + inactive) 2 + flag) 79 + q, a = q / 78; negative when dark.
static bool gg_app_code(float p, thread int& recipe, thread bool& inactive, thread float& flag, thread float& a) {
    float m = fabs(p);
    if (!(m >= 2048) || m > 65504) return false;
    ushort b = as_type<ushort>(half(m));
    int n = (int(b >> 10) - 26) * 1024 + int(b & 1023), q = n % 79, rest = n / 79;
    if (rest >= 64) return false;
    recipe = rest >> 2; inactive = ((rest >> 1) & 1) != 0; flag = float(rest & 1); a = float(q) / 78;
    return true;
}
static bool gg_app_code(float p) { int r; bool i; float f, a; return gg_app_code(p, r, i, f, a); }
static bool gg_decode_tint(float p, thread float& a, thread float& flag) {
    { int r; bool i; if (gg_app_code(p, r, i, flag, a)) return true; }
    if (p <= -2) {
        float m = -p - 2, k = floor(m / 4), r = m - 4 * k;
        a = k / 500; flag = r - 2 * floor(r / 2);
        return true;
    }
    if (!(p >= 2)) return false;
    float k = floor((p - 2) / 2);
    a = k / 1000; flag = p - 2 - 2 * k;
    return true;
}
/// Appearance carried by the code: 1 dark, 0 light, -1 none (positive code, Apple value).
static int gg_code_dark(float p) {
    if (gg_app_code(p)) return p < 0 ? 1 : 0;
    if (!(p <= -2)) return -1;
    float m = -p - 2;
    return int(floor((m - 4 * floor(m / 4)) / 2));
}
static bool gg_preserve(float p) { float a, f; return gg_decode_tint(p, a, f) ? f > 0.5 : p > 0; }
/// Folds the fallback slider amount (live >= 0) into preserve_hue of glass that carries no code yet.
static float gg_fold_tint(float p, float live) {
    if (live < 0 || p >= 2 || p <= -2) return p;
    return 2 + 2 * rint(clamp(live, 0.0, 1.0) * 1000) + (p > 0 ? 1 : 0);
}

struct SdfFragmentUniforms { float4 arg, tr, arg2; };   // 48 bytes

struct GlassBackgroundUniformsSdf {     // 320 bytes
    SdfFragmentUniforms sdf;
    GlassBackgroundUniforms glass;
};

struct VIn  { float4 position [[attribute(0)]]; float2 sdf_uv [[attribute(1)]]; float2 src_uv [[attribute(2)]]; };
struct VOut { float4 position [[position]]; float2 sdf_uv; float2 src_uv; };

// Harness vertex shader, same interface as sdf_filter_vert_lpf (mvp = identity).
vertex VOut harness_vert(VIn in [[stage_in]]) { return { in.position, in.sdf_uv, in.src_uv }; }

// Vertex for Apple's variable_blur_downsample_frag_lpf (fragment input named texcoord0).
struct BlurVIn  { float4 position [[attribute(0)]]; float2 texcoord0 [[attribute(1)]]; };
struct BlurVOut { float4 position [[position]]; float2 texcoord0; };
vertex BlurVOut harness_blur_vert(BlurVIn in [[stage_in]]) { return { in.position, in.texcoord0 }; }

#define K(bits) as_type<float>(bits)
constexpr sampler kSmp(filter::linear, mip_filter::linear, address::clamp_to_edge);

// CA::OGL::Metal::ShaderUtils<float>::supercircle_sdf (identical in 26.6 and 27.2)
static float3 supercircle_sdf(float2 p, float2 b, float radius, float2 k) {
    float ar = fabs(radius);
    float r6 = ar * K(0x3FC3AB4Bu);
    float m  = mix(r6, ar, fmax(k.x, k.y));
    float2 d = p - b;
    float2 q = float2(m) + d;
    float2 at = fabs(fmax(float2(0), (d + r6) / r6));
    float len = sqrt(dot(at, at));
    float mx = fmax(at.x, at.y), mn = fmin(at.x, at.y);
    float s = mx == 0 ? 0 : saturate(mn / mx);
    float poly = (((K(0x4049FC11u) - s * K(0x3F6D11E0u)) * s + K(0xC06909C0u)) * s + K(0x3FA24ECFu)) * s + K(0x3E897CE5u);
    float v = (len + 1) + (-1 / (1 - (s * s) * saturate(len) * poly));
    float2 w = fmax(float2(0), at * K(0x3FC3AB4Bu) + K(0xBF075697u));
    float u2 = sqrt(dot(w, w)) * K(0x3F277765u) + K(0x3EB11136u);
    float v1 = mix(v, u2, k.x), v2 = mix(v, u2, k.y);
    float sg = at.y > at.x ? 1.0 : -1.0;
    float f = mix(v1, v2, saturate(0.5 - sg + sg * s)) - 1;
    half fh = half(f);
    float2 qq = fmax(float2(0), q);
    float2 nq = qq * rsqrt(dot(qq, qq));
    float2 ax = q.x > q.y ? float2(1, 0) : float2(0, 1);
    float dd = fmin(fmax(q.x, q.y), 0.0) + r6 * float(fh);
    return float3(dd, (nq.x + nq.y > 0) ? nq : ax);
}

// The functions below take uniforms by value (not constant references) so the _lph entries can share them:
// those entries convert 26.6's half uniforms into a float struct in thread memory and call the same body.
static float4 finish_sdf(float dist, float2 n1, float2 p, SdfFragmentUniforms s) {
    float2 e  = float2(p.x, s.arg.x * p.y / s.arg.y);
    float2 n2 = e * rsqrt(dot(e, e));
    float2 n  = mix(n1, n2, float2(s.arg.w));
    n *= rsqrt(dot(n, n));
    return float4(dist, n.x * s.tr.x + n.y * s.tr.y, n.x * s.tr.z + n.y * s.tr.w, 1);
}

// compute_sdf_with_mode (identical in 26.6 and 27.2)
static float4 compute_sdf_with_mode(float2 p, int mode, SdfFragmentUniforms s) {
    float2 sgn = float2(p.x >= 0 ? 1.0 : -1.0, p.y >= 0 ? 1.0 : -1.0);
    if (mode < 4) {
        float2 q = fabs(p) - s.arg.xy;
        float2 axis = q.x > q.y ? float2(1, 0) : float2(0, 1);
        return finish_sdf(fmax(q.x, q.y), axis * sgn, p, s);
    }
    if (mode == 4) {
        float3 r = supercircle_sdf(fabs(p), s.arg.xy, s.arg2.z, s.arg2.xy);
        return finish_sdf(r.x, r.yz * sgn, p, s);
    }
    float4 a2 = s.arg2;
    float4 h = (a2.xxwy + a2.ywzz) * 0.5;
    float4 k = saturate((K(0xBFC3AB4Bu) - s.arg.xyxy / h) * K(0xBFF21E8Cu));
    k = select(float4(1), k, h < 0);
    float3 r = supercircle_sdf(p, s.arg.xy, a2.y, k.xw);
    float3 c = supercircle_sdf(float2(-p.x, p.y), s.arg.xy, a2.x, k.xy);
    if (c.x > r.x) r = float3(c.x, -c.y, c.z);
    c = supercircle_sdf(float2(p.x, -p.y), s.arg.xy, a2.z, k.zw);
    if (c.x > r.x) r = float3(c.x, c.y, -c.z);
    c = supercircle_sdf(-p, s.arg.xy, a2.w, k.zy);
    if (c.x > r.x) r = float3(c.x, -c.y, -c.z);
    return finish_sdf(r.x, r.yz, p, s);
}

static float lens(float amount, float inv_height, float d) {   // amount * (1 - sqrt((2-t)t))
    float t = saturate(inv_height * -d);
    return amount - saturate(sqrt((2 - t) * t)) * amount;
}
static float blur_lod(float r) { return fmax(0.0, log2(r < 2 ? r * 0.5 + 1 : r)); }
static float3 clean(float3 c) { return select(c, float3(0), fabs(c) < 1e-6); }
static float3 grade(float3 c, half4 r0, half4 r1, half4 r2) {
    return float3(dot(c, float3(r0.xyz)), dot(c, float3(r1.xyz)), dot(c, float3(r2.xyz)))
         + float3(float(r0.w), float(r1.w), float(r2.w));
}
static float ramp_radius(float d, float4 lo4, float4 alpha, float blur_radius) {   // lo4 = blur_dist0..3
    float3 lo = lo4.xyz, hi = lo4.yzw;
    float3 r = saturate(fma(float3(d), 1 / (hi - lo), -lo / (hi - lo)));
    float3 a = alpha.yzw * r;
    return (alpha.x - (a.x + a.y + a.z)) * blur_radius;
}
static float ramp_radius(float d, GlassBackgroundUniforms u) {
    return ramp_radius(d, float4(u.blur_dist0, u.blur_dist1, u.blur_dist2, u.blur_dist3),
                       float4(u.blur_alpha0, u.blur_alpha1, u.blur_alpha2, u.blur_alpha3), u.blur_radius);
}
// Apple's polynomial approximation of 0.5*erfc, computed in half: x clamped to [-2, 2].
static half apple_poly_h(float x) {
    half v = saturate(half(x) * 0.25h + 0.5h) * 4.0h - 2.0h;
    half v2 = v * v;
    half p = fma(fma(fma(0.002954h, v2, -0.034454h), v2, 0.168213h), v2, -0.560547h);
    return fma(p, v, 0.5h);
}

// =====================================================================================
// 1. macOS 26.6 glass_background_base<true> (bleed = false for the _no_bleed variants)
// =====================================================================================
static float4 glass_background_base(float2 src_uv, float2 shadow, float dist, float2 grad, float cover,
                                    texture2d<float> tex, GlassBackgroundUniforms u, float edr,
                                    bool bleed = true) {
    float2 disp = float2(dot(grad, u.displacement_mat.xy), dot(grad, u.displacement_mat.zw));

    // Shadow (drawn first, the face covers it with a mix by cover)
    float4 shadowCol = 0;
    if (cover < 1) {
        float smag = lens(u.shadow_amount, u.shadow_inv_height, u.shadow_dist_offset + dist);
        float2 suv = smag * disp + src_uv;
        half x = saturate(half(u.shadow_inv_radius * shadow.x) * 0.25h + 0.5h) * 4.0h - 2.0h;
        half x2 = x * x;
        half p = fma(fma(fma(0.002954h, x2, -0.034454h), x2, 0.168213h), x2, -0.560547h);
        p = fma(p, x, 0.5h);
        float smask = u.shadow_opacity * shadow.y * float(p);
        if (smask < 1e-6 && cover == 0) discard_fragment();
        float4 sc;
        if (u.shadow_contribution > 1e-6) {
            float4 s = tex.sample(kSmp, suv, level(blur_lod(u.shadow_blur_radius)));
            float3 c = clean(s.rgb / fmax(s.a, 1e-6));
            float3 g = float3(dot(c, float3(u.shadow_cm0.xyz)), dot(c, float3(u.shadow_cm1.xyz)), dot(c, float3(u.shadow_cm2.xyz)));
            sc = float4(g * u.shadow_contribution + float3(float(u.shadow_cm0.w), float(u.shadow_cm1.w), float(u.shadow_cm2.w)),
                        mix(u.shadow_face_opacity, 1.0, u.shadow_contribution));
        } else {
            sc = float4(float(u.shadow_cm0.w), float(u.shadow_cm1.w), float(u.shadow_cm2.w), u.shadow_face_opacity);
        }
        shadowCol = sc * smask;
    }

    // Face: refraction + blur ramp, color matrix, edge bleed
    float4 face = 0;
    if (cover > 0) {
        float4 col;
        if (bool(u.complex_refraction)) {
            float imag = lens(u.inner_refraction_amount, u.inner_refraction_inv_height, dist);
            float4 s = tex.sample(kSmp, imag * disp + src_uv, level(blur_lod(ramp_radius(imag + dist, u))));
            col = float4(clean(s.rgb), s.a);
            if (u.refraction_opacity > 0) {
                float omag = lens(u.outer_refraction_amount, u.outer_refraction_inv_height, dist);
                float4 o = tex.sample(kSmp, omag * disp + src_uv, level(blur_lod(ramp_radius(omag + dist, u))));
                float span = u.refraction_threshold1 - u.refraction_threshold0;
                float t = saturate(fma(dist, 1 / span, -u.refraction_threshold0 / span)) * u.refraction_opacity;
                col = mix(col, float4(clean(o.rgb), o.a), t);
            }
        } else {
            float4 s = tex.sample(kSmp, src_uv, level(blur_lod(u.blur_radius)));
            col = float4(clean(s.rgb), s.a);
        }
        float3 c = col.rgb / fmax(col.a, 1e-6);
        float3 f = u.face_opacity > 0 ? mix(c, grade(c, u.face_cm0, u.face_cm1, u.face_cm2), u.face_opacity) : c;
        if (!bleed) { face = float4(f, 1); } else {

        float bmag = lens(u.edge_bleed_amount, u.edge_bleed_inv_height, dist);
        float4 b = tex.sample(kSmp, bmag * disp + src_uv, level(blur_lod(u.edge_bleed_blur_radius)));
        float3 bg = grade(clean(b.rgb / fmax(b.a, 1e-6)), u.bleed_cm0, u.bleed_cm1, u.bleed_cm2);
        float bspan = u.edge_bleed_dist1 - u.edge_bleed_dist0;
        float bt = saturate(fma(dist, 1 / bspan, -u.edge_bleed_dist0 / bspan));
        float L = saturate(dot(f, float3(K(0x3E59999Au), K(0x3F372474u), K(0x3D93A92Au))));
        float k = u.bleed_darken.x * L + u.bleed_darken.y;
        k = k * k * bt;
        k = k * k * u.edge_bleed_opacity;
        face = float4(mix(f, bg, k), 1);
        }
    }

    float4 o = mix(shadowCol, face, cover);

    // SDR holding tone
    if (u.holding_tone_opacity > 0) {
        float w = u.sdr_shadow_dist0 > dist ? 1.0
                : (u.sdr_shadow_dist1 > dist ? mix(1.0, 0.0, (dist - u.sdr_shadow_dist0) / (u.sdr_shadow_dist1 - u.sdr_shadow_dist0)) : 0.0);
        float sa = saturate(o.a);
        float4 h = float4(u.sdr_white_value * o.rgb * sa / fmax(o.a, 1e-6), sa);
        o = mix(o, h, w * u.holding_tone_opacity);
    }

    // Clamp EDR
    if (u.clamp_limit > 0) {
        float3 c = o.rgb / fmax(o.a, 1e-6);
        if (gg_preserve(u.preserve_hue)) {
            float m = fmax(fmax(c.x, c.y), c.z);
            if (m > u.clamp_limit) c *= u.clamp_limit / m;
        } else {
            c = clamp(c, float3(-0.75), float3(u.clamp_limit));
        }
        o.rgb = c * o.a;
    }
    o.rgb *= edr;
    return o;
}

// Shared body of glass_background_sdf_lpf and glass_background_sdf_no_bleed_lpf (26.6).
static float4 replica_sdf(VOut in, texture2d<float> source_texture, GlassBackgroundUniformsSdf u,
                          float edr_scale, bool bleed) {
    int mode = int(u.sdf.arg.z);
    float cover = 0, dist = 0;
    float2 grad = 0;
    if (mode > -1) {
        float4 s = compute_sdf_with_mode(in.sdf_uv, mode, u.sdf);
        dist = s.x; grad = s.yz;
        cover = saturate(0.5 - s.x / fmax(fwidth(s.x), K(0x38D1B717u))) * s.w;
    }
    float2 shadow = 0;
    if (cover < 1) {
        float4 s = compute_sdf_with_mode(u.glass.shadow_offset + in.sdf_uv, abs(mode) | 4, u.sdf);
        shadow = s.xw;
    }
    return glass_background_base(in.src_uv, shadow, dist, grad, cover, source_texture, u.glass, edr_scale, bleed);
}

fragment float4 replica_glass_background_sdf_lpf(VOut in [[stage_in]],
                                                 texture2d<float> source_texture [[texture(3)]],
                                                 constant GlassBackgroundUniformsSdf& u [[buffer(1)]],
                                                 constant float& edr_scale [[buffer(6)]]) {
    return replica_sdf(in, source_texture, u, edr_scale, true);
}

fragment float4 replica_glass_background_sdf_no_bleed_lpf(VOut in [[stage_in]],
                                                          texture2d<float> source_texture [[texture(3)]],
                                                          constant GlassBackgroundUniformsSdf& u [[buffer(1)]],
                                                          constant float& edr_scale [[buffer(6)]]) {
    return replica_sdf(in, source_texture, u, edr_scale, false);
}

// Texture SDF variant (AIR 26.6 m062 glass_background_lpf, m063 no_bleed): reads (distance, gradient, coverage)
// from sdf_texture at texcoord1, the shadow at texcoord1 + shadow_offset (uv units), then calls the same glass_background_base.
// Sampler __air_sampler_state.1 = 0x7bff0000082a49: like kSmp but with nearest mip.
constexpr sampler kSdfSmp(filter::linear, mip_filter::nearest, address::clamp_to_edge);
struct TexVOut { float4 position [[position]]; float2 texcoord0; float2 texcoord1; };
// Harness vertex for the texture variant: texcoord0 = source uv (attribute 2), texcoord1 = sdf_texture uv (attribute 1).
vertex TexVOut harness_tex_vert(VIn in [[stage_in]]) { return { in.position, in.src_uv, in.sdf_uv }; }

static float4 replica_tex(TexVOut in, texture2d<float> src, texture2d<float> sdft, GlassBackgroundUniforms u,
                          float edr_scale, bool bleed) {
    float4 s = sdft.sample(kSdfSmp, in.texcoord1);
    float cover = saturate(0.5 - s.x / fmax(fwidth(s.x), K(0x38D1B717u))) * s.w;
    float2 shadow = 0;
    if (cover < 1) shadow = sdft.sample(kSdfSmp, u.shadow_offset + in.texcoord1).xw;
    return glass_background_base(in.texcoord0, shadow, s.x, s.yz, cover, src, u, edr_scale, bleed);
}

fragment float4 replica_glass_background_lpf(TexVOut in [[stage_in]],
                                             texture2d<float> source_texture [[texture(3)]],
                                             texture2d<float> sdf_texture [[texture(4)]],
                                             constant GlassBackgroundUniforms& u [[buffer(1)]],
                                             constant float& edr_scale [[buffer(6)]]) {
    return replica_tex(in, source_texture, sdf_texture, u, edr_scale, true);
}

fragment float4 replica_glass_background_no_bleed_lpf(TexVOut in [[stage_in]],
                                                      texture2d<float> source_texture [[texture(3)]],
                                                      texture2d<float> sdf_texture [[texture(4)]],
                                                      constant GlassBackgroundUniforms& u [[buffer(1)]],
                                                      constant float& edr_scale [[buffer(6)]]) {
    return replica_tex(in, source_texture, sdf_texture, u, edr_scale, false);
}

// =====================================================================================
// 2. macOS 27.2.1 glass_background_sdf_all_lpf (glass_background_base<true,true,true>)
// =====================================================================================
struct GlassBackgroundUniforms27 {      // 320 bytes; 0..231 same as 26 except the noted differences
    float4 displacement_mat;
    float  inner_refraction_amount, inner_refraction_inv_height;
    float  outer_refraction_amount, outer_refraction_inv_height;
    float  refraction_threshold0, refraction_threshold1;
    float  blur_radius, edge_bleed_blur_radius, edge_bleed_amount, edge_bleed_inv_height;
    float  shadow_amount, shadow_inv_height;
    float2 shadow_offset;
    float  shadow_blur_radius, shadow_inv_radius;
    half4  face_cm0, face_cm1, face_cm2;
    half4  bleed_cm0, bleed_cm1, bleed_cm2;
    half4  shadow_cm0, shadow_cm1, shadow_cm2;
    float  shadow_contribution, shadow_face_opacity;
    float  blur_alpha0, blur_alpha1, blur_alpha2, blur_alpha3;
    float  blur_dist0, blur_dist1, blur_dist2, blur_dist3;
    float  edge_bleed_dist0, edge_bleed_dist1, edge_bleed_opacity, face_opacity;
    float2 bleed_darken;
    float  shadow_dist_offset, shadow_opacity, refraction_opacity, holding_tone_opacity;
    float  sdr_shadow_dist0;            // 232
    float  sdr_shadow_inv;              // 236 (26: sdr_shadow_dist1)
    float2 ring_shadow_offset;          // 240
    float  ring_shadow_stroke_width;    // 248
    float  ring_shadow_radius;          // 252
    float  ring_shadow_opacity;         // 256
    float  ring_shadow_mask;            // 260
    float2 key_fill_highlight_dir;      // 264
    float  key_fill_highlight_height;   // 272
    float  key_fill_highlight_spread;   // 276 (already a cos threshold)
    float  key_fill_highlight_amount;   // 280
    float  key_fill_highlight_effect_offset;  // 284
    float  key_fill_highlight_color_bias;     // 288
    float  blur_fill_blur_radius;       // 292
    float  blur_fill_lighten_opacity;   // 296
    float  blur_fill_darken_opacity;    // 300
    float  blur_fill_normal_opacity;    // 304
    float  aberration_amount;           // 308
    float2 aberration_dir;              // 312
};

struct GlassBackgroundUniformsExt {     // 28 byte, buffer(9)
    float inv_aberration_height, aberration_offset, sdr_white_value, clamp_limit;
    float face_color_matrix_max_luma_complement;
    bool  preserve_hue, blur_fill_enabled, stroke_mode, highlight_extension, wants_highlight_bias_correction;
};

struct GlassBackgroundUniformsSdf27 {   // 368 byte
    SdfFragmentUniforms sdf;
    GlassBackgroundUniforms27 glass;
};
// The layout must match 27.2.1's air.struct_type_info (offsets in GlassBackgroundUniforms).
static_assert(sizeof(GlassBackgroundUniformsSdf27) == 368, "GlassBackgroundUniformsSdf27");
static_assert(sizeof(GlassBackgroundUniformsExt) == 28, "GlassBackgroundUniformsExt");
static_assert(sizeof(GlassBackgroundUniformsSdf) == 320, "GlassBackgroundUniformsSdf");
#define OFF(T, f) __builtin_offsetof(T, f)
static_assert(OFF(GlassBackgroundUniforms27, face_cm0) == 80, "face_cm0");
static_assert(OFF(GlassBackgroundUniforms27, bleed_darken) == 208, "bleed_darken");
static_assert(OFF(GlassBackgroundUniforms27, sdr_shadow_inv) == 236, "sdr_shadow_inv");
static_assert(OFF(GlassBackgroundUniforms27, ring_shadow_offset) == 240, "ring_shadow_offset");
static_assert(OFF(GlassBackgroundUniforms27, key_fill_highlight_dir) == 264, "key_fill_highlight_dir");
static_assert(OFF(GlassBackgroundUniforms27, blur_fill_blur_radius) == 292, "blur_fill_blur_radius");
static_assert(OFF(GlassBackgroundUniforms27, aberration_dir) == 312, "aberration_dir");
static_assert(OFF(GlassBackgroundUniformsExt, preserve_hue) == 20, "preserve_hue");
static_assert(OFF(GlassBackgroundUniformsExt, wants_highlight_bias_correction) == 24, "wants_highlight_bias_correction");

// Luminance compression before the face color matrix (27): s = sat(1 - L*k), mix(sL, s*c, 1 + 0.3(1-s)).
static float3 luma_compress(float3 c, float k) {
    float L = dot(float3(K(0x3E59B3D0u), K(0x3F371759u), K(0x3D93DD98u)), c);
    float s = saturate(1 - L * k);
    return mix(float3(s * L), s * c, float3((1 - s) * K(0x3E99999Au) + 1));
}

static float4 glass_background_base27(float2 src_uv, float2 shadow, float2 ring_sdf, float dist, float fw,
                                      float2 grad, float cover, float support, texture2d<float> tex,
                                      GlassBackgroundUniforms27 u, GlassBackgroundUniformsExt x, float edr,
                                      bool simple_sample = false,     // adapter only: 26's complex_refraction = 0
                                      bool margin_fill = false) {     // adapter only: fill a transparent backdrop margin (outer refraction)
    float2 disp = float2(dot(grad, u.displacement_mat.xy), dot(grad, u.displacement_mat.zw));
    float2 qtexel = 0.25 / float2(tex.get_width(), tex.get_height());

    // Key/fill highlight H (rim). stroke_mode: radial = 1 and inner AA via (1 - cover).
    float H = 0;
    if (u.key_fill_highlight_height > 0) {
        float zo = u.key_fill_highlight_effect_offset + dist;
        float z = -zo;
        float hfw = fw * 0.5;
        bool normal = !x.stroke_mode;
        bool skip = (zo >= hfw) || (normal ? (u.key_fill_highlight_height + hfw <= z) : (cover >= 1));
        if (!skip && bool(support)) {
            float invfw = 1 / fw;
            float radial = 1;
            if (normal) {
                float a = 1 - saturate(z / u.key_fill_highlight_height);
                radial = mix(bool(a) ? 1.0 : 0.0, a, 0.75);
            }
            float aa = normal ? saturate(fma(zo + u.key_fill_highlight_height, invfw, 0.5)) : 1 - cover;
            float m = radial * support * aa * saturate(fma(z, invfw, 0.5));
            float inv = 1 / fmax(1 - u.key_fill_highlight_spread, 1e-6);
            float f = dot(u.key_fill_highlight_dir, grad);
            float2 lobes = saturate((float2(f, -f) - u.key_fill_highlight_spread) * inv) * m;
            float2 curved = lobes / fmax(u.key_fill_highlight_amount * (1 - lobes) + 1, 1e-6);
            H = curved.x + curved.y;
        }
    }

    // Black ring shadow: difference of two soft edges (half), times opacity, shifted SDF alpha, mix(1, cover, mask).
    float ring = 0;
    if (u.ring_shadow_opacity > 0 && (cover > 0 || u.ring_shadow_mask < 1)) {
        float inv = 1 / fmax(u.ring_shadow_radius, 1e-6);
        float a = inv * ring_sdf.x;
        float b = a + u.ring_shadow_stroke_width * inv;
        float r = float(saturate(apple_poly_h(a * K(0x3F350481u)) - apple_poly_h(b * K(0x3F350481u))));
        ring = u.ring_shadow_opacity * ring_sdf.y * r * mix(1.0, cover, u.ring_shadow_mask);
    }

    // Shadow
    float4 shadowCol = 0;
    if (cover < 1) {
        float smag = lens(u.shadow_amount, u.shadow_inv_height, u.shadow_dist_offset + dist);
        float2 suv = smag * disp + src_uv;
        float smask = u.shadow_opacity * shadow.y * float(apple_poly_h(u.shadow_inv_radius * shadow.x));
        if (cover == 0 && smask < 1e-6 && H < 1e-6 && ring < 1e-6) discard_fragment();
        float4 sc;
        if (u.shadow_contribution > 1e-6) {
            float4 s = tex.sample(kSmp, suv, level(blur_lod(u.shadow_blur_radius)));
            float3 c = clean(s.rgb / fmax(s.a, 1e-6));
            float3 g = float3(dot(c, float3(u.shadow_cm0.xyz)), dot(c, float3(u.shadow_cm1.xyz)), dot(c, float3(u.shadow_cm2.xyz)));
            sc = float4(g * u.shadow_contribution + float3(float(u.shadow_cm0.w), float(u.shadow_cm1.w), float(u.shadow_cm2.w)),
                        mix(u.shadow_face_opacity, 1.0, u.shadow_contribution));
        } else {
            sc = float4(float(u.shadow_cm0.w), float(u.shadow_cm1.w), float(u.shadow_cm2.w), u.shadow_face_opacity);
        }
        shadowCol = sc * smask;
    }

    // Face: always refracts (the "r" variant), blur fill before outer refraction and before the color matrix.
    float4 face = 0;
    if (cover > 0) {
        float imag = lens(u.inner_refraction_amount, u.inner_refraction_inv_height, dist);
        float4 lo4 = float4(u.blur_dist0, u.blur_dist1, u.blur_dist2, u.blur_dist3);
        float4 al4 = float4(u.blur_alpha0, u.blur_alpha1, u.blur_alpha2, u.blur_alpha3);
        float radius = ramp_radius(imag + dist, lo4, al4, u.blur_radius);
        float2 uv = imag * disp + src_uv;
        // Simplification: the aberration branch (aberrate_texture, when aberration_amount != 0) is not transcribed;
        // NSGlassEffectView controls do not enable it in any recipe seen so far. Transcribe it if needed.
        float4 s = simple_sample ? tex.sample(kSmp, src_uv, level(blur_lod(u.blur_radius)))   // 26's non-refracting branch
                                 : tex.sample(kSmp, uv, level(blur_lod(radius)));
        float3 c = clean(s.rgb) / fmax(s.a, 1e-6);
        float4 cur = float4(c, 1);
        if (x.blur_fill_enabled) {
            float lod = blur_lod(u.blur_fill_blur_radius);
            float2 off = lod * qtexel;
            float4 fs = (tex.sample(kSmp, src_uv - off, level(lod)) + tex.sample(kSmp, src_uv + off, level(lod))) * 0.5;
            float3 fill = clean(fs.rgb / fmax(fs.a, 1e-6));
            float lw = u.blur_fill_lighten_opacity, dw = u.blur_fill_darken_opacity;
            float3 mixed = lw * fmax(c, fill) + dw * fmin(c, fill) + (1 - (dw + lw)) * c;
            cur = float4(mix(mixed, fill, u.blur_fill_normal_opacity), 1);
        }
        if (u.refraction_opacity > 0) {
            float omag = lens(u.outer_refraction_amount, u.outer_refraction_inv_height, dist);
            float olod = blur_lod(ramp_radius(omag + dist, lo4, al4, u.blur_radius));
            float4 o = tex.sample(kSmp, omag * disp + src_uv, level(olod));
            // Adapter on 26.6: the backdrop margin (outside the glass frame) can be transparent, e.g. glass with
            // inputBlurRadius = 0 (SwiftUI toolbar buttons like Settings, QuartzCore's no-blur path). The outer sample then
            // pulls the glass surface alpha down, and the color matrix (with an additive constant) applied to premultiplied
            // color then divided by alpha comes out too bright: white edge pixels, lost dark ring. Fill the missing part of
            // the outer sample with the background at the pixel itself (real 27 reads the background outside the edge; the
            // local background is the closest available approximation), then blend as 27 does. If alpha is still missing
            // (the pixel itself has no data), unpremultiply after blending like the 26.6 shader.
            if (margin_fill && o.a < 1) {
                float4 self = tex.sample(kSmp, src_uv, level(olod));
                o += (1 - o.a) * self;
            }
            float span = u.refraction_threshold1 - u.refraction_threshold0;
            float t = saturate(fma(dist, 1 / span, -u.refraction_threshold0 / span)) * u.refraction_opacity;
            cur = mix(cur, float4(clean(o.rgb), o.a), t);   // 27 blends premultiplied samples directly, no re-unpremultiply
            if (margin_fill) cur = float4(cur.rgb / fmax(cur.a, 1e-6), 1);
        }
        float4 f = cur;
        if (u.face_opacity > 0) {
            float3 cc = x.face_color_matrix_max_luma_complement > 0 ? luma_compress(cur.rgb, x.face_color_matrix_max_luma_complement) : cur.rgb;
            f.rgb = mix(cur.rgb, grade(cc, u.face_cm0, u.face_cm1, u.face_cm2), u.face_opacity);
        }
        float bmag = lens(u.edge_bleed_amount, u.edge_bleed_inv_height, dist);
        float4 b = tex.sample(kSmp, bmag * disp + src_uv, level(blur_lod(u.edge_bleed_blur_radius)));
        float3 bg = grade(clean(b.rgb / fmax(b.a, 1e-6)), u.bleed_cm0, u.bleed_cm1, u.bleed_cm2);
        float bspan = u.edge_bleed_dist1 - u.edge_bleed_dist0;
        float bt = saturate(fma(dist, 1 / bspan, -u.edge_bleed_dist0 / bspan));
        float L = saturate(dot(f.rgb, float3(K(0x3E59999Au), K(0x3F372474u), K(0x3D93A92Au))));
        float k = u.bleed_darken.x * L + u.bleed_darken.y;
        k = k * k * bt;
        k = k * k * u.edge_bleed_opacity;
        face = float4(mix(f.rgb, bg, k), f.a);
    }

    // Composite: face over shadow, then the black ring source-over.
    float4 o = mix(shadowCol, face, cover);
    o = o * (1 - ring) + float4(0, 0, 0, ring);

    // Highlight: rebuild the backdrop (LOD 0) where transparent, grade weighted by face_opacity*H,
    // clamp min/max by the sign of bias, then V *= 1 + bias*H*(3 - 2V). highlight_extension raises alpha by (1-A)H.
    if (H > 1e-6) {
        float3 C = o.rgb;
        float A = o.a;
        float rem = 1 - A;
        float3 P = C, Bfull = 0;
        if (A < 1) {
            float4 bs = tex.sample(kSmp, src_uv, level(fmax(0.0, log2(1.0))));
            // Adapter on 26.6: outside the glass frame the backdrop margin can be transparent (blur 0 glass), with no
            // background to rebuild. Darken with a black source-over layer instead: factor 1 + bias H (3 - 2V) with the
            // estimated V = glass color where the glass surface is, white where there is only background.
            // Simplification: on dark backgrounds the rim is lighter than 27's (27 uses the background's real V).
            if (margin_fill && bs.a < 0.05) {   // with partial data (samples near the frame) Bu = rgb / a below is still correct
                float3 V = cover > 0.5 ? C / fmax(A, 1e-6) : float3(1);
                float3 k3 = saturate(-u.key_fill_highlight_color_bias * H * fma(float3(-2), saturate(V), float3(3)));
                float k = fmax(fmax(k3.x, k3.y), k3.z);
                return float4(C * (1 - k3), A + rem * k) * edr;
            }
            float3 Bu = clean(bs.rgb / fmax(bs.a, 1e-6));
            float3 Bh = Bu;
            if (u.face_opacity > 0) {
                float3 cc = x.face_color_matrix_max_luma_complement > 0 ? luma_compress(Bu, x.face_color_matrix_max_luma_complement) : Bu;
                float3 g = grade(cc, u.face_cm0, u.face_cm1, u.face_cm2);
                if (x.wants_highlight_bias_correction) g = u.key_fill_highlight_color_bias < 0 ? fmin(g, Bu) : fmax(g, Bu);
                Bh = mix(Bu, g, u.face_opacity * H);
            }
            P = Bh * rem + C;
            Bfull = Bu;
        }
        float3 T = fma(float3(u.key_fill_highlight_color_bias * H), fma(float3(-2), P, float3(3)), float3(1)) * P;
        float A2 = rem * H * float(x.highlight_extension ? 1 : 0) + A;
        o = float4(T - (1 - A2) * Bfull, A2);
    }

    // SDR holding tone (27: a single sdr_shadow_dist0 / sdr_shadow_inv pair)
    if (u.holding_tone_opacity > 0) {
        float w = 1 - saturate((dist - u.sdr_shadow_dist0) * u.sdr_shadow_inv);
        float sa = saturate(o.a);
        float4 h = float4(x.sdr_white_value * o.rgb * sa / fmax(o.a, 1e-6), sa);
        o = mix(o, h, w * u.holding_tone_opacity);
    }

    // Clamp EDR (limit and preserve_hue live in Ext)
    if (x.clamp_limit > 0) {
        float3 c = o.rgb / fmax(o.a, 1e-6);
        if (x.preserve_hue) {
            float m = fmax(fmax(c.x, c.y), c.z);
            if (m > x.clamp_limit) c *= x.clamp_limit / m;
        } else {
            c = clamp(c, float3(-0.75), float3(x.clamp_limit));
        }
        o.rgb = c * o.a;
    }
    o.rgb *= edr;
    return o;
}

// glass_background_base_inl: main SDF, shadow SDF, ring SDF (only when needed), then calls base27.
static float4 base27_inl(float2 sdf_uv, float2 src_uv, SdfFragmentUniforms sdf,
                         GlassBackgroundUniforms27 u, GlassBackgroundUniformsExt x, texture2d<float> tex, float edr,
                         bool simple_sample = false, bool margin_fill = false) {
    int mode = int(sdf.arg.z);
    float cover = 0, dist = 0, fw = 1e-4;
    float2 grad = 0;
    if (mode > -1) {
        float4 s = compute_sdf_with_mode(sdf_uv, mode, sdf);
        dist = s.x; grad = s.yz;
        fw = fmax(fwidth(s.x), K(0x38D1B717u));
        cover = saturate(0.5 - s.x / fw) * s.w;
    }
    float2 shadow = 0;
    if (cover < 1) shadow = compute_sdf_with_mode(u.shadow_offset + sdf_uv, abs(mode) | 4, sdf).xw;
    float2 ring = 0;
    if (u.ring_shadow_opacity > 0 && (cover > 0 || u.ring_shadow_mask < 1))
        ring = compute_sdf_with_mode(u.ring_shadow_offset + sdf_uv, abs(mode) | 4, sdf).xw;
    return glass_background_base27(src_uv, shadow, ring, dist, fw, grad, cover, mode > -1 ? 1.0 : 0.0, tex, u, x, edr, simple_sample, margin_fill);
}

// One sdf_texture sample for the 27 path: texels with coverage w = 0 (outside the region where QuartzCore computes the SDF,
// distance left at 0) are treated as far outside the shape, because 27's dark rim/ring/highlight rely on distance alone
// (26.6 also multiplies by w, so it does not need this). Without this step the whole quad outside the SDF band is treated
// as lying on the edge (dark frame around the lock screen clock, Spotlight).
static float4 sdf_texel(texture2d<float> sdft, float2 uv) {
    float4 s = sdft.sample(kSdfSmp, uv);
    if (s.w <= 1e-4) s.x = 1e4;
    return s;
}

// Like base27_inl but the SDF is read from sdf_texture (the non-sdf glass_background_* variants): t0 = source uv,
// t1 = sdf_texture uv. The texture variant's shadow_offset is already in uv (set by QuartzCore). The ring offset (SDF
// points) is converted to sdf_texture uv: SDF points -> source uv (displacement_mat, by rows) -> pixels (inverse of the
// t0 derivatives) -> t1 (t1 derivatives).
// fwMax: upper bound on fwidth for the highlight rim H (2 pixel sizes in SDF points). At the SDF region boundary (empty
// texels), especially rounded corners where both quad neighbors are empty, fwidth grows to several points and the
// "draw H only inside the edge" condition (dist < fw/2) no longer holds it back, so H leaks outside the edge.
// Offset o in SDF points -> sdf_texture uv offset: SDF points -> source uv (displacement_mat, by rows) -> pixels
// (inverse of the t0 derivatives: a = dfdx, b = dfdy) -> t1 (t1 derivatives: c, e).
static float2 sdf_to_t1(float2 o, float4 dm, float2 a, float2 b, float2 c, float2 e) {
    float2 sd = float2(dot(o, dm.xy), dot(o, dm.zw));
    float det = a.x * b.y - b.x * a.y;
    float2 p = fabs(det) > 1e-20 ? float2(sd.x * b.y - b.x * sd.y, a.x * sd.y - sd.x * a.y) / det : float2(0);
    return c * p.x + e * p.y;
}

// Glass short side (points) from sdf_texture. The real sdf_texture is an atlas (captured from WindowServer: the glass
// takes one cell, texels at the texture center do not belong to the glass), so the depth at the texture center is not
// used. The SDF of a convex shape is convex along every line; along the inward normal ray from the pixel, the minimum is
// always -1/2 of the short side (body: to the midline; rounded end: to the arc center). Double the step until the distance
// rises again (bracketing the minimum), then a 10-step golden-section search locates it. The minimum value is not taken
// from the smallest sample (off by the search error and by bilinear interpolation rounding the V tip, up to half a texel:
// half a point on a 1x display, and Control Center refracts by -2 x short side, so with a = 0 disabling blur the error is
// visible) but from the intersection of the V's two straight branches: the descending branch through the pixel and the
// midway sample, the ascending one through two samples farther from the minimum than the search error plus 1.5 texels.
// 27 has an explicit short side (Environment.dimensions) and is exact; the branch intersection is equally exact for
// capsules and rounded ends. Pixels outside the SDF region: 0. k: texels per point.
static float sdf_along(texture2d<float> sdft, float2 t1, float2 n, float r, float4 dm, float2 a, float2 b, float2 c, float2 e) {
    float4 q = sdft.sample(kSdfSmp, t1 + sdf_to_t1(-n * r, dm, a, b, c, e), level(0));
    return q.w <= 1e-4 ? 1e4 : q.x;
}
static float glass_size_tex(texture2d<float> sdft, float2 t1, float4 s, float4 dm, float2 a, float2 b, float2 c, float2 e,
                            float k) {
    if (s.w <= 1e-4 || dot(s.yz, s.yz) < 1e-6) return 0;
    float2 n = normalize(s.yz);
    float lo = 0, mid = 1, prev = s.x, cur = sdf_along(sdft, t1, n, 1, dm, a, b, c, e);
    while (cur < prev && mid < 2048) {   // bracket the minimum in [lo, 2 mid]
        lo = mid > 1 ? mid * 0.5 : 0; prev = cur; mid *= 2;
        cur = sdf_along(sdft, t1, n, mid, dm, a, b, c, e);
    }
    float hi = mid; lo = fmax(lo, 0.0);
    const float g = 0.6180339887;
    float x1 = hi - g * (hi - lo), x2 = lo + g * (hi - lo);
    float f1 = sdf_along(sdft, t1, n, x1, dm, a, b, c, e), f2 = sdf_along(sdft, t1, n, x2, dm, a, b, c, e);
    for (int i = 0; i < 10; ++i) {
        if (f1 < f2) { hi = x2; x2 = x1; f2 = f1; x1 = hi - g * (hi - lo); f1 = sdf_along(sdft, t1, n, x1, dm, a, b, c, e); }
        else         { lo = x1; x1 = x2; f1 = f2; x2 = lo + g * (hi - lo); f2 = sdf_along(sdft, t1, n, x2, dm, a, b, c, e); }
    }
    float rm = f1 < f2 ? x1 : x2, fm = fmin(fmin(f1, f2), s.x);
    float h = (hi - lo) + 1.5 / k, rl = 0.5 * rm;
    if (rm > 2 * h) {   // pixels near the minimum (deep inside, no refraction) keep the smallest sample
        float fl = sdf_along(sdft, t1, n, rl, dm, a, b, c, e);
        float fr1 = sdf_along(sdft, t1, n, rm + h, dm, a, b, c, e), fr2 = sdf_along(sdft, t1, n, rm + 2 * h, dm, a, b, c, e);
        float m1 = (s.x - fl) / rl, m2 = (fr2 - fr1) / h;
        float r0 = (s.x - fr1 + m2 * (rm + h)) / (m1 + m2), fv = s.x - m1 * r0;
        // The intersection is valid when both branches slope the right way, lie in the SDF region (empty texel = 1e4)
        // and the minimum falls between the two sample groups.
        if (m1 > 0 && m2 > 0 && fl < 1e3 && fr2 < 1e3 && r0 > rl && r0 < rm + h && isfinite(fv)) fm = fmin(fm, fv);
    }
    return fmax(-2 * fm, 0.0);
}

// sdf_texture texels per SDF point: distances in sdf_texture are in texels (sdf-capture: slope ~1 per texel), while the
// 27 parameters (1 point rim band, highlight, ring, short side) are in points. QuartzCore builds sdf_texture at densities
// that vary by app (Finder 1 texel/point on a 1x display; Settings, Activity Monitor while scrolling are denser): treating
// texels as points shrinks the 1 point band to half a pixel, the button loses its dark ring and the highlight moves to the
// edge. Computed geometrically (1 point along x, y -> uv -> texels), from the screen derivatives of texcoord1 (texels per
// pixel, square root of the determinant) divided by points per pixel (pl): tied to real pixels. An earlier version went
// through displacement_mat (SDF points -> source uv -> pixels) and gave a smaller value than real on the Settings button
// (only the left edge had a ring). 1 if it cannot be computed.
static float sdf_texels_per_point(texture2d<float> sdft, float2 c, float2 e, float pl) {
    float2 sz = float2(sdft.get_width(), sdft.get_height());
    float2 ux = c * sz, uy = e * sz;
    float k = sqrt(fabs(ux.x * uy.y - ux.y * uy.x)) / pl;
    return isfinite(k) && k > 0.05 ? clamp(k, 0.125, 64.0) : 1.0;
}

// k = sdf_texels_per_point: every distance fed to the 27 path is converted to points (divided by k), coverage is unchanged (a ratio).
static float4 base27_tex(float2 t0, float2 t1, texture2d<float> sdft, GlassBackgroundUniforms27 u,
                         GlassBackgroundUniformsExt x, texture2d<float> tex, float edr, float fwMax, float k, bool margin_fill) {
    float2 a = dfdx(t0), b = dfdy(t0), c = dfdx(t1), e = dfdy(t1);
    // Coverage and shadow come from the raw sample as in 26.6; only distances fed to 27-specific effects use sdf_texel
    // (converting before fwidth makes the jump to 1e4 inflate fwidth, giving wrong coverage at the SDF region boundary).
    float4 s = sdft.sample(kSdfSmp, t1);
    float fw = fmax(fwidth(s.x), K(0x38D1B717u));
    float cover = saturate(0.5 - s.x / fw) * s.w;
    float dist = s.w <= 1e-4 ? 1e4 : s.x / k;
    float2 shadow = 0;
    if (cover < 1) { shadow = sdft.sample(kSdfSmp, u.shadow_offset + t1).xw; shadow.x /= k; }
    float2 ring = 0;
    if (u.ring_shadow_opacity > 0 && (cover > 0 || u.ring_shadow_mask < 1)) {
        ring = sdf_texel(sdft, t1 + sdf_to_t1(u.ring_shadow_offset, u.displacement_mat, a, b, c, e)).xw;
        ring.x /= k;
    }
    return glass_background_base27(t0, shadow, ring, dist, fmin(fw / k, fwMax), s.yz, cover, 1.0, tex, u, x, edr, false, margin_fill);
}

// Harness: "bakes" sdf_texture with compute_sdf_with_mode. box = (top-left corner, size) in screen points
// (y down), ctr = glass center; sdf_uv = (x - ctr.x, ctr.y - y) like group.swift's quad.
kernel void harness_bake_sdf(texture2d<float, access::write> out [[texture(0)]],
                             constant SdfFragmentUniforms& s [[buffer(0)]], constant float4& box [[buffer(1)]],
                             constant float2& ctr [[buffer(2)]], constant float& band [[buffer(3)]],
                             constant float& unit [[buffer(4)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float2 p = box.xy + (float2(gid) + 0.5) / float2(out.get_width(), out.get_height()) * box.zw;
    float4 v = compute_sdf_with_mode(float2(p.x - ctr.x, ctr.y - p.y), int(s.arg.z), s);
    // band > 0: only write the SDF within |d| <= band around the edge, leave the rest empty (0) as QuartzCore textures may.
    bool empty = band > 0 && fabs(v.x) > band;
    // Distances in the real sdf_texture are in texels (sdf-capture: slope ~1 per texel), not points: the Settings toolbar
    // button has an sdf_texture denser than 1 texel/point, so 27's 1 point band shrank to half a pixel (lost dark ring,
    // highlight at the edge).
    v.x *= float(out.get_width()) / box.z * unit;   // unit: units per texel (the harness tests units off from texel density)
    out.write(empty ? float4(0) : v, gid);
}

fragment float4 r27_glass_background_sdf_all_lpf(VOut in [[stage_in]],
                                                 texture2d<float> source_texture [[texture(3)]],
                                                 constant GlassBackgroundUniformsSdf27& u [[buffer(1)]],
                                                 constant GlassBackgroundUniformsExt& u_ext [[buffer(9)]],
                                                 constant float& edr_scale [[buffer(6)]]) {
    return base27_inl(in.sdf_uv, in.src_uv, u.sdf, u.glass, u_ext, source_texture, edr_scale);
}

// =====================================================================================
// 3. Adapter: 26 ABI -> 27 algorithm. 27-only parameters are function constants, defaulting to
//    values measured from the 27.0 NSGlassEffectView (gpui-glass-demo) or explicitly marked unknown.
// =====================================================================================
constant bool  kBlurFill     [[function_constant(0)]];   // blur_fill_enabled
constant bool  kHighlightExt [[function_constant(1)]];   // highlight_extension: host value unknown
constant bool  kBiasCorrect  [[function_constant(2)]];   // wants_highlight_bias_correction: unknown
constant bool  kDarkMode     [[function_constant(3)]];   // colorScheme == .dark: changes face, blur fill, max luma, slider target defaults
constant bool  kInactive     [[function_constant(4)]];   // window not active (GlassRecipes.InactiveCondition: flags bit 1 off)
constant float kRingOffY     [[function_constant(10)]];
constant float kRingStroke   [[function_constant(11)]];
constant float kRingRadius   [[function_constant(12)]];
constant float kRingOpac     [[function_constant(13)]];  // 0.06: RegularBase.Base (DesignLibrary 27.2.1, 0x195f20f78); set to 0 when disabled (bit 29, offscreen)
constant float kRingMask     [[function_constant(14)]];
constant float kKfHeight     [[function_constant(15)]];
constant float kKfOffset     [[function_constant(16)]];
constant float kKfSpread     [[function_constant(17)]];  // cos(spread)
constant float kKfAmount     [[function_constant(18)]];  // 1/CA_amount - 2
constant float kKfBias       [[function_constant(19)]];
constant float kKfDirX       [[function_constant(20)]];  // (sin(angle), -cos(angle))
constant float kKfDirY       [[function_constant(21)]];
constant float kFillRadius   [[function_constant(22)]];
constant float kFillLight    [[function_constant(23)]];
constant float kFillDark     [[function_constant(24)]];
constant float kFillNormal   [[function_constant(25)]];
constant float kMaxLumaComp  [[function_constant(26)]];  // 1 - max luma; SDR displays use MaxLumaSDR: Aqua 0.94, dark 0.6
constant float kDiffusion    [[function_constant(27)]];  // 27 transparency slider (NSGlassTintAmount), 0..1, 0.5 = neutral
constant float kFaceFillR    [[function_constant(28)]];  // 27 face color matrix (RegularBase.Base, 27 branch, DesignLibrary 27.2.1):
constant float kFaceFillG    [[function_constant(29)]];  //  Aqua (0x195f20550..618): fill (1,1,1,0.2), black 0.4, white 1.03, sat 1.2
constant float kFaceFillB    [[function_constant(30)]];  //  dark (0x195f204cc, 0x195f20bc8..c20): fill (0,0,0,0), black 0.125, white 1.125, sat 1.3
constant float kFaceFillA    [[function_constant(31)]];  //  26.6 measured: Aqua (1,1,1,0.35) 0.5 / 0.95 / 1, dark (0,0,0,0.35) 0.2 / 0.6 / 1
constant float kFaceBlack    [[function_constant(32)]];
constant float kFaceWhite    [[function_constant(33)]];
constant float kFaceSat      [[function_constant(34)]];
constant float kBlurRadius   [[function_constant(35)]];  // blur radius override; default clampedLinear(x; 64..160 -> 0..4)
constant float kPixelLength  [[function_constant(36)]];  // environment.pixelLength (1/scale), default 0.5 (2x)
constant float kRefractionOpacity [[function_constant(37)]];  // inputRefractionOpacity, default 0.6 (regular, 27 branch)
constant int   kVariant      [[function_constant(38)]];  // 0 regular, 1 clear, 2 sidebar, 3 menu
constant float kGlassSize    [[function_constant(39)]];  // glass short side override (points), default taken from the SDF
constant float kHeadroom     [[function_constant(40)]];  // current display EDR headroom (1 = SDR)
constant float kMaxHeadroom  [[function_constant(41)]];  // inputMaxHeadroom = sdrAdjustment.headroomTransitionPoint = 1.2 (27 branch,
                                                         // regular and clear, light = dark; RegularBase.Base 0x195f214f8)
constant bool  kInBounds     [[function_constant(44)]];  // no drawing outside the glass edge (default: on for the automatic path)
#define FC(name, dflt) (is_function_constant_defined(name) ? name : (dflt))

// RegularDiffusionAmount (DesignLibrary 27.2.1, 0x195f22ea0): applies diffusion `a` to the spec's blur fill.
// ld = (lighten, darken), n = normal opacity. Returns (lighten, darken, normal).
// Simplification: blur fill only; two other fields this function also interpolates (color Spec+0x2b0, Float Spec+0x2ec) are not understood yet.
static float3 regular_diffusion(float a, float2 ld, float n) {
    if (fabs(a - 0.5) < K(0x39b504f3u)) return float3(ld, n);
    if (a < 0.5) {
        float w = clamp(2 * a, 0.0, 1.0);
        return float3(ld * w + (ld * 0.75) * (1 - w), n * w);
    }
    float w = clamp(2 * (a - 0.5), 0.0, 1.0);
    float2 t = ld.x > 0 ? (ld.y > 0 ? float2(0.9, 0.9) : float2(0.9, 0))
                        : (ld.y > 0 ? float2(0, 0.9) : float2(0));
    return float3(ld * (1 - w) + t * w, n * (1 - w) + w);
}

// SidebarDiffusionAmount (0x195f2cbac): like RegularDiffusionAmount but normal goes to 0.25 (not 0) when pulled
// toward 0, and lighten/darken stay unchanged when pulled toward 1. Fill/black are later overwritten by FaceEffect (V2).
static float3 sidebar_diffusion(float a, float2 ld, float n) {
    if (fabs(a - 0.5) < K(0x39b504f3u)) return float3(ld, n);
    if (a < 0.5) {
        float w = clamp(2 * a, 0.0, 1.0);
        return float3(ld * w + (ld * 0.75) * (1 - w), 0.25 * (1 - w) + n * w);
    }
    float w = clamp(2 * (a - 0.5), 0.0, 1.0);
    return float3(ld, n * (1 - w) + w);
}

// Also in RegularDiffusionAmount: the face color matrix fill color (Spec+0x2b0) moves toward
// (1,1,1,0) when pulled toward 0 and toward (1,1,1,0.5) when pulled toward 1 (0x195f23348..0x195f233bc, mixed via
// 0x195f7f598). The mix direction is chosen by continuity at a = 0.5 (the function returns early there).
// Dark mode (flag w20 = colorScheme == .dark): the target rgb is the face black (Spec+0x2a4) instead of 1.
// 0x195f7f598 reads Color.Resolved.red/green/blue (sRGB components) and alpha and interpolates each channel
// linearly, i.e. exactly an RGBA mix on sRGB values here. This branch's dark max luma: see the adapter.
static float4 regular_diffusion_fill(float a, float4 fill, float3 tint) {
    if (fabs(a - 0.5) < K(0x39b504f3u)) return fill;
    if (a < 0.5) return mix(float4(tint, 0), fill, clamp(2 * a, 0.0, 1.0));
    return mix(fill, float4(tint, 0.5), clamp(2 * (a - 0.5), 0.0, 1.0));
}

// CA::ColorMatrix::set_ycc_composite(white, black, saturation, fill) (QuartzCore 26.6, 0x7ff80d2348a2):
// RGB -> YCbCr BT.709, Y' = (white - black) Y + black, CbCr' = sat (CbCr - 0.5) + 0.5, back to RGB;
// then the whole matrix is multiplied by (1 - fill.a) and the premultiplied fill added. Simplified in RGB:
// c' = (1 - fa) (sat c + (white - black - sat) Y(c) + black) + fill.rgb fa.
// Simplification: assumes 27 uses the same construction (QuartzCore 27 not read yet); max luma is left to the shader (kMaxLumaComp).
static void ycc_face(float black, float white, float sat, float4 fill, thread half4& r0, thread half4& r1, thread half4& r2) {
    float3 L = float3(0.2126, 0.7152, 0.0722);
    float k = 1 - fill.w;
    half4 rows[3];
    for (int i = 0; i < 3; ++i) {
        float3 m = (white - black - sat) * L;
        m[i] += sat;
        rows[i] = half4(float4(m * k, black * k + fill[i] * fill.w));
    }
    r0 = rows[0]; r1 = rows[1]; r2 = rows[2];
}

// Recognizes the glass kind from 26.6 uniforms, so the adapter inside WindowServer knows which 27 parameter set to use.
// The signature is the face color matrix QuartzCore 26.6 builds (set_ycc_composite) from CAFilter inputs measured on 26.6
// (measurements/glass-states-25G72.json, NSGlassEffectView .regular/.clear x Aqua/DarkAqua).
// 26.6 does not change glass when the window is inactive (DesignLibrary 26.6 has no inactive schema), so the inactive
// state cannot be inferred. Returns kVariant (0 regular, 1 clear) or -1 if nothing matches: the 26.6 shader is used then.
// Simplification: no 26.6 sidebar/menu signature yet (not reproducible in the test app), they fall back to -1.
// 26.6 face recipes -> 27 glass kind. 26.6 recipe sources: DesignLibrary 26.6 addresses and uniforms measured in
// WindowServer; 27 recipes from DesignLibrary 27. variant: 0 regular, 1 clear, 3 menu, 4 Dock;
// -1 = adaptive glass (face computed at runtime from hover and background brightness: buttons, playback bars): full 27 regular;
// -2 = keep 26.6 as is (pad/phone Control Center, not on Mac).
// 5..7 are snapshots of adaptive glass at rest (no constants in the binary).
// 17, 18: not 26.6 faces but the 27 SidebarRecipe face ggapp writes into the sidebar glass filter (GGApp.sidebarGlass,
// ggapp/Sources/Sidebar.m; DesignLibrary 27 FaceEffect 0x195f2cf7c). Hybrid approach: the app computes the recipe as 27
// does, the shader recognizes it and draws kVariant 2. Matches no 26.6 face; non-key windows still send this face (27 has
// no inactive schema for sidebars).
// Simplification: light face #17 equals the 27 regular light face; no process sends 27 regular yet (26.6 has no such constant).
// Once ggapp computes the 27 regular recipe in the app too, sidebars need their own flag (e.g. a bit in preserve_hue).
struct Sig26 { float black, white, sat; float4 fill; int variant; bool dark, inactive; };
constant int kNumSigs26 = 19;
constant Sig26 kSigs26[kNumSigs26] = {
    { 0.5,   0.95, 1.0,  float4(1, 1, 1, 0.35),        0, false, true  },  // 0 regular inactive light (0x7ffc0a633b10)
    { 0.2,   0.6,  1.0,  float4(0, 0, 0, 0.35),        0, true,  true  },  // 1 regular inactive dark
    { 0.2,   0.95, 1.0,  float4(1, 1, 1, 0.1),         1, false, false },  // 2 NSGlassEffectView .clear light (0x7ffc0a5de8d0)
    { 0.05,  0.8,  1.0,  float4(1, 1, 1, 0.05),        1, true,  false },  // 3 .clear dark
    { 0.5,   1.03, 1.0,  float4(1, 1, 1, 0.4),         0, false, false },  // 4 regular active light: menus, buttons, popovers, panels
    { 0.8,   0.97, 1.0,  float4(1, 1, 1, 0.25),       -1, false, false },  // 5 adaptive (small buttons 49x30, 36x36)
    { 0.75,  0.97, 1.1,  float4(0),                   -1, false, false },  // 6 adaptive (inactive window button group)
    { 0.5,   1.0,  1.0,  float4(0),                   -1, false, false },  // 7 adaptive? (lock screen clock digits)
    { 0.2,   0.6,  1.0,  float4(0, 0, 0, 0.4),         0, true,  false },  // 8 regular active dark (0x7ffc0a632e40)
    { 0.15,  0.9,  1.05, float4(1, 1, 1, 0.1),         4, false, false },  // 9 Dock light (0x7ffc0a625f20, matches measured uniforms)
    { 0.075, 0.9,  1.06, float4(0, 0, 0, 0.1),         4, true,  false },  // 10 Dock dark
    { 0.8,   0.96, 1.0,  float4(0.96, 0.96, 0.96, 0.04), 3, false, true },  // 11 menu inactive light
    { 0.15,  0.3,  1.0,  float4(0),                    3, true,  true  },  // 12 menu inactive dark
    { 0.075, 1.15, 1.06, float4(0),                    1, false, false },  // 13 clear base (Dock/CC/focusBorder background) -> 27 clear
    { 0.125, 0.8,  1.3,  float4(0),                    5, false, false },  // 14 Mac Control Center 0x7ffc0a624cb0 (all parts, light = dark)
    { 0.16,  1.05, 1.3,  float4(0),                   -2, false, false },  // 15 pad Control Center 0x7ffc0a624510 (unused on Mac)
    { 0.2,   1.1,  1.6,  float4(0),                   -2, false, false },  // 16 phone Control Center (unused on Mac)
    { 0.4,   1.03, 1.2,  float4(1, 1, 1, 0.2),         2, false, false },  // 17 27 sidebar light (ggapp SidebarRecipe)
    { 0.1,   0.5,  0.6,  float4(0),                    2, true,  false },  // 18 27 sidebar dark (ggapp SidebarRecipe)
};

/// Index of the 26.6 recipe matching face_cm (tolerance 2e-3), -1 if no recipe matches.
static int classify_sig26(GlassBackgroundUniforms g) {
    for (int s = 0; s < kNumSigs26; ++s) {
        half4 r0, r1, r2;
        ycc_face(kSigs26[s].black, kSigs26[s].white, kSigs26[s].sat, kSigs26[s].fill, r0, r1, r2);
        float4 d = fmax(fmax(fabs(float4(r0 - g.face_cm0)), fabs(float4(r1 - g.face_cm1))), fabs(float4(r2 - g.face_cm2)));
        if (fmax(fmax(d.x, d.y), fmax(d.z, d.w)) < 2e-3) return s;
    }
    return -1;
}

/// Interpolated face in 26.6 show/hide animations (measured on a WindowServer dump): face = mix(identity, recipe s, t),
/// blur = B t (2 - t). Returns s (best match) and t in (0, 1]: the line is continuous up to the target recipe (at t = 1 the
/// 27 glass is exactly recipe s, as 27 uses explicit parameters), leaving no gap with classify_sig26 (a gap at t ~ 0.995
/// dropped that frame to white 27 regular: Control Center flashed when returning from a module). The first frame (face
/// near identity, blur near 0) returns t = 0 with #4: at t = 0 the 27 glass does not depend on the recipe. -1 if the face
/// lies on no line (adaptive glass). glass_mode26 calls classify_sig26 first, so exact recipe faces still take that branch.
static int interp_sig26(GlassBackgroundUniforms g, thread float& t) {
    float4 c0 = float4(g.face_cm0) - float4(1, 0, 0, 0), c1 = float4(g.face_cm1) - float4(0, 1, 0, 0),
           c2 = float4(g.face_cm2) - float4(0, 0, 1, 0);
    t = 0;
    if (dot(c0, c0) + dot(c1, c1) + dot(c2, c2) < 1e-5 && g.blur_radius < 0.05) return 4;
    int best = -1;
    float bestRes = 4e-3;   // error of a face stored in half (12 values, each up to ~5e-4)
    for (int s = 0; s < kNumSigs26; ++s) {
        half4 r0, r1, r2;
        ycc_face(kSigs26[s].black, kSigs26[s].white, kSigs26[s].sat, kSigs26[s].fill, r0, r1, r2);
        float4 d0 = float4(r0) - float4(1, 0, 0, 0), d1 = float4(r1) - float4(0, 1, 0, 0), d2 = float4(r2) - float4(0, 0, 1, 0);
        float den = dot(d0, d0) + dot(d1, d1) + dot(d2, d2);
        if (den < 1e-6) continue;
        float ts = (dot(c0, d0) + dot(c1, d1) + dot(c2, d2)) / den;
        float4 e0 = c0 - ts * d0, e1 = c1 - ts * d1, e2 = c2 - ts * d2;
        float res = sqrt(dot(e0, e0) + dot(e1, e1) + dot(e2, e2));
        if (ts > 0 && ts < 1.01 && res < bestRes) { bestRes = res; best = s; t = min(ts, 1.0f); }   // 1.01: half face rounding can overshoot slightly
    }
    if (best < 0) t = 0;
    return best;
}

kernel void test_interp_sig26(constant GlassBackgroundUniforms& g [[buffer(0)]], device int* out [[buffer(1)]]) {
    float t = 0;
    out[0] = interp_sig26(g, t);
    ((device float*)out)[1] = t;
}

/// 27 glass kind to draw (-1 = keep 26.6), dark and inactive, from the kSigs26 table.
static int classify_glass26(GlassBackgroundUniforms g, thread bool& dark, thread bool& inactive) {
    int s = classify_sig26(g);
    if (s < 0 || kSigs26[s].variant < 0) return -1;
    dark = kSigs26[s].dark; inactive = kSigs26[s].inactive;
    return kSigs26[s].variant;
}
static int classify_glass26(GlassBackgroundUniforms g, thread bool& dark) {
    bool inactive = false;
    return classify_glass26(g, dark, inactive);
}

/// Drawing mode for the automatic path: >= 0 a 27 glass kind (as classify_glass26); -1 adaptive glass (draw 27 regular);
/// -2 keep 26.6 as is (only pad/phone Control Center, not on Mac). A face matching no recipe: adaptive (-1).
/// Adaptive glass: dark estimated from the face (gray 0.5 through the face comes out below 0.5), inactive = false.
/// t: show/hide animation progress (1 when not animating). A face interpolated toward recipe s (interp_sig26) draws the
/// 27 glass of s at progress t (gg27_params); if s is adaptive glass (-1) it is treated as regular.
// System appearance is dark (set by the dylib from the logged-in user's AppleInterfaceStyle). Adaptive glass faces change
// with background brightness, so they do not tell light from dark (the light Settings toolbar button was once drawn as dark 27 glass).
constant bool  kSystemDark   [[function_constant(46)]];
// Per-draw appearance flag: the dylib binds a uint (1 = dark) at buffer 28 every time one of our glass pipelines is bound,
// so light/dark switches take effect immediately. Constant 47 enables this parameter (the harness and the old ABI have no
// buffer 28). Takes priority over constant 46.
constant bool  kAppearanceBuf [[function_constant(47)]];
constant bool  kAppearanceBufOn = is_function_constant_defined(kAppearanceBuf) && kAppearanceBuf;

// Appearance flag parameter for the 8 gg27_glass_background_* entry functions and the value read (-1 when constant 47 is off).
// Buffer 28 = GGLive: appearance flag and global fallback slider amount (updated by GGGlass at runtime via Darwin notify).
struct GGLive { uint appearance; float diffusion; };
#define GG_APPEARANCE_ARG , constant GGLive& gg_live [[buffer(28), function_constant(kAppearanceBufOn)]]
#define GG_SYS (kAppearanceBufOn ? int(gg_live.appearance) : -1)
#define GG_LIVE_TINT (kAppearanceBufOn ? gg_live.diffusion : -1.0f)

/// Appearance of adaptive glass (the face carries no light/dark): as in 27, the glass's own appearance that ggapp writes in
/// the negative code (the view's effectiveAppearance); otherwise the global flag (sys, buffer 28); otherwise (old harness)
/// constant 46; finally a guess from the face.
static bool gg_adaptive_dark(GlassBackgroundUniforms g, int sys) {
    int own = gg_code_dark(g.preserve_hue);
    return own >= 0 ? own == 1
         : sys >= 0 ? sys == 1
         : is_function_constant_defined(kSystemDark) ? kSystemDark
         : dot(float3(g.face_cm0.xyz), float3(0.5)) + float(g.face_cm0.w) < 0.5;
}

/// sys: appearance flag (-1 none, 0 light, 1 dark).
static int glass_mode26(GlassBackgroundUniforms g, thread bool& dark, thread bool& inactive, thread float& t, int sys = -1) {
    t = 1;
    // Glass carrying an app recipe code: kind and state are decided by the app (as in 27), not guessed from the face. The
    // face is a 27 face written by the app, so it is not used for animation progress (t = 1). Reserved recipes (9..15) draw
    // as regular. Recipes 7 (widget, ChicletRecipe) and 8 (notification, NotificationCenterRecipe): the code's inactive bit
    // means subdued, not inactive (ggapp/Legibility/Recipe27.h).
    { int r; bool ia; float f, a;
      if (gg_app_code(g.preserve_hue, r, ia, f, a)) { dark = g.preserve_hue < 0; inactive = ia && r < 7; return r <= 8 ? r : 0; } }
    int s = classify_sig26(g);
    if (s < 0) {
        int si = interp_sig26(g, t);
        if (si >= 0) {
            bool adaptive = kSigs26[si].variant == -1;
            dark = adaptive ? gg_adaptive_dark(g, sys) : kSigs26[si].dark; inactive = !adaptive && kSigs26[si].inactive;
            return adaptive ? 0 : kSigs26[si].variant;
        }
        t = 1;
    }
    // Unknown faces (any blur) are adaptive glass: draw 27 regular. Previously blur >= 3 kept 26.6 (unknown Control
    // Center), which made the Settings toolbar button lose 27's dark ring.
    int mode = s >= 0 ? kSigs26[s].variant : -1;
    if (mode >= 0) { dark = kSigs26[s].dark; inactive = kSigs26[s].inactive; }
    else if (mode == -1) { dark = gg_adaptive_dark(g, sys); inactive = false; }
    return mode;
}

kernel void test_glass_mode26(constant GlassBackgroundUniforms& g [[buffer(0)]], device int* out [[buffer(1)]],
                              constant int& sys [[buffer(2)]]) {
    bool d = false, i = false;
    float t = 1;
    int m = glass_mode26(g, d, i, t, sys);
    out[0] = m == -1 ? 0 : m;   // -1 (adaptive) draws 27 regular
    out[1] = d ? 1 : 0;
}

// Test-only kernel (glass-harness/classify.swift).
kernel void test_classify_glass26(constant GlassBackgroundUniforms& g [[buffer(0)]], device int* out [[buffer(1)]]) {
    bool d = false;
    out[0] = classify_glass26(g, d);
    out[1] = d ? 1 : 0;
}

// DesignLibrary 27's ClampedLinearMap (0x195ed73f8) without an overshoot segment (upper = nil):
// linear, clamped at both ends. Every glass-size table in RegularBase.Base has this form.
static float clamped_linear(float x, float x0, float x1, float y0, float y1) {
    return mix(y0, y1, saturate((x - x0) / (x1 - x0)));
}

// Converts YCC (black, white, saturation, no fill) to 3 matrix rows, like the face (set_ycc_composite).
static void ycc_rows(float black, float white, float sat, thread half4& r0, thread half4& r1, thread half4& r2) {
    float3 L = float3(0.2126, 0.7152, 0.0722);
    half4 rows[3];
    for (int i = 0; i < 3; ++i) { float3 m = (white - black - sat) * L; m[i] += sat; rows[i] = half4(float4(m, black)); }
    r0 = rows[0]; r1 = rows[1]; r2 = rows[2];
}

// 27 adapter parameters from 26.6 uniforms (shared by the SDF and texture variants, so the two paths QuartzCore picks
// for the same glass, e.g. the Dock while magnifying, give the same result). xsAuto = glass short side (points).
// variant0 / dark0 are classify_glass26's result; the kVariant / kDarkMode function constants (always set by the harness)
// override it; inact0 (window not active, from the 26.6 recipe) is overridden by the kInactive function constant.
// bleed = false for the _no_bleed variants.
static bool gg27_forced();

// hl: YCC of the vibrant matrix for the 27 highlight layer (black, white, sat, dodge); w < 0 = no highlight
// (inactive: InactiveHighlights alpha 0; sidebar: off).
// Whether the dark rim and highlight stay inside the glass edge (kInBounds) or follow 27 exactly (dark rim 1 px outside).
// The automatic path always stays inside: pixels outside the frame are erased when content behind is redrawn, and
// QuartzCore 26.6 does not redraw the glass because the dirty region does not touch its frame ("broken rim"). Drawing the
// rim outside for glass with a shadow (active windows) was tried: it worked but was sometimes broken at the left/right
// ends (measured on the machine 2026-11-21), so it was dropped.
static bool gg27_in_bounds(GlassBackgroundUniforms g) {
    return FC(kInBounds, !gg27_forced());
}

/// Short side used by the 27 recipe: notification cards (app recipe code 8, short side >= 40) always use x = 166
/// (surfaceSize .medium); the "x" button (20..24) keeps its real size. Same threshold as ggPlan in
/// ggapp/Legibility/Recipe.m.
static float gg27_size(GlassBackgroundUniforms g, float xs) {
    int r; bool i; float f, a;
    return (gg_app_code(g.preserve_hue, r, i, f, a) && r == 8 && xs >= 40) ? 166.0 : xs;
}

/// 27 highlight intensity: subdued (the inactive bit of recipe 7, 8 codes) multiplies key/fill opacity by 0.4 (0x195e79e30:
/// 0x195e7a330, 0x195e7a954; measured on 26.6: keyColor/fillColor alpha 1 -> 0.4). The highlight blends linearly with
/// opacity, so it equals mix(r, h, 0.4).
static float gg27_hl_gain(GlassBackgroundUniforms g) {
    int r; bool i; float f, a;
    return (gg_app_code(g.preserve_hue, r, i, f, a) && (r == 7 || r == 8) && i) ? 0.4 : 1.0;
}

kernel void test_hl_gain(constant GlassBackgroundUniforms& g [[buffer(0)]], device float* out [[buffer(1)]]) {
    out[0] = gg27_hl_gain(g);
}

static void gg27_params(GlassBackgroundUniforms g, float xsAuto, bool bleed, int variant0, bool dark0, bool inact0,
                        thread GlassBackgroundUniforms27& v, thread GlassBackgroundUniformsExt& x, thread float4& hl,
                        float t = 1.0, float tpp = 0.25) {
    v.displacement_mat = g.displacement_mat;
    // Blur radii in shader uniforms are in source_texture texels, while Spec/CA values are in points.
    // QuartzCore 26.6 converts: shader = 1.6 x (texels per point) x CA (WindowServer dump: same face #4, backdrop 0.25 ->
    // blur 1.6 / edge bleed blur 31.2 / shadow blur 8, backdrop 1.0 -> 6.4 / 124.88 / 32).
    // tpp = texels per point, measured from the real texture (changes over time: Quick Look uses backdrop 1.0 while zooming).
    float kTex = 1.6 * tpp;
    bool dark = FC(kDarkMode, dark0);
    // Glass kind: 0 = .regular (RegularRecipe; active menus on Mac too, only the window shadow differs),
    // 1 = .clear (ClearRecipe: BaseSpec -> ClearSpec.Modifier -> ClearDiffusionAmount, light = dark),
    // 2 = sidebar (SidebarRecipe V2).
    // 3 = menu: like .regular when active (only the window shadow differs), different when inactive (MenuRecipe.Inactive).
    // 4 = Dock (DockRecipe.Other 0x195f0dcbc on top of ClearSpec):
    //     like clear but blur 1.5, own refraction, outer opacity 0.2, own face, dark max luma 0.75, HDR spread 120°.
    // 5 = Control Center (ControlCenterRecipe Mac branch on top of ClearSpec):
    //     every module/pill/button uses the same recipe, light = dark; blur 4.0, opacities (1, 0.1, 0.5, 1), distances
    //     (-100, -1, 0, 0), inner refraction 0.225 x (≤ 25) / -2.0 x (≥ -80), outer 0.0357 x / 0.0714 x (unclamped), outer
    //     opacity 0.1525, face 0.125 / 0.8 / 1.2 fill 0, max luma 1, dark rim 75° with fixed bias -0.3.
    // 6 = popover with arrow (CartouchePopoverRecipe): regular with a fixed 5 pt inner height; inactive only changes the
    //     Parameters layer (highlight off, darkSpecular 120°), blur/face/ring stay as when active.
    // 7 = widget (ChicletRecipe branch P): the 27-only group as clear (ClearSpec: ring 0, darkSpecular 75°, max luma 1,
    //     blur fill DiffusionBlur = ClearDiffusionAmount when a > 0.5), highlight white 0.85.
    // 8 = notification (NotificationCenterRecipe): regular active (vibrancy shadow 1 is a shared key, written by the app).
    // Subdued (the inactive bit of these two recipes' codes, 0x195e79e30): the app handles the CA-level part (blur,
    // refraction, bleed, shadow, face); the shader only multiplies the highlight by 0.4 (gg27_hl_gain). That function does
    // not change the ring or darkSpecular.
    int variant = FC(kVariant, variant0);
    bool popover = variant == 6, chiclet = variant == 7;
    if (popover || variant == 8) variant = 0;
    if (chiclet) variant = 1;
    bool clearV = variant == 1, sidebar = variant == 2, menu = variant == 3, dock = variant == 4, cc = variant == 5;
    bool regLike = variant == 0 || menu, clearFam = clearV || dock || cc;
    // Inactive: only regular and menu change at the Spec layer; sidebars look active (highlight, ring, dark rim are
    // already off); clear and Dock have no inactive schema.
    // inactP: the Parameters layer (InactiveHighlights, InactiveDarkSpecular) includes popovers; inact: the Spec layer, without popovers.
    bool inactP = FC(kInactive, inact0) && regLike;
    bool inact = inactP && !popover;
    // 27 parameters depend on x = glass short side (Environment.dimensions, points) and pl = environment.pixelLength.
    // Simplification: treats SDF units as points like the harness; if WindowServer sends pixels, divide by scale first.
    float xs = FC(kGlassSize, gg27_size(g, xsAuto));
    float pl = FC(kPixelLength, 0.5);
    float tintA, tintFlag;
    float diffusion = gg_decode_tint(g.preserve_hue, tintA, tintFlag) ? tintA : FC(kDiffusion, 0.5);
    bool slid = fabs(diffusion - 0.5) >= K(0x39b504f3u);
    // Refraction: inner height clamp(k_h x, 0..20), amount clamp(k_a x, -60..) with (k_h, k_a) = (0.25, -0.5)
    // regular/sidebar, (0.36, -0.65) clear; outer height/amount clamp(0.2x / 0.25x, 16..);
    // outer opacity (inputRefractionOpacity, Spec+0x200) 0.6 regular, 0 clear/sidebar. 27 always refracts.
    // Dock: inner 0.08 x / -0.18 x, outer 0.13 x / 0.42 x (same clamps as ClearSpec).
    v.inner_refraction_amount = cc ? fmax(-2.0 * xs, -80.0) : fmax((dock ? -0.18 : clearV ? -0.65 : -0.5) * xs, -60.0);
    v.inner_refraction_inv_height = 1 / fmax(popover ? 5.0 : cc ? clamp(0.225 * xs, 0.0, 25.0)
                                                : clamp((dock ? 0.08 : clearV ? 0.36 : 0.25) * xs, 0.0, 20.0), 1e-6);
    v.outer_refraction_amount = cc ? 0.0714 * xs : fmax((dock ? 0.42 : 0.25) * xs, 16.0);
    v.outer_refraction_inv_height = 1 / (cc ? fmax(0.0357 * xs, 1e-6) : fmax((dock ? 0.13 : 0.2) * xs, 16.0));
    v.refraction_threshold0 = g.refraction_threshold0; v.refraction_threshold1 = g.refraction_threshold1;
    // Blur: regular/sidebar clampedLinear(64..160 -> 0..4) (Spec = CA); clear constant 0.75, slider < 0.5
    // multiplies by 2a (ClearDiffusionAmount). Distances (-0.5x, -1, 0, 0), opacities (1, .5, .5, 1).
    // Inactive: FixedBlur(2, 4) for regular, MenuRecipe.Inactive 6..12 for menus (same 64..160 input).
    // Simplification: assumes frost = automatic; with frost reduced/none, inactive sets blur 1.0.
    // Dock: constant(1.5) then ClearDiffusionAmount like clear.
    float clearBlur = (cc ? 4.0 : dock ? 1.5 : 0.75) * (slid && diffusion < 0.5 ? 2 * diffusion : 1.0);
    float2 blurOut = inact ? (menu ? float2(6, 12) : float2(2, 4)) : float2(0, 4);
    v.blur_radius = FC(kBlurRadius, kTex * (clearFam ? clearBlur : clamped_linear(xs, 64, 160, blurOut.x, blurOut.y)));
    // Edge bleed: opacity by size, height = amount = 0.35x, blur 0.35x (at most 160, the shader uses half).
    float bleedH = 0.35 * xs;
    v.edge_bleed_blur_radius = kTex * 0.5 * fmin(bleedH, 160.0);
    v.edge_bleed_amount = bleedH; v.edge_bleed_inv_height = 1 / fmax(bleedH, 1e-6);
    v.shadow_amount = 0; v.shadow_inv_height = g.shadow_inv_height; v.shadow_offset = g.shadow_offset;
    v.shadow_blur_radius = g.shadow_blur_radius; v.shadow_inv_radius = 1 / clamped_linear(xs, 64, 160, 4, 24);
    // Face color matrix rebuilt from 27's original values (26's face_cm is discarded).
    // regular: light (0.4, 1.03, 1.2, fill (1,1,1,0.2)), dark (0.125, 1.125, 1.3, (0,0,0,0)), fill through the slider.
    // clear (light = dark): (0.125, 1.08, 1.06, (1,1,1,0)). sidebar (FaceEffect V2 runs after the slider, so it overrides):
    // light (0.4, 1.03, 1.2, (1,1,1,0.2)), dark (0.1, 0.5, 0.6, (0,0,0,0)).
    // Dock: light (0.15, 0.9, 1.25, fill 0), dark (0.05, 0.92, 1.25, fill (0,0,0,0.02)).
    float3 bws = cc ? float3(0.125, 0.8, 1.2)
               : dock ? (dark ? float3(0.05, 0.92, 1.25) : float3(0.15, 0.9, 1.25))
               : clearV ? float3(0.125, 1.08, 1.06)
               : (dark ? (sidebar ? float3(0.1, 0.5, 0.6) : float3(0.125, 1.125, 1.3)) : float3(0.4, 1.03, 1.2));
    float4 fill0 = cc ? float4(0)
                 : dock ? (dark ? float4(0, 0, 0, 0.02) : float4(1, 1, 1, 0))
                 : clearV ? float4(1, 1, 1, 0) : (dark ? float4(0) : float4(1, 1, 1, 0.2));
    float black = FC(kFaceBlack, bws.x);
    float4 fill = float4(FC(kFaceFillR, fill0.r), FC(kFaceFillG, fill0.g), FC(kFaceFillB, fill0.b), FC(kFaceFillA, fill0.a));
    if (regLike) fill = regular_diffusion_fill(diffusion, fill, dark ? float3(black) : float3(1));
    float white = FC(kFaceWhite, bws.y);
    // Inactive runs after the slider. Regular (InactiveFaceEffect): light white 0.96, dark black 0.08, the rest unchanged.
    // Menu (MenuRecipe.Inactive) also overrides fill: light (0.8, 0.96, fill (0.96,0.96,0.96,0.04)), dark (0.15, 0.3, fill 0).
    if (inact && menu) { black = dark ? 0.15 : 0.8; white = dark ? 0.3 : 0.96; fill = dark ? float4(0) : float4(0.96, 0.96, 0.96, 0.04); }
    else if (inact) { if (dark) black = 0.08; else white = 0.96; }
    ycc_face(black, white, FC(kFaceSat, bws.z), fill, v.face_cm0, v.face_cm1, v.face_cm2);
    // Edge bleed ycc: regular light (0.9, 1, 1.2) / dark (0.125, 0.5, 1); sidebar Planar sets sat 1.5 and
    // FaceEffect sets light black/white 0.75/0.9, dark black 0.1.
    if (sidebar) ycc_rows(dark ? 0.1 : 0.75, dark ? 0.5 : 0.9, 1.5, v.bleed_cm0, v.bleed_cm1, v.bleed_cm2);
    else if (dark) ycc_rows(0.125, 0.5, 1.0, v.bleed_cm0, v.bleed_cm1, v.bleed_cm2);
    else           ycc_rows(0.9, 1.0, 1.2, v.bleed_cm0, v.bleed_cm1, v.bleed_cm2);
    v.shadow_cm0 = g.shadow_cm0; v.shadow_cm1 = g.shadow_cm1; v.shadow_cm2 = g.shadow_cm2;
    v.shadow_contribution = g.shadow_contribution; v.shadow_face_opacity = g.shadow_face_opacity;
    // Inactive: opacities (1,1,1,1), distances 0 (uniform blur).
    // Control Center: opacities (1, 0.1, 0.5, 1), distances fixed(-100), fixed(-1), 0, 0.
    v.blur_alpha0 = 1; v.blur_alpha1 = inact ? 1.0 : cc ? 0.1 : 0.5; v.blur_alpha2 = inact ? 1.0 : 0.5; v.blur_alpha3 = 1;
    // Explicit float constants: "inact ? 0 : -1" (both sides int) with a runtime inact was compiled by Metal to +1
    // (caught by test_gg27_params in classify.swift: the automatic path had the opposite sign from forced).
    v.blur_dist0 = inact ? 0.0 : cc ? -100.0 : -0.5 * xs; v.blur_dist1 = inact ? 0.0 : -1.0; v.blur_dist2 = 0; v.blur_dist3 = 0;
    v.edge_bleed_dist0 = g.edge_bleed_dist0; v.edge_bleed_dist1 = g.edge_bleed_dist1;
    v.edge_bleed_opacity = (clearFam || inact || !bleed) ? 0 : clamped_linear(xs, 64, 160, 0, dark ? 0.8 : 0.5);
    v.face_opacity = 1;
    v.bleed_darken = dark ? float2(-1, 1) : float2(1, 0);   // useDarkenBlending: on for light, off for dark
    // Glass drop shadow (Spec.shadow, RegularBase.Base 27 branch, DesignLibrary 27.2.1 0x195f20f88..0x195f210a8, read from
    // the binary): opacity clampedLinear(xs; 64..160 -> 0.04..0.4, dark 0.6) (26.6: 0.4-0.5 for every size), radius
    // clampedLinear(64..160 -> 4..24) (26.6: 20-24), offset (0, 8) as in 26.6, normalizedHeight/Amount = 0 (the shadow does
    // not refract), vibrancy 0. Clear/Dock/Control Center (ClearSpec.Modifier, DockRecipe.Other) and sidebar V2 (Planar):
    // opacity 0. Inactive: DisableShadow (26.6 also sends 0). Only enabled when 26.6 has a shadow (shadow_opacity > 0: active
    // window). 26.6 shadow uniforms are in points for both the SDF and texture variants (dump: inv_radius 1/20, 1/24), the
    // 26.6 offset is kept.
    // Simplification: 26.6 animates the shadow opacity from 0; here the 27 value is switched on directly when 26.6 > 0.
    v.shadow_dist_offset = g.shadow_dist_offset;
    v.shadow_opacity = (regLike && !inact && g.shadow_opacity > 0) ? clamped_linear(xs, 64, 160, 0.04, dark ? 0.6 : 0.4) : 0.0;
    // inactive: DisableOuterRefaction; Dock 0.2.
    v.refraction_opacity = FC(kRefractionOpacity, cc ? 0.1525 : dock ? 0.2 : (regLike && !inact) ? 0.6 : 0.0);
    // SDR holding tone: off in 27 (sdrAdjustment: shadowOpacityShift 0, whitePointShift 1.0 for regular and clear).
    // 26.6 enables it for active windows (opacity 1, -2 / -1, white 0.97), darkening the interior by 3%.
    v.holding_tone_opacity = 0;
    v.sdr_shadow_dist0 = g.sdr_shadow_dist0;
    // 26 interpolates dist0 -> dist1; with dist1 <= dist0, 26 becomes a step at dist0 (a very large inv gives the same result).
    v.sdr_shadow_inv = g.sdr_shadow_dist1 > g.sdr_shadow_dist0 ? 1 / (g.sdr_shadow_dist1 - g.sdr_shadow_dist0) : 1e30;
    v.ring_shadow_offset = float2(0, FC(kRingOffY, 8.0));
    v.ring_shadow_stroke_width = FC(kRingStroke, 4.0);
    v.ring_shadow_radius = FC(kRingRadius, 5.0);
    // clear: ring all 0; sidebar: off in Planar; regular inactive: DisableRingShadow; menu inactive keeps the ring.
    // Automatic path (WindowServer): no drawing outside the glass edge. QuartzCore 26.6 only redraws glass within the frame
    // computed from 26.6 parameters, so anything drawn outside is erased when content behind is redrawn (broken rim on the
    // "..." button). Hence the dark rim moves inside the edge (offset 0 instead of -h) and the highlight is inset with it
    // (gg27_highlight). The ring has mask 1 so it already stays inside, unchanged.
    // Simplification: placing the outer rim exactly where 27 does would require enlarging QuartzCore's draw frame (CA hook).
    bool inBounds = gg27_in_bounds(g);
    // Ring mask 1: the ring is multiplied by glass coverage so it stays inside the edge (dark band in the upper half of the
    // interior, 27 button on white 247-250 top / 252-253 bottom), preserved on the automatic path too.
    v.ring_shadow_opacity = FC(kRingOpac, (menu || (variant == 0 && !inact)) ? 0.06 : 0.0);
    v.ring_shadow_mask = FC(kRingMask, 1.0);
    // Dark rim (Spec.darkSpecular): height h = pl < 0.5 ? 1.6 pl : pl (about 1 pixel), offset -h,
    // SDR spread 106 degrees (regular light) / 75 degrees (regular dark, clear) -> cos, amount 0.4 -> 1/0.4 - 2,
    // bias pl < 0.5 ? -0.3 : -0.25. Sidebar (Planar V2) sets height 0: off, done here with bias 0.
    // EDR (QuartzCore 27 GlassBackgroundFilter::render 0x18debc4ec): t = (min(headroom, maxHeadroom) - 1) /
    // (maxHeadroom - 1) when maxHeadroom > 1, otherwise 1. SDR display: t = 0. Used for spread and max luma.
    float hr = FC(kHeadroom, 1.0), mh = FC(kMaxHeadroom, 1.2);
    float tE = mh > 1.0000001 ? saturate((fmin(hr, mh) - 1) / (mh - 1)) : 1.0;
    float kfh = pl < 0.5 ? 1.6 * pl : pl;
    v.key_fill_highlight_dir = float2(FC(kKfDirX, 1.0), FC(kKfDirY, 0.0));
    v.key_fill_highlight_height = FC(kKfHeight, kfh);
    // Inactive (InactiveDarkSpecular, Parameters layer): spread = spreadSDR = 120 degrees, amount 0.5, colorBias x0.75.
    // These are exactly the values gpui measured on an offscreen control (inactive window): 120 degrees, 0.5, -0.1875.
    // Dock: spreadSDR keeps clear's 75°, HDR spread 120°.
    float spreadSDR = inactP ? 120.0 : ((dark || clearFam) ? 75.0 : 106.0);
    float spreadHDR = inactP ? 120.0 : dock ? 120.0 : ((dark || clearV || cc) ? 75.0 : 96.0);
    v.key_fill_highlight_spread = FC(kKfSpread, cos(mix(spreadSDR, spreadHDR, tE) * M_PI_F / 180));
    v.key_fill_highlight_amount = FC(kKfAmount, 1 / (inactP ? 0.5 : 0.4) - 2);
    v.key_fill_highlight_effect_offset = FC(kKfOffset, inBounds ? 0.0 : -kfh);
    float kfBias = pl < 0.5 ? -0.3 : -0.25;
    // Control Center: fixed colorBias -0.3, independent of pixelLength.
    v.key_fill_highlight_color_bias = FC(kKfBias, sidebar ? 0.0 : cc ? -0.3 : (inactP ? 0.75 * kfBias : kfBias));
    // Blur fill (Spec radius 16 -> CA 8, normal 0.5): regular/sidebar Aqua lighten 0.9 / darken 0, dark 0 / 0.9,
    // then RegularDiffusionAmount / SidebarDiffusionAmount. Clear: all 0, slider > 0.5 gives normal 2(a - 0.5)
    // (ClearDiffusionAmount). Aqua regular a = 0 reproduces gpui's measurements (0.675 / 0 / 0).
    float2 ld0 = float2(FC(kFillLight, dark ? 0.0 : 0.9), FC(kFillDark, dark ? 0.9 : 0.0));
    float3 bf = clearFam ? float3(0, 0, slid && diffusion > 0.5 ? clamp(2 * (diffusion - 0.5), 0.0, 1.0) : 0.0)
              : sidebar ? sidebar_diffusion(diffusion, ld0, FC(kFillNormal, 0.5))
              : regular_diffusion(diffusion, ld0, FC(kFillNormal, 0.5));
    v.blur_fill_blur_radius = FC(kFillRadius, kTex * 8.0);
    v.blur_fill_lighten_opacity = bf.x;
    v.blur_fill_darken_opacity = bf.y;
    v.blur_fill_normal_opacity = bf.z;
    v.aberration_amount = 0; v.aberration_dir = 0;

    x.inv_aberration_height = 0; x.aberration_offset = 0;
    x.sdr_white_value = g.sdr_white_value; x.clamp_limit = g.clamp_limit;
    // QuartzCore 27 GlassBackgroundFilter::render (0x18debcee4): m = SDR + (MaxLuma - SDR) t, t = fraction of headroom
    // in use (SDR display: 0), complement = 1 - m. RegularBase.Base: Aqua MaxLumaSDR 0.94, dark = MaxLuma =
    // clampedLinear(x; 64..104 -> 0.6..0.35). t = tE (kHeadroom / kMaxHeadroom, default SDR).
    // Dark with slider < 0.5: RegularDiffusionAmount (0x195f233c0..0x195f2342c) pulls MaxLuma toward
    // clampedLinear(x; 64..104 -> 0.6..0.45) with weight 1 - w, w = clamp(2a, 0, 1).
    float maxLumaDark = clamped_linear(xs, 64, 104, 0.6, 0.35);
    if (dark && slid && diffusion < 0.5) {
        float w = clamp(2 * diffusion, 0.0, 1.0);
        maxLumaDark = clamped_linear(xs, 64, 104, 0.6, 0.45) * (1 - w) + maxLumaDark * w;
    }
    // (MaxLuma, MaxLumaSDR): regular light (1, 0.94), dark (f, f); clear (1, 1); sidebar light (0.85, 0.85),
    // dark (1, 1). m = SDR + (MaxLuma - SDR) tE, complement = 1 - m (assuming ceiling s12 = 1).
    // Dock: dark (0.75, 0.75), light keeps clear's (1, 1).
    float2 ml = dock ? float2(dark ? 0.75 : 1.0) : (clearV || cc) ? float2(1) : sidebar ? float2(dark ? 1.0 : 0.85)
              : (dark ? float2(maxLumaDark) : float2(1, 0.94));
    x.face_color_matrix_max_luma_complement = FC(kMaxLumaComp, 1 - (ml.y + (ml.x - ml.y) * tE));
    x.preserve_hue = gg_preserve(g.preserve_hue);
    x.blur_fill_enabled = FC(kBlurFill, true);
    x.stroke_mode = false;
    x.highlight_extension = FC(kHighlightExt, true);
    x.wants_highlight_bias_correction = FC(kBiasCorrect, true);
    // Highlight: regular/menu (0.125, 0.9, 1) + dodge 0.15; clear and Control Center (ClearSpec) (0.15, 1.1, 1) + dodge 0.25;
    // Dock light white 0.9 on ClearSpec (0.15, 0.9, 1, 0.25), dark (0.25, 0.95, 1.2) without dodge.
    hl = (inactP || sidebar) ? float4(-1)
       : dock ? (dark ? float4(0.25, 0.95, 1.2, 0) : float4(0.15, 0.9, 1, 0.25))
       : chiclet ? float4(0.15, 0.85, 1, 0.25)   // ChicletRecipe.Modifier: keyYCC.white = fillYCC.white = 0.85
       : (clearV || cc) ? float4(0.15, 1.1, 1, 0.25)
       : float4(0.125, 0.9, 1, 0.15);
    // Glass carrying an app recipe code: the app has written the 27 values into the shared keys and QuartzCore converted
    // them to uniforms (texel units, inverse heights, face/bleed matrices, blur opacity differences). Copy that group from
    // the uniforms; the code above is then only used for the 27-only group (ring, darkSpecular, blur fill, max luma,
    // highlight). Keys written by the app: ggapp/Legibility/Recipe27.h.
    if (gg_app_code(g.preserve_hue)) {
        v.inner_refraction_amount = g.inner_refraction_amount; v.inner_refraction_inv_height = g.inner_refraction_inv_height;
        v.outer_refraction_amount = g.outer_refraction_amount; v.outer_refraction_inv_height = g.outer_refraction_inv_height;
        v.blur_radius = g.blur_radius;
        v.edge_bleed_amount = g.edge_bleed_amount; v.edge_bleed_inv_height = g.edge_bleed_inv_height;
        v.shadow_inv_radius = g.shadow_inv_radius;
        v.face_cm0 = g.face_cm0; v.face_cm1 = g.face_cm1; v.face_cm2 = g.face_cm2;
        v.bleed_cm0 = g.bleed_cm0; v.bleed_cm1 = g.bleed_cm1; v.bleed_cm2 = g.bleed_cm2;
        v.blur_alpha0 = g.blur_alpha0; v.blur_alpha1 = g.blur_alpha1; v.blur_alpha2 = g.blur_alpha2; v.blur_alpha3 = g.blur_alpha3;
        v.blur_dist0 = g.blur_dist0; v.blur_dist1 = g.blur_dist1; v.blur_dist2 = g.blur_dist2; v.blur_dist3 = g.blur_dist3;
        v.edge_bleed_opacity = bleed ? g.edge_bleed_opacity : 0.0;
        v.shadow_opacity = g.shadow_opacity;
        v.refraction_opacity = g.refraction_opacity;
    }
    // Show/hide animation (t < 1): the 27 glass of the target recipe following the rule QuartzCore uses to interpolate
    // filter inputs (measured on a 26.6 dump): face linear from identity, refraction (amount, height) and edge bleed linear,
    // blur B t (2 - t). The 27-only effects (dark rim, ring, blur fill, luminance compression) also run linearly; the
    // highlight is multiplied by t in the entry.
    // Simplification: assumes 27 animates the same inputs the same way; no 27 video yet to compare frame by frame.
    if (t < 1) {
        float ti = 1 / fmax(t, 1e-3);
        v.blur_radius *= t * (2 - t);
        v.inner_refraction_amount *= t; v.inner_refraction_inv_height *= ti;
        v.outer_refraction_amount *= t; v.outer_refraction_inv_height *= ti;
        v.edge_bleed_amount *= t; v.edge_bleed_inv_height *= ti;
        v.face_cm0 = half4(mix(float4(1, 0, 0, 0), float4(v.face_cm0), t));
        v.face_cm1 = half4(mix(float4(0, 1, 0, 0), float4(v.face_cm1), t));
        v.face_cm2 = half4(mix(float4(0, 0, 1, 0), float4(v.face_cm2), t));
        v.blur_fill_lighten_opacity *= t; v.blur_fill_darken_opacity *= t; v.blur_fill_normal_opacity *= t;
        v.key_fill_highlight_color_bias *= t;
        v.ring_shadow_opacity *= t;
        x.face_color_matrix_max_luma_complement *= t;
    }
}

static float kf_lobe(float z, float fw, float h, float facing, float spread, float radial);

// source_texture texels per SDF point: displacement_mat row 0 = uv x per point (for any rotation).
static float texels_per_point(texture2d<float> tex, GlassBackgroundUniforms g) {
    return float(tex.get_width()) * length(g.displacement_mat.xy);
}

// The 27 highlight layer (CASDFKeyFillHighlightEffect + vibrant_color_matrix_sover, like kf_highlight_vibrant in section 4)
// drawn directly in the glass shader: WindowServer 26.6 has this layer but 26.6 leaves its alpha at 0. d, n: the glass
// SDF and outward normal (sdf space, y up); dst: premultiplied glass color (close to the composited framebuffer in the
// glass interior, where the glass is nearly opaque). The shape is the same for every kind: key/fill alpha 1, height 1,
// amount 0.5, curvature 0.75, spread clampedLinear(xs; 96..192 -> 80..90°), diffuse lobe height x8, spread x0.65, amount
// x0.15; gain 1.2 scales the matrix and clamp threshold by 1.2^(1/2.2). Key and fill share alpha, so the normal's sign
// does not matter, only the vertical axis.
// noHighlight27 (constant 50, on-machine A/B test): disables this highlight to tell whether the white rim on the Settings
// toolbar button edge is ours or another layer drawn over it.
constant bool  kNoHighlight27 [[function_constant(50)]];
static float4 gg27_highlight(float4 dst, float d, float2 n, float xs, float4 ycc, bool inBounds) {
    if (is_function_constant_defined(kNoHighlight27) && kNoHighlight27) return dst;
    // kInBounds moves the dark rim (kfh, about 1 px) from outside the edge to inside; the highlight is inset with it so the
    // gray rim stays outermost as in 27 instead of being covered by the bright line at the top/bottom edges.
    float pl = FC(kPixelLength, 0.5);
    float z = -d - (inBounds ? (pl < 0.5 ? 1.6 * pl : pl) : 0.0);
    float fw = fmax(fwidth(z), 1e-4);
    float spread = (80 + 10 * saturate((xs - 96) / 96)) * M_PI_F / 180;
    float cs = cos(spread), dcs = cos(spread * 0.65);
    float facing = n.y;
    float tk = saturate(z);
    float rk = mix(tk < 1 ? 1.0 : 0.0, 1 - tk, 0.75);
    float key  = kf_lobe(z, fw, 1.0, facing, cs, rk);
    float fill = kf_lobe(z, fw, 1.0, -facing, cs, rk);
    float rd = 1 - saturate(z / 8.0);
    float dkey  = kf_lobe(z, fw, 8.0, facing, dcs, rd);
    float dfill = kf_lobe(z, fw, 8.0, -facing, dcs, rd);
    if (key + fill + dkey + dfill < 1e-6 || z < -5) return dst;
    const float damount = 1 / (0.5 * 0.15) - 2;   // sharp lobe: amount 0.5 -> 1/0.5 - 2 = 0
    float mask = key + dkey / fmax(1 + damount * (1 - dkey), 1e-6) + fill + dfill / fmax(1 + damount * (1 - dfill), 1e-6);
    float gain = pow(1.2, 1 / 2.2);
    float scale = gain / (1 - fmin(ycc.w, 0.996));
    float3 bu = dst.rgb / fmax(dst.a, 1e-6);
    float a = saturate(dst.a);
    float3 mb = (ycc.z * bu + (ycc.y - ycc.x - ycc.z) * dot(float3(0.2126, 0.7152, 0.0722), bu) + ycc.x) * scale;
    float4 c = float4(clamp(mb, -0.75, gain) * a, a) * mask;
    return c + (1 - c.a) * dst;
}

static float4 gg27_core(VOut in, texture2d<float> source_texture, GlassBackgroundUniformsSdf u,
                        float edr_scale, bool bleed, int variant0, bool dark0, bool inact0 = false, float t = 1.0) {
    GlassBackgroundUniforms27 v; GlassBackgroundUniformsExt x; float4 hl;
    float xs = 2 * fmin(u.sdf.arg.x, u.sdf.arg.y);
    gg27_params(u.glass, xs, bleed, variant0, dark0, inact0, v, x, hl, t, texels_per_point(source_texture, u.glass));
    float4 r = base27_inl(in.sdf_uv, in.src_uv, u.sdf, v, x, source_texture, edr_scale, false, FC(kInBounds, !gg27_forced()));
    // Highlight only on the automatic path (WindowServer); the forcing harness draws a separate highlight layer for comparison.
    // During show/hide animations, highlight intensity follows progress t.
    int mode = int(u.sdf.arg.z);
    float4 s = mode > -1 ? compute_sdf_with_mode(in.sdf_uv, mode, u.sdf) : float4(1e9, 0, 0, 0);
    return (hl.w >= 0 && !gg27_forced())
        ? mix(r, gg27_highlight(r, s.x, s.yz, FC(kGlassSize, gg27_size(u.glass, xs)), hl, gg27_in_bounds(u.glass)), t * gg27_hl_gain(u.glass)) : r;
}

// Test-only kernel (glass-harness/classify.swift): the 27 parameter set the automatic path (WindowServer) builds from
// 26.6 uniforms, to compare with forcing via function constants. Fixed 36 point short side.
kernel void test_gg27_params(constant GlassBackgroundUniforms& g [[buffer(0)]],
                             device GlassBackgroundUniforms27* ov [[buffer(1)]],
                             device GlassBackgroundUniformsExt* ox [[buffer(2)]]) {
    bool dark = false, inact = false;
    int variant = classify_glass26(g, dark, inact);
    GlassBackgroundUniforms27 v; GlassBackgroundUniformsExt x; float4 hl;
    gg27_params(g, 36.0, true, max(variant, 0), dark, inact, v, x, hl);
    ov[0] = v; ox[0] = x;
}

// Like test_gg27_params but picks the kind via glass_mode26 (the real WindowServer path, including app recipe codes) and
// also outputs the highlight. Fixed 36 point short side.
kernel void test_gg27_params_auto(constant GlassBackgroundUniforms& g [[buffer(0)]],
                                  device GlassBackgroundUniforms27* ov [[buffer(1)]],
                                  device GlassBackgroundUniformsExt* ox [[buffer(2)]], device float4* ohl [[buffer(3)]]) {
    bool dark = false, inact = false;
    float t = 1;
    int mode = glass_mode26(g, dark, inact, t, -1);
    GlassBackgroundUniforms27 v; GlassBackgroundUniformsExt x; float4 hl;
    gg27_params(g, 36.0, true, max(mode, 0), dark, inact, v, x, hl, t);
    ov[0] = v; ox[0] = x; ohl[0] = hl;
}

// Like test_gg27_params_auto, with the short side taken from buffer(4).
kernel void test_gg27_params_auto_x(constant GlassBackgroundUniforms& g [[buffer(0)]],
                                    device GlassBackgroundUniforms27* ov [[buffer(1)]],
                                    device GlassBackgroundUniformsExt* ox [[buffer(2)]], device float4* ohl [[buffer(3)]],
                                    constant float& xs [[buffer(4)]]) {
    bool dark = false, inact = false;
    float t = 1;
    int mode = glass_mode26(g, dark, inact, t, -1);
    GlassBackgroundUniforms27 v; GlassBackgroundUniformsExt x; float4 hl;
    gg27_params(g, xs, true, max(mode, 0), dark, inact, v, x, hl, t);
    ov[0] = v; ox[0] = x; ohl[0] = hl;
}

// Recipe decoding: recipe, inactive, flag, a, dark (gg_code_dark), valid.
kernel void test_decode_recipe(constant float& p [[buffer(0)]], device float* out [[buffer(1)]]) {
    int r = -1; bool i = false; float f = 0, a = 0;
    bool ok = gg_app_code(p, r, i, f, a);
    out[0] = r; out[1] = i ? 1 : 0; out[2] = f; out[3] = a; out[4] = gg_code_dark(p); out[5] = ok ? 1 : 0;
}

// Entries replacing the Apple functions of the same name (26.6 ABI, see shaders/gg27-entries.txt). Uniforms matching
// no mapped glass kind (kSigs26) without a forcing function constant: keep 26.6 as is (bit-exact copy).
constant bool  kDebugColor   [[function_constant(42)]];  // on-machine diagnostics: color by branch
constant bool  kDebugSize    [[function_constant(45)]];  // diagnostics: color by the short side the adapter uses

// Glass not mapped to a 27 recipe (kSigs26 table) without a forcing function constant: keep 26.6 as is via the
// bit-exact copy (it must look like Golden Gate, not turn everything into clear).
// When the harness forces the kind via function constants, the full 27 recipe is always drawn (no 26.6, no tone keeping).
static bool gg27_forced() {
    return is_function_constant_defined(kVariant) || is_function_constant_defined(kDarkMode);
}

// debugColor: color by 26.6 recipe (kSigs26): 0 green, 1 dark green, 2 blue, 3 dark blue,
// 4 yellow, 5 magenta, 6 teal, 7 orange, 8 dark yellow, 9 white, 10 gray, 11 brown, 12 dark brown, 13 purple;
// no recipe match: red. The texture variant adds diagonal stripes to show where QuartzCore switches between the two paths.
// Colors are premultiplied by alpha.
// debugSize (constant 45): color by the short side xs the adapter uses: < 64 red, 64-160 green, >= 160 blue (27 blur
// changes with xs in 64..160), to see whether the texture variant estimates xs differently from the SDF variant.
/// Debug color index: app recipe code (100 + recipe, +10 inactive), otherwise the 26.6 recipe (kSigs26).
static int gg_debug_sig(GlassBackgroundUniforms g) {
    int rc; bool ia; float f, a;
    return gg_app_code(g.preserve_hue, rc, ia, f, a) ? 100 + min(rc, 6) + (ia ? 10 : 0) : classify_sig26(g);
}
static float4 gg27_debug(float4 r, int sig, bool texPath, float2 pos, float xs) {
    if (is_function_constant_defined(kDebugSize) && kDebugSize) {
        float3 c = xs < 64 ? float3(1, 0, 0) : xs < 160 ? float3(0, 1, 0) : float3(0, 0.3, 1);
        if (texPath && (int(floor((pos.x + pos.y) / 6)) & 1)) c *= 0.55;
        r.rgb = mix(r.rgb, c * r.a, 0.6);
        return r;
    }
    if (!(is_function_constant_defined(kDebugColor) && kDebugColor)) return r;
    // Glass with an app recipe code (sig = 100 + recipe, +10 when inactive): pink regular, light blue clear, mint
    // sidebar, light brown menu, light gray Dock, purple Control Center, cream popover; half as bright when inactive.
    if (sig >= 100) {
        const float3 app[7] = { float3(1, 0.4, 0.7), float3(0.4, 0.6, 1), float3(0.5, 1, 0.8), float3(0.8, 0.6, 0.3),
                                float3(0.9), float3(0.7, 0.3, 1), float3(1, 0.85, 0.6) };
        float3 c = app[min((sig - 100) % 10, 6)] * (sig >= 110 ? 0.5 : 1.0);
        if (texPath && (int(floor((pos.x + pos.y) / 6)) & 1)) c *= 0.55;
        r.rgb = mix(r.rgb, c * r.a, 0.6);
        return r;
    }
    const float3 cols[kNumSigs26] = { float3(0, 1, 0), float3(0, 0.45, 0), float3(0, 0.3, 1), float3(0, 0, 0.45),
                             float3(1, 0.9, 0), float3(1, 0, 0.8), float3(0, 0.9, 0.9), float3(1, 0.5, 0),
                             float3(0.6, 0.55, 0), float3(1), float3(0.5), float3(0.55, 0.3, 0.1),
                             float3(0.3, 0.15, 0.05), float3(0.5, 0, 1),
                             float3(0.6, 0, 0.3), float3(0.8, 0.3, 0.5), float3(0.4, 0, 0.6),
                             float3(0.3, 1, 0.6), float3(0.15, 0.5, 0.3) };   // 17, 18 sidebar: mint, dark mint
    float3 c = sig < 0 ? float3(1, 0, 0) : cols[sig];
    if (texPath && (int(floor((pos.x + pos.y) / 6)) & 1)) c *= 0.55;
    r.rgb = mix(r.rgb, c * r.a, 0.6);
    return r;
}

// debugEdge (constant 48): solid fill by SDF distance d (points) at pixels we draw, ignoring the glass color: purple for
// the 27 dark ring band (-1 <= d < 0), green interior, blue outside the edge but still drawn (shadow, refraction), yellow
// for empty texels (w = 0). The texture variant is striped. On the machine: if the outermost button pixel is purple but
// still looks white, something draws over it; if it is not purple, the distance read is off. Discarded pixels keep the
// background.
constant bool  kDebugEdge    [[function_constant(48)]];
constant bool  kDebugScale   [[function_constant(49)]];   // diagnoses sdf_texture texels/point (gg27_tex_entry)
static float4 gg27_debug_edge(float4 r, float d, float w, bool texPath, float2 pos) {
    if (!(is_function_constant_defined(kDebugEdge) && kDebugEdge)) return r;
    float3 c = w <= 1e-4 ? float3(1, 0.9, 0) : d < -1 ? float3(0, 1, 0) : d < 0 ? float3(1, 0, 1) : float3(0, 0.3, 1);
    if (texPath && (int(floor((pos.x + pos.y) / 6)) & 1)) c *= 0.6;
    return float4(c, 1);
}

static float4 gg27_entry(VOut in, texture2d<float> tex, GlassBackgroundUniformsSdf u, float edr, bool bleed, int sys = -1,
                         float live = -1) {
    u.glass.preserve_hue = gg_fold_tint(u.glass.preserve_hue, live);
    bool dark = false, inact = false, forced = gg27_forced();
    float t = 1;
    int mode = glass_mode26(u.glass, dark, inact, t, sys);
    float4 r = (mode == -2 && !forced) ? replica_sdf(in, tex, u, edr, bleed)
             : gg27_core(in, tex, u, edr, bleed, max(mode, 0), dark, inact, forced ? 1.0 : t);
    r = gg27_debug(r, gg_debug_sig(u.glass), false, in.position.xy, 2 * fmin(u.sdf.arg.x, u.sdf.arg.y));
    float4 sd = compute_sdf_with_mode(in.sdf_uv, int(u.sdf.arg.z), u.sdf);
    return gg27_debug_edge(r, sd.x, 1, false, in.position.xy);
}

// Texture SDF variant. No shape parameters: the glass short side is estimated from sdf_texture around the pixel (glass_size_tex).
// Simplification: exact for capsules/rounded rectangles; for concave shapes (Dock while magnifying) or near rounded corners the
// estimate may vary slightly between pixels.
static float4 gg27_tex_entry(TexVOut in, texture2d<float> tex, texture2d<float> sdft, GlassBackgroundUniforms g,
                             float edr, bool bleed, int sys = -1, float live = -1) {
    g.preserve_hue = gg_fold_tint(g.preserve_hue, live);
    bool dark = false, inact = false, forced = gg27_forced();
    float t = 1;
    int mode = glass_mode26(g, dark, inact, t, sys);
    if (forced) t = 1;
    float4 r;
    float2 a = dfdx(in.texcoord0), b = dfdy(in.texcoord0), c = dfdx(in.texcoord1), e = dfdy(in.texcoord1);
    // Distance units per point. Every pixel: texels/point from screen derivatives (sdf_texture distances are in texels,
    // sdf-capture: slope ~1 per texel). Near the edge (6 points): the SDF's own slope at the pixel if measurable (the SDF
    // slopes 1 per unit), in case units are not exactly texels; deep inside, the SDF kinks at the medial axis, so the slope
    // is not used there.
    // Simplification: with units other than texels only the band near the edge is right; the interior short side estimate is
    // still off by that ratio.
    // Simplification: points per pixel come from the pixelLength setting (1 on a 1x display); HiDPI displays must set it correctly.
    float pl = FC(kPixelLength, 0.5);
    float k = sdf_texels_per_point(sdft, c, e, pl);
    float4 s0 = sdft.sample(kSdfSmp, in.texcoord1);
    float gpt = length(float2(dfdx(s0.x), dfdy(s0.x))) / pl;
    // Inside the shape up to 6 points from the edge, outside up to 1 point: the 27 rim/highlight band lies inside the edge
    // (kInBounds); outside the edge near the empty SDF boundary (empty texel x = 0) finite differences jump (the 4 point band
    // case was off by 3/255 at 3.6 points outside the edge).
    bool nearEdge = s0.w > 1e-4 && s0.x > -6 * k && s0.x < k;
    // Only replace k when the slope differs clearly (> 15%): finite differences on curved edges (rounded ends) are slightly
    // off, so using them always adds noise (the atlas case was off by 5/255 in 3 channels).
    float kEdge = nearEdge && isfinite(gpt) && gpt > 0.05 && fabs(gpt / k - 1) > 0.15 ? clamp(gpt, 0.125, 64.0) : k;
    float xs = glass_size_tex(sdft, in.texcoord1, s0, g.displacement_mat, a, b, c, e, k) / k;
    if (mode == -2 && !forced) r = replica_tex(in, tex, sdft, g, edr, bleed);
    else {
        GlassBackgroundUniforms27 v; GlassBackgroundUniformsExt x; float4 hl;
        gg27_params(g, xs, bleed, max(mode, 0), dark, inact, v, x, hl, t, texels_per_point(tex, g));
        r = base27_tex(in.texcoord0, in.texcoord1, sdft, v, x, tex, edr, 2 * pl, kEdge, FC(kInBounds, !gg27_forced()));
        // Raw sample (no 1e4 substitution: the jump inflates fwidth and the lobe becomes 0.5 at the SDF boundary); empty
        // texels drop the highlight via a select after computing, so derivatives stay uniform within the quad.
        if (hl.w >= 0 && !forced) {
            float4 h = gg27_highlight(r, s0.x / kEdge, s0.yz, FC(kGlassSize, gg27_size(g, xs)), hl, gg27_in_bounds(g));
            r = s0.w > 1e-4 ? mix(r, h, t * gg27_hl_gain(g)) : r;
        }
    }
    r = gg27_debug(r, gg_debug_sig(g), true, in.position.xy, xs);
    // debugScale (constant 49): the glass interior writes R = texels/point from screen derivatives, G = |d(s.x)/dx|,
    // B = |d(s.x)/dy| per point (each channel / 4); black outside the edge.
    float gx = fabs(dfdx(s0.x)) / pl, gy = fabs(dfdy(s0.x)) / pl;
    if (is_function_constant_defined(kDebugScale) && kDebugScale)
        return s0.x < 0 && s0.w > 1e-4 ? float4(saturate(float3(k, gx, gy) / 4), 1) : float4(0, 0, 0, 1);
    return gg27_debug_edge(r, s0.x / kEdge, s0.w, true, in.position.xy);
}

fragment float4 gg27_glass_background_lpf(TexVOut in [[stage_in]],
                                          texture2d<float> source_texture [[texture(3)]],
                                          texture2d<float> sdf_texture [[texture(4)]],
                                          constant GlassBackgroundUniforms& u [[buffer(1)]],
                                          constant float& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return gg27_tex_entry(in, source_texture, sdf_texture, u, edr_scale, true, GG_SYS, GG_LIVE_TINT);
}

fragment float4 gg27_glass_background_no_bleed_lpf(TexVOut in [[stage_in]],
                                                   texture2d<float> source_texture [[texture(3)]],
                                                   texture2d<float> sdf_texture [[texture(4)]],
                                                   constant GlassBackgroundUniforms& u [[buffer(1)]],
                                                   constant float& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return gg27_tex_entry(in, source_texture, sdf_texture, u, edr_scale, false, GG_SYS, GG_LIVE_TINT);
}

fragment float4 gg27_glass_background_sdf_lpf(VOut in [[stage_in]],
                                              texture2d<float> source_texture [[texture(3)]],
                                              constant GlassBackgroundUniformsSdf& u [[buffer(1)]],
                                              constant float& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return gg27_entry(in, source_texture, u, edr_scale, true, GG_SYS, GG_LIVE_TINT);
}

fragment float4 gg27_glass_background_sdf_no_bleed_lpf(VOut in [[stage_in]],
                                                       texture2d<float> source_texture [[texture(3)]],
                                                       constant GlassBackgroundUniformsSdf& u [[buffer(1)]],
                                                       constant float& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return gg27_entry(in, source_texture, u, edr_scale, false, GG_SYS, GG_LIVE_TINT);
}

// 26.6's _lph variants (chosen by QuartzCore on this Intel GPU): same as _lpf up to offset 156, fields from 160 are
// half (per glass_background_sdf_lph's air.struct_type_info), edr_scale is half, returns half4.
struct GlassBackgroundUniformsH {       // 224 bytes
    float4 displacement_mat;
    float  inner_refraction_amount, inner_refraction_inv_height, outer_refraction_amount, outer_refraction_inv_height;
    float  refraction_threshold0, refraction_threshold1, blur_radius, edge_bleed_blur_radius;
    float  edge_bleed_amount, edge_bleed_inv_height, shadow_amount, shadow_inv_height;
    float2 shadow_offset;
    float  shadow_blur_radius, shadow_inv_radius;
    half4  face_cm0, face_cm1, face_cm2, bleed_cm0, bleed_cm1, bleed_cm2, shadow_cm0, shadow_cm1, shadow_cm2;
    float  shadow_contribution, shadow_face_opacity;
    half   blur_alpha0, blur_alpha1, blur_alpha2, blur_alpha3, blur_dist0, blur_dist1, blur_dist2, blur_dist3;
    half   edge_bleed_dist0, edge_bleed_dist1, edge_bleed_opacity, face_opacity;
    half2  bleed_darken;
    half   shadow_dist_offset, shadow_opacity, refraction_opacity, holding_tone_opacity;
    half   sdr_shadow_dist0, sdr_shadow_dist1, clamp_limit, preserve_hue, sdr_white_value, x86_workaround, complex_refraction;
};
struct GlassBackgroundUniformsSdfH { SdfFragmentUniforms sdf; GlassBackgroundUniformsH glass; };   // 272 byte
static_assert(sizeof(GlassBackgroundUniformsSdfH) == 272, "GlassBackgroundUniformsSdfH 272 byte");
static_assert(OFF(GlassBackgroundUniformsH, blur_alpha0) == 160, "blur_alpha0 @160");
static_assert(OFF(GlassBackgroundUniformsH, bleed_darken) == 184, "bleed_darken @184");
static_assert(OFF(GlassBackgroundUniformsH, x86_workaround) == 206, "x86_workaround @206");

static GlassBackgroundUniformsSdf to_float(GlassBackgroundUniformsSdfH h) {
    GlassBackgroundUniformsH g = h.glass;
    GlassBackgroundUniformsSdf u;
    u.sdf = h.sdf;
    u.glass.displacement_mat = g.displacement_mat;
    u.glass.inner_refraction_amount = g.inner_refraction_amount; u.glass.inner_refraction_inv_height = g.inner_refraction_inv_height;
    u.glass.outer_refraction_amount = g.outer_refraction_amount; u.glass.outer_refraction_inv_height = g.outer_refraction_inv_height;
    u.glass.refraction_threshold0 = g.refraction_threshold0; u.glass.refraction_threshold1 = g.refraction_threshold1;
    u.glass.blur_radius = g.blur_radius; u.glass.edge_bleed_blur_radius = g.edge_bleed_blur_radius;
    u.glass.edge_bleed_amount = g.edge_bleed_amount; u.glass.edge_bleed_inv_height = g.edge_bleed_inv_height;
    u.glass.shadow_amount = g.shadow_amount; u.glass.shadow_inv_height = g.shadow_inv_height;
    u.glass.shadow_offset = g.shadow_offset; u.glass.shadow_blur_radius = g.shadow_blur_radius; u.glass.shadow_inv_radius = g.shadow_inv_radius;
    u.glass.face_cm0 = g.face_cm0; u.glass.face_cm1 = g.face_cm1; u.glass.face_cm2 = g.face_cm2;
    u.glass.bleed_cm0 = g.bleed_cm0; u.glass.bleed_cm1 = g.bleed_cm1; u.glass.bleed_cm2 = g.bleed_cm2;
    u.glass.shadow_cm0 = g.shadow_cm0; u.glass.shadow_cm1 = g.shadow_cm1; u.glass.shadow_cm2 = g.shadow_cm2;
    u.glass.shadow_contribution = g.shadow_contribution; u.glass.shadow_face_opacity = g.shadow_face_opacity;
    u.glass.blur_alpha0 = g.blur_alpha0; u.glass.blur_alpha1 = g.blur_alpha1; u.glass.blur_alpha2 = g.blur_alpha2; u.glass.blur_alpha3 = g.blur_alpha3;
    u.glass.blur_dist0 = g.blur_dist0; u.glass.blur_dist1 = g.blur_dist1; u.glass.blur_dist2 = g.blur_dist2; u.glass.blur_dist3 = g.blur_dist3;
    u.glass.edge_bleed_dist0 = g.edge_bleed_dist0; u.glass.edge_bleed_dist1 = g.edge_bleed_dist1;
    u.glass.edge_bleed_opacity = g.edge_bleed_opacity; u.glass.face_opacity = g.face_opacity;
    u.glass.bleed_darken = float2(g.bleed_darken);
    u.glass.shadow_dist_offset = g.shadow_dist_offset; u.glass.shadow_opacity = g.shadow_opacity;
    u.glass.refraction_opacity = g.refraction_opacity; u.glass.holding_tone_opacity = g.holding_tone_opacity;
    u.glass.sdr_shadow_dist0 = g.sdr_shadow_dist0; u.glass.sdr_shadow_dist1 = g.sdr_shadow_dist1;
    u.glass.clamp_limit = g.clamp_limit; u.glass.preserve_hue = g.preserve_hue; u.glass.sdr_white_value = g.sdr_white_value;
    u.glass.x86_workaround = g.x86_workaround; u.glass.complex_refraction = g.complex_refraction;
    return u;
}

// Simplification: the fallback (unknown uniforms) computes in float like the _lpf variant, while Apple's _lph partly computes in
// half, so there is a small difference (measured by compare.swift with a tolerance). Textures are read as float (the same
// texture QuartzCore binds).
fragment half4 gg27_glass_background_sdf_lph(VOut in [[stage_in]],
                                             texture2d<float> source_texture [[texture(3)]],
                                             constant GlassBackgroundUniformsSdfH& u [[buffer(1)]],
                                             constant half& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return half4(gg27_entry(in, source_texture, to_float(u), float(edr_scale), true, GG_SYS, GG_LIVE_TINT));
}

fragment half4 gg27_glass_background_sdf_no_bleed_lph(VOut in [[stage_in]],
                                                      texture2d<float> source_texture [[texture(3)]],
                                                      constant GlassBackgroundUniformsSdfH& u [[buffer(1)]],
                                                      constant half& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return half4(gg27_entry(in, source_texture, to_float(u), float(edr_scale), false, GG_SYS, GG_LIVE_TINT));
}

// Texture _lph variant: GlassBackgroundUniformsH uniforms (224 bytes, half from offset 160), half edr, returns half4.
static GlassBackgroundUniforms to_float(constant GlassBackgroundUniformsH& g) {
    GlassBackgroundUniformsSdfH h; h.glass = g;
    return to_float(h).glass;
}

fragment half4 gg27_glass_background_lph(TexVOut in [[stage_in]],
                                         texture2d<float> source_texture [[texture(3)]],
                                         texture2d<float> sdf_texture [[texture(4)]],
                                         constant GlassBackgroundUniformsH& u [[buffer(1)]],
                                         constant half& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return half4(gg27_tex_entry(in, source_texture, sdf_texture, to_float(u), float(edr_scale), true, GG_SYS, GG_LIVE_TINT));
}

fragment half4 gg27_glass_background_no_bleed_lph(TexVOut in [[stage_in]],
                                                  texture2d<float> source_texture [[texture(3)]],
                                                  texture2d<float> sdf_texture [[texture(4)]],
                                                  constant GlassBackgroundUniformsH& u [[buffer(1)]],
                                                  constant half& edr_scale [[buffer(6)]] GG_APPEARANCE_ARG) {
    return half4(gg27_tex_entry(in, source_texture, sdf_texture, to_float(u), float(edr_scale), false, GG_SYS, GG_LIVE_TINT));
}

// Replaces the 26.6 highlight layer: QuartzCore's fixed_frag_* uber shader with constant 28 (fc_texture_function) = 66
// (UberShader::sdf_key_fill_highlight, AIR 26.6 module m004). That layer is white alpha 1 when the window is key and draws
// over the glass edge, covering the 27 dark ring; the 27 highlight is already drawn in the glass shader (gg27_highlight).
// Writes no pixels.
fragment half4 gg_no_kf_highlight() {
    discard_fragment();
    return half4(0);
}

// =====================================================================================
// 4. 27's separate highlight layer: CASDFKeyFillHighlightEffect (variant with a diffuse lobe)
//    + vibrantColorMatrix filter (source-over). Transcribed from AIR 27.2.1, module UberShader<float,float>:
//    UberShader::sdf_diffuse_kf_highlight and UberShader::vibrant_color_matrix_sover.
//    The glass background (sections 2, 3) is drawn first; this pass reads that result as its backdrop.
// =====================================================================================
struct KFHighlightUniforms {        // parameters already converted to shader form (CA::OGL::SDFNode::apply):
    float2 half_size; float radius; // capsule shape (sdf_uv, points)
    float  key_alpha, fill_alpha;   // key/fill color alpha (RGB unused: vibrant sover only takes the alpha mask)
    float  height, spread, amount;  // sharp lobe: height pt, cos(spread), 1/CA_amount - 2
    float  curvature, offset;       // sharp region curvature, effect offset
    float  d_height, d_spread, d_amount;  // diffuse lobe: height*diffuseHeightScale, cos(spread*diffuseSpreadScale), 1/(amount*diffuseAmountScale) - 2
    float  clamp_max;               // vibrant filter maxColorComponent = max(gain, 1)
    float2 dir;                     // (sin(angle), -cos(angle)) of key; fill uses the opposite direction
    float4 m_r, m_g, m_b;           // vibrant matrix: rows (R, G, B coefficients, bias)
};

// Analytic capsule/rounded rect SDF (negative inside) and outward normal.
static float2 harness_rrect_sdf(float2 p, float2 b, float r, thread float2& n) {
    float2 q = fabs(p) - (b - r);
    float2 s = float2(p.x < 0 ? -1.0 : 1.0, p.y < 0 ? -1.0 : 1.0);
    if (q.x > 0 && q.y > 0) n = normalize(q) * s;
    else n = q.x > q.y ? float2(s.x, 0) : float2(0, s.y);
    return float2(length(fmax(q, 0.0)) + fmin(fmax(q.x, q.y), 0.0) - r, 0);
}

// One lobe: radial part by depth z, AA on both edges, direction gate; returned before the rational curve.
static float kf_lobe(float z, float fw, float h, float facing, float spread, float radial) {
    float aa = saturate(z / fw + 0.5) * saturate((h - z) / fw + 0.5);
    return radial * aa * saturate((facing - spread) / fmax(1 - spread, 1e-6));
}

fragment float4 kf_highlight_vibrant(VOut in [[stage_in]],
                                     texture2d<float> backdrop [[texture(0)]],
                                     constant KFHighlightUniforms& u [[buffer(1)]]) {
    float2 n;
    float d = harness_rrect_sdf(in.sdf_uv, u.half_size, u.radius, n).x;
    float z = -(d + u.offset);                       // depth into the surface
    float fw = fmax(fwidth(z), 1e-4);
    float facing = dot(u.dir, n);
    // Sharp lobe: radial = mix(z < h ? 1 : 0, 1 - z/h, curvature).
    float tk = saturate(z / u.height);
    float rk = mix(tk < 1 ? 1.0 : 0.0, 1 - tk, u.curvature);
    float key  = kf_lobe(z, fw, u.height, facing,  u.spread, rk);
    float fill = kf_lobe(z, fw, u.height, -facing, u.spread, rk);
    // Diffuse lobe: linear radial 1 - z/h.
    float rd = 1 - saturate(z / u.d_height);
    float dkey  = kf_lobe(z, fw, u.d_height, facing,  u.d_spread, rd);
    float dfill = kf_lobe(z, fw, u.d_height, -facing, u.d_spread, rd);
    if (key + fill + dkey + dfill < 1e-6 || z < -5) discard_fragment();
    float mask = (key / fmax(1 + u.amount * (1 - key), 1e-6) + dkey / fmax(1 + u.d_amount * (1 - dkey), 1e-6)) * u.key_alpha
               + (fill / fmax(1 + u.amount * (1 - fill), 1e-6) + dfill / fmax(1 + u.d_amount * (1 - dfill), 1e-6)) * u.fill_alpha;

    // vibrant_color_matrix_sover: matrix on the unpremultiplied backdrop, clamped to [-0.75, clamp_max], times the alpha
    // mask, source-over. The matrix is built by DesignLibrary 27.2.1 (0x195eac290..0x195eac15c) from highlights.key.ycc
    // (computed on the host, see group.swift vibrantRows). Regular: YCC(0.125, 0.9, 1) + dodge 0.15, matching gpui's 27.0 measurements.
    float4 dst = backdrop.read(uint2(in.position.xy));
    float3 bu = dst.rgb / fmax(dst.a, 1e-6);
    float a = saturate(dst.a);
    float3 mb = float3(dot(u.m_r.xyz, bu) + u.m_r.w, dot(u.m_g.xyz, bu) + u.m_g.w, dot(u.m_b.xyz, bu) + u.m_b.w);
    float3 t = clamp(mb, -0.75, u.clamp_max) * a;
    float4 c = float4(t, a) * mask;
    return c + (1 - c.a) * dst;
}
