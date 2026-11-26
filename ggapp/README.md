# GGApp

A dylib loaded into GUI apps on macOS 26.6 (25G72, x86_64) that brings macOS 27 in-app Liquid Glass behavior, rebuilt the way macOS 27 does it:

| Effect | How |
|---|---|
| Interactive glass buttons (Flexiglass) | Registers a `PlatformGlassInteractionDefinition` for `.appKit` so SwiftUI 26.6 expands glass entries itself; the 27 spring is integrated in-app, two `vibrantColorMatrix` glow layers (backdrop-aware); `.glass`/`.glassProminent` buttons become interactive by pointing DesignLibrary's `_Glass.regular` GOT slot at `_Glass.regular.interactive(true)` |
| Traffic lights | A `MaterialProvider` stacking SDF layers like 27 `WindowControlMaterialProvider`, in a dedicated `NSHostingView` placed on `_NSThemeWidget`; grows 14 -> 16 pt on press, stretches/drifts with drags (windowControl FlexInteraction) |
| Scroll pocket | Drops the progressive blur (`variableBlur`) and picks recipes like AppKit 27: sidebar -> ThinFilm over glass, toolbar title text -> ThinFilm, content without a title -> ConditionalPocketRecipe(ThinFilm) (transparent when key, ThinFilm on hover/inactive), hard style -> 27 HardPocket; every recipe replaces the 26.6 drawing, whether 26.6 picked soft or hard |
| Toolbar press | AppKit toolbar platters grow and glow on press like 27 `NSToolbarPlatterView` |
| Sidebar | No floating sidebars, like AppKit 27 (`wantsFloatingAppearance`/`_hasFloatingAppearance` always NO); AppKit icons tinted with the accent color in key windows, labelColor otherwise; semibold selected row text without accent tint; SwiftUI `List(.sidebar)` icons and Catalyst sidebars like 27; optional 27 `SidebarRecipe` glass parameters (needs the GGGlass shader) |
| Menu glass | Context/popup menus: a faint LittleGlow spot under the pointer while pressing or dragging in the menu (the 27 `menu` pointer set, no growth), via a `-[NSMenuTrackingSession handleEvent:]` hook in place of 27 `_NSFlexiglassInteractionDriver` |
| Window corners | 27 radius: 16 pt for every titled window and sheet, 26 for alerts (26.6: 15/16/20/26 by window and toolbar style); window shape and shadow follow |
| Glass tint slider | The 27 Liquid Glass slider in the Appearance pane of System Settings, and the system-wide transparency path behind it (`GGLegibility.dylib`) |

## Components

