# GoldenGateGlassBackport

Backports the Liquid Glass of macOS 27 (Golden Gate) to macOS 26.6 Tahoe (build 25G72) on Intel x86_64 Macs.

## Read this first

- **Risky by design.** This project runs unsigned code inside WindowServer and inside your apps, on a system with SIP and AMFI off. A bug can crash WindowServer, log you out, or leave you unable to log in. Use it on a machine you can recover, keep a backup, and do not use it on a machine you depend on.
- **One exact system only:** macOS 26.6 build **25G72**, Intel Mac (x86_64), System Integrity Protection with **Filesystem Protections disabled**, AMFI disabled (`amfi_get_out_of_my_way=1` in `boot-args`). The patches depend on private symbols and memory layouts of that build; the installer and the app check every condition and refuse to run otherwise. Apple Silicon and other macOS builds are not supported.
- **Unsigned package.** `GoldenGateGlass.pkg` is not signed or notarized, so macOS blocks it on first open (see [Install](#install)).
- **Emergency off switch:** create `/Users/Shared/GoldenGate/disable` and restart; WindowServer then starts without GGGlass. If you cannot log in, create that file from Recovery (on the Data volume) or over SSH. GGGlass also creates it by itself when WindowServer crashes repeatedly right after loading it, and ggapp stops loading into any app that keeps crashing.
- **Not from Apple.** This is an independent project, not affiliated with, endorsed by, or supported by Apple Inc.

## Features

### Glass rendering in WindowServer (GGGlass)

Every glass surface on screen is drawn with the macOS 27 glass algorithm: GGGlass replaces the QuartzCore 26.6 glass shaders inside WindowServer with a port of the 27 shaders (refraction, blur, highlights, shadows, light/dark and active/inactive variants). The shaders are precompiled and cached by the Metal driver after the first boot, so there is no runtime compile cost.

### In-app behavior (ggapp)

ggapp is loaded into GUI apps and brings over the macOS 27 behavior that lives in AppKit and SwiftUI:

| Feature | What changes |
|---|---|
| Interactive glass buttons | glass buttons flex and glow when pressed, including SwiftUI `.glass` button styles |
| Window controls | macOS 27 close, minimize and zoom buttons |
| Toolbar button press | toolbar buttons get the 27 glass press highlight |
| Scroll edge effect | the 27 scroll pocket under toolbars and titlebars (ThinFilm, Conditional and Hard styles chosen like 27) |
| Sidebar | not floating, 27 icon and text colors, semibold selected row, glass search field; Catalyst apps (Podcasts, Books) edge to edge like 27 |
| Interactive menus | glass highlight follows the pointer in menus |
| Window corners | macOS 27 window corner radius |
| Glass transparency slider | the macOS 27 Liquid Glass slider in System Settings > Appearance, with the 27 preview; apps, Dock, Control Center, Notification Center and Spotlight follow it |
| Per-glass recipes | each glass surface gets the macOS 27 recipe (regular, clear, sidebar, menu, Dock, Control Center, widgets, notifications) |

### Management app (Golden Gate Glass)

A small app in Applications shows whether this Mac meets the requirements, whether the background helpers run, whether WindowServer loaded GGGlass and whether the current session has the app effects. It has a switch for each effect, lists apps excluded after crashes (with "Allow Again"), opens the logs, turns everything off or on, and uninstalls.

## Install

Download `GoldenGateGlass.pkg` from Releases, or [build it](#build-from-source). Because it is unsigned, either right-click the package and choose Open, or remove the quarantine flag first:

```bash
xattr -d com.apple.quarantine GoldenGateGlass.pkg
```

Restart after the first install. Updates install over the old version without a restart: reopen apps to get the new in-app effects; WindowServer changes apply at the next restart.

The package installs everything outside the system volume (`/Library/GoldenGate`, a LaunchDaemon and a LaunchAgent, the app). See [installer/README.md](installer/README.md) for the exact files and log locations.

## Use

- **Glass transparency:** System Settings > Appearance > Liquid Glass slider, as on macOS 27.
- **Effects:** open Golden Gate Glass and flip the switches; changes apply to apps opened afterwards.
- **Turn off app effects:** "Turn Everything Off" in the app, or `defaults write -g GGApp.disable -bool true`, then reopen apps.
- **Turn off WindowServer glass:** create `/Users/Shared/GoldenGate/disable` and restart.
- **Uninstall:** "Uninstall..." in the app, or `sudo zsh "/Applications/Golden Gate Glass.app/Contents/Resources/uninstall.sh"`, then restart. Remaining files are removed at that restart.

## Known limitations

- The scroll edge effect covers the top edge only; table headers are not yet forced to the Hard style, and its opacity does not follow the transparency slider yet.
- Widgets keep the macOS 26.6 tint matrix (the macOS 27 one is not located yet); text buttons in notifications ("Clear", "Show Less") are not glass yet.
- Some macOS 27 surfaces do not exist in 26.6 (glass alerts and sheets, the Campo background) and are not recreated.
- The `liquidLens` controls of macOS 27 (switch, slider, segmented control lens) are not implemented.

## Build from source

Requires Xcode 26 (swiftc, clang, actool and the Metal compiler; on Xcode 26 install the Metal toolchain with `xcodebuild -downloadComponent MetalToolchain`).

```bash
ggapp/build.sh && ggglass/build.sh && installer/build.sh
```

The package is written to `installer/build/GoldenGateGlass.pkg`.

GitHub Actions builds the same package (`.github/workflows/build.yml`): every push and pull request builds it and runs the tests that do not depend on the host system, and pushing a tag `v*` publishes the package as a GitHub Release.

## Tests

```bash
installer/tests/run.sh
```

```bash
ggglass/tests/run-tests.sh
```

```bash
ggapp/tests/run-tests.sh
```

The installer tests use a fake `launchctl` and temporary folders; they do not touch the running system. Most other tests need macOS 26.6 25G72; `ggapp/tests/app.sh` opens windows and `glass-harness/` needs a GPU (see [glass-harness/README.md](glass-harness/README.md)).

## Layout

| Folder | Contents |
|---|---|
| `ggapp/` | In-app effects: `GGAppLoader.dylib` (the file `DYLD_INSERT_LIBRARIES` points to), `GGApp.dylib`, `GGLegibility.dylib`, the `ggapp` dev tool, tests |
| `ggglass/` | `GGGlass.dylib` for WindowServer, the `ggglass` dev tool, tests |
| `installer/` | `ggd` helper (LaunchDaemon and LaunchAgent), the Golden Gate Glass app, package scripts, uninstaller, tests |
| `glass-harness/` | The macOS 27 glass shader port (`shaders/glass26_replica.metal`) and offline tools to render and compare glass states |
| `abi/` | Glass ABI description of build 25G72 used by the harness |
| `measurements/` | Reference glass states measured on 25G72 |

## Apple assets

No Apple binaries are included. The System Settings slider preview uses a few images and a string table from macOS 27 (`ggapp/Resources/SettingsPreview/`, see [ggapp/README.md](ggapp/README.md) for how they were extracted), and the app icon uses the macOS 26 Tahoe wallpaper. They remain the property of Apple Inc. macOS, Liquid Glass, and related names are trademarks of Apple Inc.
