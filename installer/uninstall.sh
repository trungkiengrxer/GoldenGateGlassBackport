#!/bin/zsh
# Uninstall Golden Gate Glass (runs as root: the app calls it through the admin password prompt, or `sudo zsh uninstall.sh`).
# Order chosen so DYLD_INSERT_LIBRARIES never points to a deleted file:
#  1. bootout daemon, agent;  2. remove the loader from the variable of every logged-in user;  3. delete plists, app, ggd;
#  4. keep the dylibs (WindowServer may still be armed, running apps may still launch extensions with the old variable),
#     create disable, install a LaunchDaemon that cleans up once at the next boot (a restart clears the launchctl debug
#     state and session variables).
# Test: installer/tests/uninstall.sh (GG_PREFIX prefixes every path, fake LAUNCHCTL/PKGUTIL, GG_UIDS replaces the uid list).
set -u
P=${GG_PREFIX:-}
L=${LAUNCHCTL:-/bin/launchctl}
loader=/Library/GoldenGate/app/GGAppLoader.dylib   # the variable holds the real path, no GG_PREFIX
uids=(${=${GG_UIDS:-$(/usr/bin/dscl . list /Users UniqueID | /usr/bin/awk '$2 >= 501 {print $2}')}})

$L bootout system/com.goldengateglass.daemon 2>/dev/null
for u in $uids; do $L bootout gui/$u/com.goldengateglass.agent 2>/dev/null; done

for u in $uids; do
    cur=$($L asuser $u $L getenv DYLD_INSERT_LIBRARIES 2>/dev/null)
    [[ $cur == *$loader* ]] || continue
    parts=(${(s.:.)cur}); rest=${(j.:.)${parts:#$loader}}
    if [[ -n $rest ]]; then $L asuser $u $L setenv DYLD_INSERT_LIBRARIES "$rest"
    else $L asuser $u $L unsetenv DYLD_INSERT_LIBRARIES; fi
done

rm -f $P/Library/LaunchDaemons/com.goldengateglass.daemon.plist $P/Library/LaunchAgents/com.goldengateglass.agent.plist $P/Library/GoldenGate/ggd
rm -rf "$P/Applications/Golden Gate Glass.app"
${PKGUTIL:-/usr/sbin/pkgutil} --forget com.goldengateglass.pkg >/dev/null 2>&1

mkdir -p $P/Users/Shared/GoldenGate && touch $P/Users/Shared/GoldenGate/disable
cleanup=$P/Library/LaunchDaemons/com.goldengateglass.cleanup.plist
cat > $cleanup <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.goldengateglass.cleanup</string>
	<key>ProgramArguments</key>
	<array>
		<string>/bin/rm</string>
		<string>-rf</string>
		<string>/Library/GoldenGate</string>
		<string>/Users/Shared/GoldenGate/disable</string>
		<string>/Library/LaunchDaemons/com.goldengateglass.cleanup.plist</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LaunchOnlyOnce</key>
	<true/>
</dict>
</plist>
EOF
[[ $(id -u) == 0 ]] && chown root:wheel $cleanup
chmod 644 $cleanup
print "Restart your Mac to finish uninstalling."
