// GGLegibility.dylib: the macOS 27 glass transparency slider path rebuilt on 26.6.
// Foundation/QuartzCore/SkyLight only, no AppKit/SwiftUI, so it can also load into the Dock.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Slider amount code in the CAFilter key inputClampPreserveHue: P = 2 + 2 round(clamp(a, 0, 1) 1000) + (flag & 1).
int32_t gg_tint_encode(float a, int32_t flag);
/// Code that also carries the glass appearance (negative): P = -(2 + 4 round(clamp(a) 500) + 2 (dark & 1) + (flag & 1)).
/// The largest magnitude 2005 < 2048, so the _lph variant (preserve_hue as half) still keeps every integer exactly.
int32_t gg_tint_encode_app(float a, int32_t flag, int32_t dark);
/// |P| >= 2: writes a and the original preserve flag, returns true. -2 < P < 2 is an original Apple value.
bool gg_tint_decode(int32_t p, float *a, int32_t *flag);
/// Appearance carried by the code: 1 dark, 0 light, -1 unknown (positive code or Apple value).
int32_t gg_tint_appearance(int32_t p);

/// NSGlassTintAmount in the global domain (default 0.5), like 27 NSGlassEffectView.Legibility.systemLegibility().
float GGGlassSystemLegibility(void);
/// Re-reads NSGlassTintAmount, compares with the applied value, stores it, returns whether it changed
/// (27 +[NSGlassEffectView _legibilityNeedsUpdate]).
bool gg_legibility_needs_update(void);
/// Value applied in this process.
float gg_legibility_current(void);

/// Installs the -[CALayer setFilters:] hook (injects the code into every glassBackground filter) and the notification
/// receiver. Safe to call again.
void gg_legibility_install(void);
/// Rewrites the code on every glassBackground filter in the process CAContexts (committed in one CATransaction):
/// the 27 "recompute recipe then commit" step.
void gg_legibility_recommit(void);

/// Like 27 NSGlassEffectView.Legibility.setSystemLegibility(_:completionHandler:): writes NSGlassTintAmount (reset: deletes
/// the key) to the global domain, then posts a type 12 coordinated notification with a fence through WindowServer. Returns 0
/// when WindowServer accepts it, -1 when it rejects it at once (type 12 while unpatched; SkyLight returns no specific error
/// code). completion: 0 when every app reports done, -1 when rejected. GG_PREFS_WRITE: plist replacing the global domain;
/// GG_TINT_NOPOST: do not post.
int GGGlassSetSystemLegibility(float a, bool reset, void (^completion)(int err));
/// Like 27 previewSystemLegibility(_:) (AppKit 0x18b31ef24): writes NSGlassTintAmount and only the calling process applies
/// it (local post of NSGlassEffectDiffusionDidChangeNotification, rewrites the glass code), no broadcast to other apps.
/// Used while dragging the slider.
void GGGlassPreviewSystemLegibility(float a, bool reset);
/// Like 27 commitSystemLegibility(completionHandler:) (0x18b31efc8): posts a type 12 coordinated notification with the value
/// written during preview. Used on slider release. Return value and completion as GGGlassSetSystemLegibility.
int GGGlassCommitSystemLegibility(void (^completion)(int err));
/// Test only: delivers a payload the way SkyLight delivers it to the CGSNotificationType 0x528 receiver.
void gg_legibility_test_receive(const void *data, uint32_t len);

#ifdef __cplusplus
}
#endif
