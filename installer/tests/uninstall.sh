#!/bin/zsh
# Test installer/uninstall.sh on a fake GG_PREFIX tree with a fake launchctl; does not touch the real machine.
set -u
here=${0:A:h}; script=${here:h}/uninstall.sh
t=$(mktemp -d) || exit 1
trap 'rm -rf "$t"' EXIT
fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1"; fail=1; }
P=$t/prefix loader=/Library/GoldenGate/app/GGAppLoader.dylib

cat > $t/launchctl <<'EOF'
#!/bin/zsh
# Fake launchctl: logs commands; asuser <uid> <launchctl> getenv/setenv/unsetenv on the env-<uid> file.
d=${0:h}; print -r -- "$*" >> $d/calls
case $1 in
    asuser) f=$d/env-$2
            case $4 in
                getenv) [[ -f $f ]] && cat $f ;;
                setenv) print -rn -- "$6" > $f ;;
                unsetenv) rm -f $f ;;
            esac ;;
esac
exit 0
EOF
chmod +x $t/launchctl
mkdir -p $P/Library/LaunchDaemons $P/Library/LaunchAgents $P/Library/GoldenGate/app "$P/Applications/Golden Gate Glass.app/Contents" $P/Users/Shared/GoldenGate
touch $P/Library/LaunchDaemons/com.goldengateglass.daemon.plist $P/Library/LaunchAgents/com.goldengateglass.agent.plist \
    $P/Library/GoldenGate/{GGGlass.dylib,gg27.metal,gg27.metallib,ggd} $P/Library/GoldenGate/app/{GGAppLoader.dylib,GGApp.dylib,GGLegibility.dylib} \
    $P/Users/Shared/GoldenGate/settings.plist
print -rn -- "/x/a.dylib:$loader" > $t/env-501
print -rn -- "$loader" > $t/env-502

out=$(GG_PREFIX=$P LAUNCHCTL=$t/launchctl PKGUTIL=/usr/bin/true GG_UIDS="501 502" /bin/zsh $script 2>&1); rc=$?
[[ $rc == 0 ]] && ok "uninstall finished, exit 0" || bad "exit code $rc: $out"
b=$(grep -n "^bootout" $t/calls | tail -1 | cut -d: -f1); e=$(grep -n -E "(setenv|unsetenv)" $t/calls | head -1 | cut -d: -f1)
[[ -n $b && -n $e && $b -lt $e ]] && ok "bootout before changing the variable" || bad "order: $(cat $t/calls)"
grep -q "^bootout system/com.goldengateglass.daemon$" $t/calls && grep -q "^bootout gui/501/com.goldengateglass.agent$" $t/calls \
    && grep -q "^bootout gui/502/com.goldengateglass.agent$" $t/calls && ok "bootout daemon and each user's agent" || bad "bootout: $(cat $t/calls)"
[[ "$(cat $t/env-501)" == "/x/a.dylib" ]] && ok "uninstall keeps other dylibs" || bad "keep other dylibs: $(cat $t/env-501)"
[[ ! -f $t/env-502 ]] && ok "loader only: unsetenv" || bad "env-502 still present: $(cat $t/env-502)"
[[ ! -e $P/Library/LaunchDaemons/com.goldengateglass.daemon.plist && ! -e $P/Library/LaunchAgents/com.goldengateglass.agent.plist ]] \
    && ok "daemon and agent plists removed" || bad "plists still present"
[[ ! -e "$P/Applications/Golden Gate Glass.app" && ! -e $P/Library/GoldenGate/ggd ]] && ok "app and ggd removed" || bad "app/ggd still present"
[[ -f $P/Library/GoldenGate/GGGlass.dylib && -f $P/Library/GoldenGate/app/GGAppLoader.dylib ]] \
    && ok "GGGlass.dylib and ggapp dylibs kept until the next boot" || bad "dylibs removed too early"
[[ -f $P/Users/Shared/GoldenGate/disable ]] && ok "disable created" || bad "disable missing"
c=$P/Library/LaunchDaemons/com.goldengateglass.cleanup.plist
[[ -f $c ]] && plutil -lint $c >/dev/null && grep -q LaunchOnlyOnce $c && grep -q "<string>/Library/GoldenGate</string>" $c \
    && ok "one-shot cleanup plist installed for next boot" || bad "cleanup plist: $(cat $c 2>&1)"
grep -q "<string>/Users/Shared/GoldenGate</string>" $c && bad "cleanup must not remove all of /Users/Shared/GoldenGate" \
    || ok "cleanup removes only disable in /Users/Shared/GoldenGate"
[[ $out == *"Restart your Mac to finish uninstalling."* ]] && ok "restart reminder" || bad "reminder missing: $out"
exit $fail
