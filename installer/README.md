# Golden Gate Glass installer

A `.pkg` that installs GGGlass (macOS 27 shaders in WindowServer) and ggapp (in-app effects), keeps them active across restarts and logins without modifying the system volume, and adds the management app `Golden Gate Glass.app`.

Only for macOS 26.6 (25G72), Intel, SIP Filesystem Protections off, AMFI off (`amfi_get_out_of_my_way=0x1`). The package checks this itself and refuses other machines.

## Build

```bash
ggapp/build.sh && ggglass/build.sh && installer/build.sh
```
Produces `installer/build/GoldenGateGlass.pkg` (and `installer/build/Golden Gate Glass.app`, `installer/build/ggd`).

`ggapp/Resources/` (Settings preview assets extracted from macOS 27) is not in the repository. Without it the package still builds and installs; only the System Settings slider preview lacks its images and strings. `GG_APP_RESOURCES=<folder>` points the build at another copy.

Tests: `installer/tests/run.sh` (pure functions of ggd and the app, `ggd daemon --once` with fake commands, `check.sh`, `postinstall`, `uninstall.sh`; does not touch the real system).

## What is installed where

| Path | Contents |
|---|---|
| `/Library/GoldenGate/` | `GGGlass.dylib`, `gg27.metal`, `gg27.metallib`, `ggd` (root) |
| `/Library/GoldenGate/app/` | `GGAppLoader.dylib`, `GGApp.dylib`, `GGLegibility.dylib`, `Resources/` (root, not 777) |
| `/Users/Shared/GoldenGate/` | `disable` (kill-switch), GGGlass `settings.plist` |
| `/Library/LaunchDaemons/com.goldengateglass.daemon.plist` | `ggd daemon`: arms GGGlass for WindowServer, restarts WindowServer once at the login window, sets `DYLD_INSERT_LIBRARIES` for the user right at login |
| `/Library/LaunchAgents/com.goldengateglass.agent.plist` | `ggd agent`: safety net, relaunches processes that have not loaded the loader |
| `/Applications/Golden Gate Glass.app` | management app |

Logs: `/Library/Logs/GoldenGate/ggd.log` (daemon), `~/Library/Logs/GoldenGate/agent.log` (agent), `/Library/Logs/WindowServer/GoldenGate/ggglass.log` (GGGlass), `~/Library/Logs/GoldenGate/ggapp.log` (ggapp).

## Uninstall

The "Uninstall..." button in the app, or `sudo zsh "/Applications/Golden Gate Glass.app/Contents/Resources/uninstall.sh"`. GGGlass and the ggapp dylibs are kept until the next restart (the `com.goldengateglass.cleanup` LaunchDaemon removes them once), so no environment variable ever points to a deleted file.

## Notes for developers

The dev setup (`ggapp install` + `ggapp session-on`, dylibs in `/Users/Shared/GoldenGate`) and the installed package use loaders at different paths: with both on, apps load GGApp twice. Before installing the package: `ggapp/ggapp session-off` (or `launchctl unsetenv DYLD_INSERT_LIBRARIES`).

## Updating after each change

```bash
ggapp/build.sh && ggglass/build.sh && installer/build.sh
```
Then open `installer/build/GoldenGateGlass.pkg`. Updates do not need a restart: reopened apps get the new ggapp; a new GGGlass takes effect at the next restart. Only the first install needs a restart (the Installer conclusion page says so). On a machine with the package installed, do not use `ggapp install` (it copies into `/Users/Shared/GoldenGate`, which apps no longer load from).
