#!/bin/zsh
# Tests the GGApp.dylib loader with the tests/host.m process packaged as an .app in a temporary directory.
# Does not touch global defaults or ~/Library: GG_PREFS (plist replacing the global domain), GG_HOME points at a temporary
# directory. Run after ggapp/build.sh. Exits 1 if any case fails.
set -u
here=${0:A:h}; bdir=${GG_BUILD:-${here:h}/build}; dylib=$bdir/GGApp.dylib   # GG_BUILD: separate build directory, as in build.sh
t=$(mktemp -d /tmp/gg-loader.XXXXXX); fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1 (got: $2)"; fail=1; }
mkapp() {   # mkapp <.app directory> <bundle id>
    mkdir -p $1/Contents/MacOS
    cp $t/host $1/Contents/MacOS/host
    cat > $1/Contents/Info.plist <<P
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string><key>CFBundleExecutable</key><string>host</string>
</dict></plist>
P
    codesign -f -s - $1 2>/dev/null
}
clang -arch x86_64 -fobjc-arc -framework Foundation -o $t/host $here/host.m || exit 1
mkapp $t/Host.app vn.gg.host
mkapp $t/Excl.app vn.gg.excluded
prefs=$t/prefs.plist
defaults write $prefs GGApp.exclude -array vn.gg.excluded
run() {   # run <app binary> [VAR=value...]; prints the state
    local bin=$1; shift
    env GG_PREFS=$prefs GG_HOME=$t/home GG_FAKE_BUILD=25G72 "$@" DYLD_INSERT_LIBRARIES=$dylib $bin 2>/dev/null | sed -n 's/^GGAPP://p'
}
H=$t/Host.app/Contents/MacOS/host
s=$(run $H); [ "$s" = active ] && ok "normal run -> active" || bad "normal" "$s"
[ ! -f $t/home/Library/Logs/GoldenGate/guard/vn.gg.host.crashes ] && ok "normal exit leaves no crash history" || bad "guard after exit" "file remains"
grep -q "vn.gg.host" $t/home/Library/Logs/GoldenGate/ggapp.log 2>/dev/null && ok "log written" || bad "log" "missing"
s=$(run $H GG_FAKE_BUILD=25G71); [ "$s" = inactive:build ] && ok "other build -> no hooks" || bad "build" "$s"
s=$(run $t/host); [ "$s" = inactive:nobundle ] && ok "not an .app -> no hooks" || bad "nobundle" "$s"
s=$(run $t/Excl.app/Contents/MacOS/host); [ "$s" = inactive:excluded ] && ok "app.exclude -> no hooks" || bad "excluded" "$s"
defaults write $prefs GGApp.disable -bool YES
s=$(run $H); [ "$s" = inactive:disabled ] && ok "GGApp.disable -> no hooks" || bad "disabled" "$s"
defaults write $prefs GGApp.disable -bool NO
s=$(run $H HOST_TWICE=1); [ "$s" = active ] && ok "installing hooks twice does not crash" || bad "twice" "$s"
for i in 1 2 3 4; do run $H HOST_EXIT=1 >/dev/null; done
s=$(run $H); [ "$s" = active ] && ok "4 early sudden-termination exits -> not excluded" || bad "early exit excluded" "$s"
# Swift fatalError style trap (SIGILL): the handler must record once and let the process die, not loop forever
# (SA_RESETHAND does not apply to SIGILL/SIGTRAP). Real run (no GG_GUARD_TEST), 10 s limit; deletes the host crash
# reports this case produces.
touch $t/mark
env GG_PREFS=$prefs GG_HOME=$t/home-trap GG_FAKE_BUILD=25G72 HOST_TRAP=1 DYLD_INSERT_LIBRARIES=$dylib perl -e 'alarm 10; exec @ARGV' $H >/dev/null 2>&1; rc=$?
[ $rc -eq 132 ] && [ "$(wc -c < $t/home-trap/Library/Logs/GoldenGate/guard/vn.gg.host.crashes 2>/dev/null | tr -d ' ')" = 1 ] \
    && ok "SIGILL trap: records 1 crash then dies, no hang" || bad "SIGILL trap" "exit code $rc (142 = hung until the 10 s limit), $(wc -c < $t/home-trap/Library/Logs/GoldenGate/guard/vn.gg.host.crashes 2>/dev/null) bytes"
