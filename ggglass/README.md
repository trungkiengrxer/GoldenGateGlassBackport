# GGGlass

A userspace dylib loaded into WindowServer that replaces QuartzCore 26.6's (25G72) glass shaders with an adapter of the macOS 27 algorithm in `glass-harness/shaders/glass26_replica.metal`.

Install it with the package in `installer/` (see the root README). This directory only builds and tests the dylib and its control tool.

## Components

| File | Role |
|---|---|
| `Sources/GGGlass/GGGlass.m` | Swizzles the function-creation APIs of `MTLLibrary`. Glass function names in the replacement table return our functions, everything else keeps Apple's |
| `build.sh` | Builds `build/GGGlass.dylib` (x86_64, ad-hoc signed), `build/gg27.metallib` (precompiled shader) and `build/ggtint` |
| `ggglass` | Control tool: `tint`, `off`, `on`, `status` |
| `tools/ggtint/ggtint.m` | Writer side of the transparency slider (like 27's `setSystemLegibility`) |
| `tests/run-tests.sh` | Tests the dylib with the `tests/host.m` process, which does exactly what QuartzCore does |
| `tests/cli.sh` | Tests the `ggglass` tool |
| `tests/carender.swift` | Exercises the QuartzCore path with `CARenderer`. Result: the glass filter does not run, but the trace shows QuartzCore requesting the `_lph` variants on this Intel GPU |

## Replaced functions

`glass_background_{sdf_,}{,no_bleed_}{lpf,lph}`: 8 functions, covering the precomputed SDF variant and the variant reading the SDF from a texture. Same list as `glass-harness/shaders/gg27-entries.txt`. QuartzCore uses both variants for the same glass (the texture one while the shape changes and for large glass), so both must be replaced, otherwise the glass flickers.

- The shader recognizes the 14 face recipes of 26.6 (`kSigs26`) and draws the matching Golden Gate recipe: regular active/inactive, clear, Dock (27 `DockRecipe`), inactive menu. Plus two `SidebarRecipe` 27 face signatures sent by ggapp (`GGApp.sidebarGlass`) for sidebar glass -> 27 sidebar.
- Glass carrying an **app recipe code** (`|inputClampPreserveHue| >= 2048`, ggapp `Legibility/Recipe.m`): the app has already written the real 27 values into the shared keys; the shader does not guess the kind, takes the shared group from the uniforms and only computes the 27-only group (ring, darkSpecular, blur fill, max luma, highlight) from the code (recipe 0..6: regular, clear, sidebar, menu, Dock, Control Center, popover with arrow; inactive; light/dark; slider). GGGlass sets notify state `com.goldengate.glass.abi` = 2 when enabled so ggapp knows the shader understands the codes; otherwise ggapp writes nothing new.
- Adaptive glass (#5, #6, #7 and any face that does not match: buttons, playback bars): full 27 regular.
- Mac Control Center (#14): 27 `ControlCenterRecipe` (kVariant 5). Clear base (#13): 27 clear.
- Show/hide animations (face interpolated from identity to a recipe): 27 glass of the target recipe, following progress.
- Pad/phone Control Center (#15, #16, not on Mac): **kept as 26.6** via a bit-exact copy.
- The texture variant finds the glass short side by searching the SDF minimum along an inward ray (`sdf_texture` is an atlas, the texture center may not belong to the glass); harness test: for the same glass, the texture variant differs from the SDF variant by at most 2/255.
- The 26.6 highlight layer (`CASDFKeyFillHighlightEffect`, white alpha 1 when the window is key, drawn over the glass edge): the `fixed_frag_*` uber shader with constant 28 = 66 is replaced by `gg_no_kf_highlight` (draws nothing), and the same draw through the generic uber shader is skipped. The 27 highlight is drawn in the glass shader.

## Usage

```bash
ggglass/build.sh
ggglass/tests/run-tests.sh
ggglass/tests/cli.sh
ggglass/ggglass tint 0.3
ggglass/ggglass status
```

`on`/`off` take effect at the next login (WindowServer restarts on logout). `tint` applies immediately, following the macOS 27 path:

- `build/ggtint` writes `tintAmount` and posts the Darwin notification `com.goldengate.glass.tint`. GGGlass rereads it and binds the value at buffer 28 (`GGLive`, together with the light/dark flag), used by glass that carries no code of its own.
- `build/ggtint` writes `NSGlassTintAmount` (global domain) and sends coordinated notification type 12 with a fence, like 27's `setSystemLegibility`. `GGLegibility.dylib` in apps (ggapp) receives it, writes the code into the `inputClampPreserveHue` key of the glass filter and recommits; the shader decodes it from `preserve_hue`. WindowServer only forwards type 12 when `coordinatedGlass` is on.

Settings live in `/Users/Shared/GoldenGate/settings.plist`:

| Key | Meaning | Default |
|---|---|---|
| `enabled` | on/off | true |
| `tintAmount` | 0..1, fallback value; changed at runtime via `ggglass tint` | 0.5 |
| `coordinatedGlass` | lets coordinated notification type 12 reach apps: points the MIG `stub_routine` cell of msgh_id 30591 in WindowServer's SkyLight at a GGGlass stub (only when the expected bytes match; Apple code is not modified) | false |
| `pixelLength` | 1 / display scale | 1.0, a 1x display |
| `trace` | log every requested function name | false |
| `debugSize` | color by the glass short side the adapter uses: < 64 points red, 64-160 green, >= 160 blue; the texture variant adds stripes. Compares the SDF and texture variants of the same glass (takes priority over `debugColor` when both are on) | false |
| `dumpUniforms` | log glass pipeline creation time (ms, color format, thread) and the uniform hex QuartzCore binds for glass pipelines, one line per face matrix (rounded ~1.6%, merging animation steps), at most 64 faces per function (also hooks the driver's device and render encoder, only when on) | false |
| `debugEdge` | solid fill by SDF distance at pixels the adapter draws (constant 48): purple for the dark ring band (-1..0 points), green interior, blue outside the edge but still drawn, yellow for empty texels; the texture variant is striped. Tells whether a button edge on screen is ours or something drawn over it | false |
| `traceDraws` | log the sequence of up to 6 draws right after each of our glass draws (fragment function name, uber with texture function), at most 100 sequences | false |
| `noHighlight27` | disable the 27 highlight in the glass shader (constant 50), for A/B tests | false |
| `debugScale` | the texture variant encodes texels/point and distance slope into color (constant 49) | false |
| `debugColor` | color by 26.6 recipe (`kSigs26`): 0 green (regular inactive light), 1 dark green (regular inactive dark), 2 blue (clear light), 3 dark blue (clear dark), 4 yellow (regular active light), 5 magenta (?), 6 teal (?), 7 orange (?), 8 dark yellow (regular active dark), 9 white (Dock light), 10 gray (Dock dark), 11 brown (menu inactive light), 12 dark brown (menu inactive dark), 13 purple (clear base), 14-16 red-violet (Control Center), 17 mint / 18 dark mint (27 sidebar light / dark sent by ggapp `GGApp.sidebarGlass`), no match: red. Glass with an app recipe code: pink regular, light blue clear, mint sidebar, light brown menu, light gray Dock, purple Control Center, cream popover, half as bright when inactive. The texture variant adds diagonal stripes | false |

## Safety

- Only runs on build 25G72.
- Does nothing if `/Users/Shared/GoldenGate/disable` exists (kill-switch, `ggglass off`).
- Crash guard: on the 3rd consecutive load with none surviving 120 seconds it creates the `disable` file by itself, even when the loads are far apart (panic then reboot). Logging out 3 times quickly in a row also disables it: run `ggglass on` to re-enable.
- If `boots.plist` cannot be written (wrong directory permissions) it does not enable, since the crash guard could not protect.
- Log and `boots.plist` live in `/Library/Logs/WindowServer/GoldenGate`: the WindowServer sandbox only allows writes there. `/Users/Shared/GoldenGate` only holds `settings.plist` and `disable` (read-only for WindowServer). Log file: `/Library/Logs/WindowServer/GoldenGate/ggglass.log`.
- No Metal device is created at load time. The shader is only compiled (or the precompiled `gg27.metallib` loaded) at QuartzCore's first glass function request.
- Every error (missing shader, compile error, compile wait over 5 seconds) returns Apple's original function.