| File | Role |
|---|---|
| `Stage1/Stage1.c` | `GGAppLoader.dylib`, the file `DYLD_INSERT_LIBRARIES` points at. Plain C (libSystem only): non-app processes load nothing more; removes the variable so child processes do not inherit it; apps `dlopen` `GGApp.dylib` from the same directory, system UI processes load only `GGLegibility.dylib` |
| `Sources/Loader.m` | run conditions, kill switch, exclusions, crash guard, log, SPI symbol check, GOT patching |
| `Sources/Spring.swift` | the 27 spring (response, dampingFraction) |
| `Sources/Flex.swift` | interactive glass buttons |
| `Sources/Glow.swift` | 27 pointer parameters and the BigGlow/LittleGlow layers (path per 27 `updateGlow`), shared by Flex, ToolbarPress and MenuGlass |
| `Sources/WindowControl.swift`, `Sources/WindowControlHook.m` | traffic lights |
| `Sources/Pocket.m` | scroll pocket |
| `Sources/ToolbarPress.swift` | AppKit toolbar press |
| `Sources/Sidebar.m` | 27 sidebar: not floating, icon/text colors per 27 `NSTintConfiguration`, semibold selected row text, `SidebarRecipe` glass parameters (separate key), App Store style glass search field |
| `Sources/SidebarIcon.swift`, `Sources/SidebarIcon.m` | SwiftUI `List(.sidebar)` icons per 27 `SidebarRow_Mac.calistogaIconStyle`: a `ColorProvider` (SPI) picks the color from the environment, injected into the Solarium closure of 25G72 `SidebarRow_Mac` |
| `Sources/SidebarUIKit.m` | Catalyst app sidebars like 27: non-floating tab sidebar (abutted background), 27 metrics (radius, platter insets 0, glass background kept), no extra 8 pt top inset, abutted background for split view sidebar columns |
| `Sources/SettingsSlider.swift`, `Sources/SettingsSlider.m` | the 27 Liquid Glass slider in the System Settings Appearance pane: `GlassStyleRow` (26.6 pane) returns a rebuilt 27 `GlassStylePicker(.settings)`; drag = preview, release = commit through GGLegibility |
| `Sources/SettingsPreview.swift` | the slider preview like 27 `GlassStylePreviewView`: an Apple Park article scrolling under a glass toolbar, a scroll demo, the "Moof!" easter egg (Oak Ridge) and the Clarus image. Uses `Resources/SettingsPreview/` if present (see below) |
| `Sources/MenuGlass.swift` | 27 interactive menu glass |
| `Sources/WindowCorners.m` | 27 window corner radius (replaces `-[NSThemeFrame _getCachedWindowCornerRadius]`) |
| `Sources/AppexEnv.m` | injects the loader into extensions launched by a host app (System Settings panes) |
| `Legibility/Legibility.m` | `GGLegibility.dylib`: the 27 glass transparency path (receives the type 12 coordinated notification, tracks `NSGlassTintAmount`, injects the code into `glassBackground` filters and recommits, `GGGlassSetSystemLegibility` API). Foundation/QuartzCore/SkyLight only; the stage 1 loader loads it directly (without GGApp) into Dock, Control Center, Notification Center, SystemUIServer and Spotlight |
| `Legibility/Recipe27.c`, `Legibility/Recipe.m` | (in `GGLegibility.dylib`) in-app glass 27 recipes at the CA level plus recipe codes; recipe picked from the view (`_variant` 16-18 sidebar, 20 popover in `NSPopoverFrame`), the 26.6 face and `_hasActiveAppearance`; written in `setFilters:`, rewritten when bounds, window or slider change |
| `SPI/appendix.swiftinterface` | hand-declared SwiftUICore 26.6 SPI, appended to the SDK interface at build time |
| `build.sh` | builds the three dylibs; SwiftUI is weak linked, the SPI symbol list is generated at build time and checked with `dlsym` at load |
| `ggapp` | control tool |
| `tests/` | `abi.sh` (SPI symbols and type sizes), `run-tests.sh` (loader, stage 1 loader, spring, glow, GGLegibility, recipes), `cli.sh` (control tool), `app.sh <mode>` (test app that captures its own windows to PNG in `build/shots`) |

## Build and test

```bash
ggapp/build.sh
```

```bash
ggapp/tests/abi.sh && ggapp/tests/run-tests.sh && ggapp/tests/cli.sh
```

Window tests (they open windows and may take focus): `ggapp/tests/app.sh <mode> [VAR=value...]`, where mode is one of `flex`, `controls`, `lights`, `pocket`, `toolbar`, `sidebar`, `corners`, `menu`, `legibility`, `recipes`, `settings`, `searchfield`, `glassflip`. For example:

```bash
ggapp/tests/app.sh recipes GG_ABI_FAKE=2
```

`app.sh` runs the test app with `DYLD_INSERT_LIBRARIES` pointing straight at `build/GGApp.dylib` and a temporary settings plist; it does not touch the system. `GG_BUILD=<dir>` selects a separate build directory for `build.sh`, the tests and `ggapp install`.

## Install

```bash
ggapp/ggapp install
```

```bash
ggapp/ggapp session-on
```

`install` copies the dylibs (and `Resources/` if present) to `/Users/Shared/GoldenGate`; `session-on` sets the session `DYLD_INSERT_LIBRARIES` so apps opened afterwards load GGApp. To remove: `ggapp session-off`, then log out. To turn off quickly without removing: `ggapp off`. `ggapp status` prints the settings, the session variable, apps excluded by the crash guard and the last log lines.

## Settings preview resources

The Settings slider preview uses images and string tables from macOS 27 (Apple assets), shipped in `ggapp/Resources/SettingsPreview/`. Without them everything still works: images show a placeholder symbol and texts fall back to their English keys. They were extracted from a macOS 27 system (a mounted macOS 27 IPSW) as follows:

- `apple-park.heic`, `architecture.heic`, `pond.heic`, `rainbow.heic`: the images of the same names in `Assets.car` of `AppearancePreferencesFramework.framework` (load the framework bundle, `-[NSBundle imageForResource:]`, write HEIC).
- `clarus.heic`: the Clarus image of the "Moof!" easter egg, embedded in the 27 `Appearance.appex` binary.
- `Localizable.loctable`: copied from the framework's `Resources`, plus a `<language>.lproj` directory for every language in the table (NSBundle needs them to pick a language for a non-main bundle; each holds an empty `.keep` so git keeps it).

