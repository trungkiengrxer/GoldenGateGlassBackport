#!/bin/zsh
# Tests for the ggglass tool. Runs in a temp directory via GG_ROOT, never touches /Users/Shared.
# Run: ggglass/tests/cli.sh   (exits 1 if any case fails)
set -u
here=${0:A:h}; tool=${here:h}/ggglass
root=$(mktemp -d /tmp/gg-cli.XXXXXX); export GG_ROOT=$root
state=$root/state; mkdir $state; export GG_STATE=$state   # log and boots.plist (written by the dylib)
# tint behaves like 27's setSystemLegibility (ggtint): writes NSGlassTintAmount to a plist instead of the global domain and
# sends no coordinated notification to the real WindowServer.
export GG_PREFS_WRITE=$root/prefs.plist GG_TINT_NOPOST=1
fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1"; fail=1; }

$tool tint 0.3 >/dev/null 2>&1 && [ "$(defaults read $root/settings tintAmount 2>/dev/null)" = "0.3" ] && ok "tint 0.3 writes tintAmount" || bad "tint 0.3"
nga=$(defaults read $root/prefs NSGlassTintAmount 2>/dev/null)   # float as AppKit 27 writes it: 0.300000011920929
[[ -n $nga ]] && (( nga > 0.2999 && nga < 0.3001 )) && ok "tint 0.3 writes NSGlassTintAmount (like 27)" || bad "tint 0.3 did not write NSGlassTintAmount ($nga)"
out=$($tool tint 0.3 2>&1); print -r -- "$out" | grep -q "log out" && bad "tint still asks to log out: $out" || ok "tint does not ask to log out"
$tool tint --reset >/dev/null 2>&1 && ! defaults read $root/prefs NSGlassTintAmount >/dev/null 2>&1 \
    && [ "$(defaults read $root/settings tintAmount 2>/dev/null)" = "0.5" ] && ok "tint --reset removes the key, tintAmount 0.5" || bad "tint --reset"
$tool tint 0.3 >/dev/null 2>&1
# WindowServer rereads settings.plist at runtime as user _windowserver: the file must be readable by every user (cfprefsd's
# defaults write leaves mode 600).
chmod 600 $root/settings.plist; $tool tint 0.3 >/dev/null 2>&1
[ "$(stat -f %Lp $root/settings.plist)" = "644" ] && ok "tint leaves settings.plist at mode 644" || bad "settings.plist mode $(stat -f %Lp $root/settings.plist)"
$tool tint 1.5 >/dev/null 2>&1 && bad "tint 1.5 must fail" || ok "tint 1.5 fails"
[ "$(defaults read $root/settings tintAmount 2>/dev/null)" = "0.3" ] && ok "tint 1.5 does not overwrite" || bad "tint 1.5 overwrote"
$tool tint abc >/dev/null 2>&1 && bad "tint abc must fail" || ok "tint abc fails"
$tool off >/dev/null 2>&1 && [ -f $root/disable ] && ok "off creates the disable file" || bad "off"
# boots.plist is created by WindowServer (_windowserver), so the user cannot overwrite it; simulated with chmod 444.
print '(1)' > $state/boots.plist; chmod 444 $state/boots.plist
$tool on >/dev/null 2>&1 && [ ! -f $root/disable ] && ok "on removes the disable file" || bad "on"
[ ! -f $state/boots.plist ] && ok "on clears the crash guard history" || bad "on did not remove boots.plist"
print "test log line" > $state/ggglass.log
out=$($tool status 2>&1); [ $? -eq 0 ] && print -r -- "$out" | grep -q "tintAmount" && print -r -- "$out" | grep -q "test log line" && ok "status prints settings and log" || bad "status"
$tool xyz >/dev/null 2>&1 && bad "unknown command must fail" || ok "unknown command fails"

rm -rf $root
[ $fail -eq 0 ] && print "TOTAL: all passed" || print "TOTAL: some failed"
exit $fail
