# Island (M1)

A standalone test app that shows the macOS 27.3 Dynamic Island (MenuBarAgent `CenterHUD`) on macOS 26.6 (25G72, x86_64), with the 27.3 geometry, corner curve and springs. Nothing is injected and nothing on the system is changed: it is one non-activating panel at the top center of the main screen, above the menu bar and below menus.

| File | Role |
|---|---|
| `Sources/Metrics.swift` | 27.3 constants and pure geometry: sensor region (59 x 34 pt, 7 pt from the top), compact/minimal/expanded layouts, expanded type selection, shadows, hover scale/lean, key line, springs, the case 3 corner curve (mitosis gap) and the island path (circular corners) |
| `Sources/Island.swift` | `FluidSpring` (exact damped-oscillator solution), `IslandAnimator` (springs per shape value), `IslandPanel` (CAShapeLayer drawing, display link paused when idle, content crossfade with blur) |
| `demo/main.swift` | `IslandDemo shots` and `IslandDemo live` |
| `Bridge/OSDBridge.m` | `GGIsland.dylib`: hooks the 23 OSD entry points of ControlCenter 26.6 `SystemBannerService`, reports each call to `gg_island_osd_sink` (default `os_log`, subsystem `com.goldengate.island`) and forwards it unchanged; also reports Focus changes from `FCActivityManager` (26.6 Focus banners do not go through `SystemBannerService`). Kill switch: `defaults write com.goldengate.island disable -bool YES`. The island hides when idle; keep the idle pill with `defaults write -g GGIsland.showWhenIdle -bool YES` |
| `tools/cc-once.sh` | loads `GGIsland.dylib` into ControlCenter for one launch (`sudo launchctl debug`, then restart); `cc-once.sh restore` restarts it without the bridge. Nothing is installed |
| `tests/tests.swift`, `tests/run-tests.sh` | window-free tests |
| `build.sh` | builds `build/IslandDemo.app` |

## Build and test

```bash
island/tests/run-tests.sh
```

```bash
island/build.sh
```

Window modes (they show the panel at the top of the screen but never activate the app):

```bash
island/build/IslandDemo.app/Contents/MacOS/IslandDemo shots
```

```bash
island/build/IslandDemo.app/Contents/MacOS/IslandDemo live
```

`shots` captures every state to `build/shots/island-<state>.png` and checks the opaque area against the computed shape. `live` cycles the states every 3 s for 90 s; click the island to expand or collapse it. `ISLAND_BUILD=<dir>` selects another build directory.