sleep 2; find ~/Library/Logs/DiagnosticReports -name 'host-*' -newer $t/mark -delete 2>/dev/null
for i in 1 2 3; do run $H HOST_CRASH=1 GG_GUARD_TEST=1 >/dev/null; done
[ "$(wc -c < $t/home/Library/Logs/GoldenGate/guard/vn.gg.host.crashes 2>/dev/null | tr -d ' ')" = 3 ] && ok "handler records 3 crashes (SIGABRT)" || bad "crash count" "$(ls $t/home/Library/Logs/GoldenGate/guard/)"
s=$(run $H); [ "$s" = inactive:guard ] && ok "3 consecutive crashes -> self-excluded" || bad "guard" "$s"
[ -f $t/home/Library/Logs/GoldenGate/guard/vn.gg.host.excluded ] && ok ".excluded file exists" || bad "excluded file" "missing"
# A sandboxed app reads the real global defaults (must be active when GGApp.disable is not set on the machine).
mkdir -p $t/sb; mkapp $t/sb/SB.app vn.gg.sandbox
print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>' > $t/sb.ent
codesign -f -s - --entitlements $t/sb.ent $t/sb/SB.app 2>/dev/null
s=$(DYLD_INSERT_LIBRARIES=$dylib GG_FAKE_BUILD=25G72 $t/sb/SB.app/Contents/MacOS/host 2>/dev/null | sed -n 's/^GGAPP://p')
[ "$s" = active ] && ok "sandboxed app reads settings -> active" || bad "sandbox" "${s:-did not run}"
rm -rf ~/Library/Containers/vn.gg.sandbox 2>/dev/null
# Stage 1 loader (GGAppLoader.dylib, next to GGApp.dylib in build/): only apps load GGApp.dylib; the variable is removed.
loader=$bdir/GGAppLoader.dylib
st1() { env GG_PREFS=$prefs GG_HOME=$t/home-st1 GG_FAKE_BUILD=25G72 DYLD_INSERT_LIBRARIES=$loader $1 2>/dev/null | tr '\n' ' '; }
s=$(st1 $H); [[ "$s" == *"GGAPP:active"*"ENV:removed"* ]] && ok "stage 1 loader: app -> loads GGApp, removes the variable" || bad "stage 1 app" "$s"
s=$(st1 $t/host); [[ "$s" == *"GGAPP:nodylib"*"ENV:removed"* ]] && ok "stage 1 loader: not an app -> does not load GGApp" || bad "stage 1 non-app" "$s"
# .appex: only UI extension points (System Settings panes) load; binary plist as on the real system.
mkappex() {   # mkappex <.appex directory> <bundle id> <extension point>
    mkdir -p $1/Contents/MacOS; cp $t/host $1/Contents/MacOS/host
    defaults write $1/Contents/Info.plist CFBundleIdentifier $2
    defaults write $1/Contents/Info.plist CFBundleExecutable host
    defaults write $1/Contents/Info.plist EXAppExtensionAttributes -dict EXExtensionPointIdentifier $3
    plutil -convert binary1 $1/Contents/Info.plist
    codesign -f -s - $1 2>/dev/null
}
mkappex $t/Pane.appex vn.gg.pane com.apple.Settings.extension.ui
mkappex $t/Thumb.appex vn.gg.thumb com.apple.quicklook.thumbnail.secure
s=$(st1 $t/Pane.appex/Contents/MacOS/host); [[ "$s" == *"GGAPP:active"* ]] && ok "stage 1 loader: Settings pane appex -> loads GGApp" || bad "appex pane" "$s"
s=$(st1 $t/Thumb.appex/Contents/MacOS/host); [[ "$s" == *"GGAPP:nodylib"* ]] && ok "stage 1 loader: background appex (thumbnail) -> not loaded" || bad "background appex" "$s"
defaults write $prefs GGApp.appex -bool NO
s=$(st1 $t/Pane.appex/Contents/MacOS/host); [[ "$s" == *"GGAPP:inactive:appex"* ]] && ok "GGApp.appex NO -> appex not hooked" || bad "GGApp.appex" "$s"
defaults delete $prefs GGApp.appex
# GGLegibility.dylib: regular apps load it through GGApp (GGApp.legibility, on by default);
# Dock, Control Center, Notification Center, SystemUIServer load only GGLegibility (no AppKit); GGApp.systemUI on by default.
s=$(st1 $H); [[ "$s" == *"GGAPP:active"*"LEG:installed"* ]] && ok "regular app: loads GGApp and GGLegibility" || bad "regular app legibility" "$s"
defaults write $prefs GGApp.legibility -bool NO
s=$(st1 $H); [[ "$s" == *"LEG:nolib"* ]] && ok "GGApp.legibility NO -> regular app does not load GGLegibility" || bad "GGApp.legibility" "$s"
defaults delete $prefs GGApp.legibility
mkdir -p $t/sys; mkapp $t/sys/Dock.app com.apple.dock
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"GGAPP:nodylib"*"LEG:installed"*"APPKIT:no"* ]] \
    && ok "Dock, no systemUI key: installs GGLegibility by default" || bad "Dock systemUI default" "$s"