`ggapp install` copies `ggapp/Resources/` next to the installed dylibs; from the build directory the preview reads `../Resources`.

## Settings (global defaults, all on by default)

| Key | Meaning |
|---|---|
| `GGApp.disable` | kill switch, `ggapp off`/`on` |
| `GGApp.flex` | interactive glass buttons |
| `GGApp.flexGlassButton` | makes `.glass`/`.glassProminent` buttons interactive (DesignLibrary GOT patch) |
| `GGApp.trafficLights` | traffic lights |
| `GGApp.pocket` | scroll pocket |
| `GGApp.toolbarPress` | AppKit toolbar press (interactive platter glass) |
| `GGApp.sidebar` | 27 sidebar (not floating, icon/text colors, semibold selected row text) |
| `GGApp.sidebarGlass` | **off by default**: writes the 27 `SidebarRecipe` glass parameters into the sidebar filter; enable only when the GGGlass shader recognizes this signature |
| `GGApp.sidebarCatalyst` | Catalyst app sidebars (Podcasts, Books...) edge to edge from top to bottom, with a glass background, like macOS 27 |
| `GGApp.settingsSlider` | the 27 Liquid Glass slider in place of the Clear/Tinted row in the Appearance pane (only acts in the pane process, needs `GGApp.appex` and `GGApp.legibility`) |
| `GGApp.settingsMoof` | **unset by default**: like 27, the preview "Moof!" easter egg is enabled only when AKURLBag returns `enableOakRidge = true`; set on/off to force it (clear: `defaults delete -g GGApp.settingsMoof`) |
| `GGApp.windowCorners` | 27 window corner radius |
| `GGApp.menuGlass` | 27 interactive menu glass |
| `GGApp.appex` | brings ggapp into UI extensions launched by a host app (System Settings panes) |
| `GGApp.legibility` | the 27 glass transparency path in regular apps (loads `GGLegibility.dylib`) |
| `GGApp.appRecipes` | the app computes the glass 27 recipe for each glass and writes the real values plus a recipe code into the filter. Only effective when a GGGlass that understands the codes is running (notify state `com.goldengate.glass.abi` = 2); read at load, reopen apps after changing it |
| `GGApp.systemUI` | installs `GGLegibility.dylib` (only that part) into Dock, Control Center, Notification Center, SystemUIServer and Spotlight |
| `GGApp.island` | GGLegibility also loads `GGIsland.dylib` (macOS 27 Dynamic Island, `island/`) into Control Center; independent of `GGApp.systemUI`, same crash guard |
| `GGApp.exclude` | array of bundle IDs that never load, on top of the default list (loginwindow, Dock, SecurityAgent, Control Center...) |

Set a key with `ggapp set <key> on|off` (for the keys the tool lists) or `defaults write -g GGApp.<key> -bool YES|NO`. Changes apply to apps opened afterwards.

Log: `~/Library/Logs/GoldenGate/ggapp.log`; sandboxed apps write to `~/Library/Containers/<bundle>/Data/Library/Logs/GoldenGate/`. Crash guard: after 3 consecutive crashes with no run surviving 60 s, `guard/<bundleID>.excluded` is created next to the log (`ggapp on` clears it).

## Known limitations

- Build 25G72 only; on any other build it does nothing.
- Disabled `.glass` buttons still bounce when pressed (the `_Glass.regular` patch does not know the button state).
- Traffic lights: the highlight is built from `glassHighlight_v2` because `CASDFKeyFillHighlightEffect` draws nothing on 26.6; glyphs are 26.6 assets (thinner than 27); the 27 increased contrast branch and `showBorders` outline are missing.
- Pocket: top edge only; the QuartzCore 27 blur-fill is rebuilt with three backdrops (its exact render semantics are unknown); the background replay uses our own captureOnly backdrop under the content (the 26.6 capture is disabled while 26.6 draws a hard pocket); table headers do not force Hard yet.
- No `liquidLens` yet (switch, slider, segmented). Glass windows (alerts, sheets), glass Services buttons and the Campo background that 27 makes interactive are new 27 UI that 26.6 does not have.
- Toolbar: mouse press only (local monitor + the button tracking loop); the platter scales as a whole layer (27 reshapes the glass, a sub-pixel difference).
- The glow turns off with Reduce Transparency (27 uses Reduce Highlighting Effects, absent on 26.6); no touch (Sidecar) input, drag stretching is ignored (under 0.1% with a mouse).
