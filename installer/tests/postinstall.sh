#!/bin/zsh
# Test installer/pkg/scripts/postinstall on a fake volume ($3 = temp folder, no launchctl calls, no root needed).
set -u
here=${0:A:h}; script=${here:h}/pkg/scripts/postinstall
t=$(mktemp -d) || exit 1
trap 'rm -rf "$t"' EXIT
fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1"; fail=1; }
V=$t/vol G=$t/vol/Library/GoldenGate
payload() {
    mkdir -p $G/.payload/app/Resources/SettingsPreview
    for f in GGGlass.dylib gg27.metal gg27.metallib ggd app/GGAppLoader.dylib app/GGApp.dylib app/GGLegibility.dylib app/GGIsland.dylib; do
        print -n "new" > $G/.payload/$f
    done
    print -n "new" > $G/.payload/app/Resources/SettingsPreview/pond.heic
    touch -t 202601010000 $G/.payload/gg27.metallib   # metallib in the payload is older than .metal
}

payload
/bin/zsh $script x x $V/ >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && ok "postinstall finished" || bad "exit code $rc"
[[ -f $G/GGGlass.dylib && -f $G/ggd && -f $G/app/GGAppLoader.dylib && -f $G/app/GGIsland.dylib && -f $G/app/Resources/SettingsPreview/pond.heic ]] \
    && ok "files moved into place" || bad "missing files: $(find $G | sort)"
[[ ! -e $G/.payload ]] && ok ".payload removed" || bad ".payload still present"
[[ ! $G/gg27.metallib -ot $G/gg27.metal ]] && ok "metallib not older than .metal" || bad "metallib older than .metal"
[[ $(stat -f %Lp $V/Users/Shared/GoldenGate) == 777 && $(stat -f %Lp $V/Library/Logs/WindowServer/GoldenGate) == 777 ]] \
    && ok "settings and log folders are 777" || bad "folder permissions"
[[ $(stat -f %Lp $G/app/GGApp.dylib) == 755 && $(stat -f %Lp $G/gg27.metal) == 644 ]] && ok "file permissions" || bad "file permissions"

# Reinstall: old Resources replaced, no temp folder left; if the previous uninstall has not restarted yet, cancel its cleanup.
print -n "old" > $G/app/Resources/old.txt
mkdir -p $V/Library/LaunchDaemons; touch $V/Library/LaunchDaemons/com.goldengateglass.cleanup.plist $V/Users/Shared/GoldenGate/disable
payload
/bin/zsh $script x x $V >/dev/null 2>&1
[[ ! -e $G/app/Resources/old.txt && ! -e $G/app/.Resources.old ]] && ok "reinstall replaces Resources, no temp folder left" || bad "Resources on reinstall"
[[ ! -e $V/Library/LaunchDaemons/com.goldengateglass.cleanup.plist && ! -e $V/Users/Shared/GoldenGate/disable ]] \
    && ok "reinstall after uninstall: cancels scheduled cleanup and its disable" || bad "cleanup/disable still present"
touch $V/Users/Shared/GoldenGate/disable; payload
/bin/zsh $script x x $V >/dev/null 2>&1
[[ -e $V/Users/Shared/GoldenGate/disable ]] && ok "normal reinstall: keeps a disable set by the user" || bad "disable removed by mistake"

# Package built without Settings preview assets (not in the public repository): installs fine, keeps existing Resources.
payload; rm -rf $G/.payload/app/Resources
/bin/zsh $script x x $V >/dev/null 2>&1; rc=$?
[[ $rc == 0 && -f $G/app/GGApp.dylib && ! -e $G/.payload && -f $G/app/Resources/SettingsPreview/pond.heic ]] \
    && ok "payload without Resources: installs, keeps existing Resources" || bad "payload without Resources (rc $rc): $(find $G | sort)"
rm -rf $V; payload; rm -rf $G/.payload/app/Resources
/bin/zsh $script x x $V >/dev/null 2>&1; rc=$?
[[ $rc == 0 && -f $G/app/GGApp.dylib && ! -e $G/app/Resources ]] \
    && ok "fresh install without Resources" || bad "fresh install without Resources (rc $rc): $(find $G | sort)"
exit $fail