defaults write $prefs GGApp.systemUI -bool NO
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"LEG:systemui:off"*"APPKIT:no"* ]] \
    && ok "Dock, systemUI NO: not installed" || bad "Dock systemUI NO" "$s"
defaults write $prefs GGApp.systemUI -bool YES
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"GGAPP:nodylib"*"LEG:installed"*"APPKIT:no"* ]] \
    && ok "Dock, systemUI on: installs GGLegibility, no GGApp, no AppKit" || bad "Dock systemUI on" "$s"
# Spotlight 27 is built with NSGlassEffectView so it follows the slider; GGApp excludes com.apple.Spotlight, so it takes the systemUI path.
mkapp $t/sys/Spotlight.app com.apple.Spotlight
s=$(st1 $t/sys/Spotlight.app/Contents/MacOS/host); [[ "$s" == *"GGAPP:nodylib"*"LEG:installed"*"APPKIT:no"* ]] \
    && ok "Spotlight, systemUI on: installs GGLegibility, no GGApp" || bad "Spotlight systemUI on" "$s"
defaults write $prefs GGApp.disable -bool YES
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"LEG:systemui:off"* ]] && ok "Dock, GGApp.disable: not installed" || bad "Dock disable" "$s"
defaults delete $prefs GGApp.disable
# Crash guard of the systemUI mode (not via GGApp): after 3 consecutive launches that do not live past 60 s it stops
# installing (launchd relaunches a dead Dock at once, so without a guard it would crash forever). ggapp on clears the guard directory.
rm -rf $t/home-st1/Library/Logs/GoldenGate/guard
for i in 1 2 3; do st1 $t/sys/Dock.app/Contents/MacOS/host >/dev/null; done
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"LEG:systemui:guard"* ]] && ok "Dock: 3 consecutive early deaths -> guard, not installed" || bad "Dock guard" "$s"
rm -rf $t/home-st1/Library/Logs/GoldenGate/guard
s=$(st1 $t/sys/Dock.app/Contents/MacOS/host); [[ "$s" == *"LEG:installed"* ]] && ok "Dock: clearing the guard reinstalls" || bad "Dock after clearing guard" "$s"
defaults delete $prefs GGApp.systemUI
# The host app injects DYLD_INSERT_LIBRARIES (GGAppLoader in the same directory) into the extension launch configuration (AppexEnv.m).
s=$(env GG_PREFS=$prefs GG_HOME=$t/home-ax GG_FAKE_BUILD=25G72 HOST_APPEXENV=1 DYLD_INSERT_LIBRARIES=$dylib $H 2>/dev/null | sed -n 's/^APPEXENV://p')
L=${dylib:h}/GGAppLoader.dylib
[ "$s" = "$L|/x.dylib:$L|v|no duplicate" ] && ok "host app injects the loader into the extension environment (keeps other libraries, no duplicate)" || bad "appex env injection" "$s"
# Spring 27 (Sources/Spring.swift).
cp $here/spring.swift $t/main.swift
swiftc -o $t/spring $t/main.swift ${here:h}/Sources/Spring.swift 2>$t/err && $t/spring || { cat $t/err; fail=1; }
# The two 27 glow layers (Sources/Glow.swift).
mkdir -p $t/glow && cp $here/glow.swift $t/glow/main.swift
swiftc -o $t/glowtest $t/glow/main.swift ${here:h}/Sources/Spring.swift ${here:h}/Sources/Glow.swift 2>$t/err && $t/glowtest || { cat $t/err; fail=1; }
# GGLegibility.dylib (27 slider path): cases in tests/legibility.m.
clang -arch x86_64 -fobjc-arc -framework Foundation -framework CoreGraphics -I ${here:h}/Legibility $bdir/GGLegibility.dylib \
    -o $t/legibility $here/legibility.m 2>$t/err \
    && env GG_PREFS=$t/leg.plist GG_HOME=$t/home-leg DYLD_LIBRARY_PATH=$bdir $t/legibility || { cat $t/err; fail=1; }
# In-app glass 27 recipe and recipe codes: tests/recipe.m.
clang -arch x86_64 -fobjc-arc -framework Foundation -I ${here:h}/Legibility $bdir/GGLegibility.dylib \
    -o $t/recipe $here/recipe.m 2>$t/err && DYLD_LIBRARY_PATH=$bdir $t/recipe || { cat $t/err; fail=1; }
rm -rf $t
[ $fail -eq 0 ] && print "TOTAL: all passed" || print "TOTAL: some failed"
exit $fail
