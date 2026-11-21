#!/bin/zsh
# Test `ggd daemon --once`. Does not touch the real launchd or WindowServer: LAUNCHCTL, KILLALL are fake scripts that log
# commands to $t/calls; GG_CONSOLE_USER, GG_WS_PID stand in for the console and the WindowServer pid.
# Usage: installer/tests/ggd.sh <path to built ggd>
set -u
ggd=${1:?path to ggd required}
t=$(mktemp -d) || exit 1
trap 'rm -rf "$t"' EXIT
fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1"; fail=1; }

cat > $t/launchctl <<'EOF'
#!/bin/zsh
# Fake launchctl: logs commands; debug returns 37 when the pending file exists; getenv/setenv use the env file.
# `asuser <uid> <command...>` runs that command (also the fake launchctl, or /bin/sh -c "..."), so the inner command
# gets its own log line.
# File dockafter: after that many setenv calls, create the dock file (GG_DOCK_FILE: the user's Dock "is running" when it exists).
d=${0:h}; print -r -- "$*" >> $d/calls
case $1 in
    debug) [[ -f $d/pending ]] && { print "Configuration failed: 37: Operation already in progress"; exit 37 }
           print "Service configured for next launch." ;;
    asuser) shift 2; exec "$@" ;;
    getenv) [[ -f $d/env ]] && cat $d/env ;;
    setenv) print -rn -- "$3" > $d/env
        if [[ -f $d/dockafter ]]; then
            n=$(( $(cat $d/setcount 2>/dev/null || print 0) + 1 )); print $n > $d/setcount
            [[ $n -ge $(cat $d/dockafter) ]] && touch $d/dock
        fi ;;
esac
EOF
cat > $t/killall <<'EOF'
#!/bin/zsh
print -r -- "killall $*" >> ${0:h}/calls
EOF
chmod +x $t/launchctl $t/killall
export LAUNCHCTL=$t/launchctl KILLALL=$t/killall GG_LOG=$t/ggd.log GG_DOCK_FILE=$t/dock
export GG_GLASS_DIR=$t/glass GG_APP_DIR=$t/app GG_ROOT=$t/shared
me=$(id -un); myuid=$(id -u)

reset() {
    rm -rf $t/glass $t/app $t/shared $t/calls $t/env $t/pending $t/ggd.log $t/dockafter $t/setcount
    mkdir -p $t/glass $t/app $t/shared
    touch $t/glass/GGGlass.dylib $t/app/GGAppLoader.dylib $t/app/GGApp.dylib $t/calls $t/dock   # default: session already has Dock
}
run() { GG_CONSOLE_USER=$1 GG_WS_PID=$2 $ggd daemon --once >/dev/null 2>&1 }
arm="debug system/com.apple.WindowServer --environment DYLD_INSERT_LIBRARIES=$t/glass/GGGlass.dylib"

reset; run root 123
a=$(grep -n -F -x -- "$arm" $t/calls | head -1 | cut -d: -f1); k=$(grep -n -F -x "killall -HUP WindowServer" $t/calls | head -1 | cut -d: -f1)
[[ -n $a && -n $k && $a -lt $k ]] && ok "login window: arm GGGlass, then restart WindowServer" || bad "arm then restart: $(cat $t/calls)"
grep -q setenv $t/calls && bad "login window must not set the variable" || ok "login window: variable not set"

reset; run $me 123
grep -q "killall" $t/calls && bad "logged in but WindowServer was restarted" || ok "logged in: WindowServer not restarted"
grep -q -F -x -- "$arm" $t/calls && ok "logged in: still armed for the next launch" || bad "not armed while logged in: $(cat $t/calls)"
grep -q -F -- "asuser $myuid $t/launchctl setenv DYLD_INSERT_LIBRARIES $t/app/GGAppLoader.dylib" $t/calls \
    && ok "variable set for the logged-in user's gui" || bad "set variable: $(cat $t/calls)"

# Fresh login (no Dock yet): the console changes before launchd creates the gui domain, so setenv at that point lands in
# the user domain, which gui does not inherit; each asuser call during login costs up to ~650 ms, so the domain is not
# queried. Keep setting until the user's Dock runs (checked in-process), then set once more to land in gui. The domain is
# new, so no getenv.
reset; rm $t/dock; print 3 > $t/dockafter; run $me 123
[[ $(grep -c "^asuser $myuid $t/launchctl setenv DYLD_INSERT_LIBRARIES $t/app/GGAppLoader.dylib$" $t/calls) == 4 ]] \
    && ok "fresh login: set repeatedly until Dock runs (3 times), then once more" || bad "set until Dock runs: $(cat $t/calls)"
grep -q getenv $t/calls && bad "fresh login but getenv was called" || ok "fresh login: no getenv"
[[ "$(cat $t/env)" == "$t/app/GGAppLoader.dylib" ]] && ok "fresh login: variable holds only the loader" || bad "variable: $(cat $t/env)"
reset; rm $t/dock; GG_GUI_WAIT=0.3 run $me 123
grep -q setenv $t/calls && grep -q "Dock not running" $t/ggd.log && ok "Dock not running within the limit: still set, logged (agent handles the rest)" \
    || bad "timeout: $(cat $t/ggd.log)"

other=$(dscl . list /Users UniqueID | awk -v me=$me '$2 >= 501 && $1 != me {print $1; exit}')
if [[ -n $other ]]; then
    ouid=$(id -u $other); reset; run $other 123
    grep -q -F -- "asuser $ouid " $t/calls && ok "other console user ($other, $ouid): variable set for the right uid" || bad "other user: $(cat $t/calls)"
else
    print "SKIP other console user >= 501 (machine has only one regular user)"
fi

reset; run _windowserver 123
grep -q setenv $t/calls && bad "_windowserver must not get the variable" || ok "_windowserver: variable not set"

reset; run root 0
grep -q killall $t/calls && bad "WindowServer not running but restarted" || ok "WindowServer not running: not restarted"

reset; touch $t/shared/disable; run root 123
grep -q "^debug" $t/calls && bad "disable present but still armed" || ok "disable present: not armed"
grep -q killall $t/calls && bad "disable present but still restarted" || ok "disable present: not restarted"
grep -q "not armed" $t/ggd.log && ok "disable present: log says not armed" || bad "disable log: $(cat $t/ggd.log)"

reset; rm $t/glass/GGGlass.dylib; run root 123
grep -q "^debug" $t/calls && bad "GGGlass.dylib missing but still armed" || ok "GGGlass.dylib missing: not armed"

reset; rm $t/app/GGApp.dylib; run $me 123
grep -q setenv $t/calls && bad "GGApp.dylib missing but variable set" || ok "GGApp.dylib missing: variable not set"

reset; print -rn -- "/x/a.dylib" > $t/env; run $me 123
[[ "$(cat $t/env)" == "/x/a.dylib:$t/app/GGAppLoader.dylib" ]] && ok "keeps other dylibs already in the variable" || bad "keep other dylibs: $(cat $t/env)"

reset; touch $t/pending; GG_CONSOLE_USER=$me GG_WS_PID=123 $ggd daemon --once >/dev/null 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q "already armed (pending)" $t/ggd.log && ok "status 37: logs already armed, no error" || bad "status 37 (rc $rc): $(cat $t/ggd.log)"

$ggd bogus-arg >/dev/null 2>&1; [[ $? == 2 ]] && ok "unknown argument: exit 2" || bad "unknown argument"
exit $fail
