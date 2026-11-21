#!/bin/zsh
# Tests the ggapp tool. Does not touch /Users/Shared, global defaults or the real launchd: GG_ROOT (install directory),
# GG_PREFS (plist replacing the global domain), GG_HOME (logs), LAUNCHCTL (fake script that logs commands and keeps the variable in a file).
# Run: ggapp/tests/cli.sh   (exits 1 if any case fails)
set -u
here=${0:A:h}; tool=${here:h}/ggapp
t=$(mktemp -d /tmp/gg-cli.XXXXXX); fail=0
ok() { print "OK  $1"; }
bad() { print "FAIL $1"; fail=1; }
export GG_ROOT=$t/root GG_PREFS=$t/prefs.plist GG_HOME=$t/home LAUNCHCTL=$t/launchctl
mkdir -p $t/home/Library/Logs/GoldenGate/guard
cat > $LAUNCHCTL <<'EOF'
#!/bin/zsh
# Fake launchctl: getenv/setenv/unsetenv on the env file next to it, logs every command.
f=${0:h}/env; print -r -- "$*" >> ${0:h}/launchctl.log
case $1 in
    getenv) [ -f $f ] && cat $f ;;
    setenv) print -rn -- "$3" > $f ;;
    unsetenv) rm -f $f ;;
esac
EOF
chmod +x $LAUNCHCTL
envval() { [ -f $t/env ] && cat $t/env; }

$tool session-on >/dev/null 2>&1 && bad "session-on before install must fail" || ok "session-on before install fails"
[ -z "$(envval)" ] && ok "variable not set before install" || bad "variable set before install"
mkdir -p ${here:h}/build
$tool install >/dev/null 2>&1 && [ -f $GG_ROOT/GGApp.dylib ] && [ -f $GG_ROOT/GGAppLoader.dylib ] && ok "install copies both dylibs" || bad "install"
[ -f $GG_ROOT/GGLegibility.dylib ] && ok "install copies GGLegibility.dylib" || bad "install GGLegibility"
# Resources/SettingsPreview is extracted from macOS 27 and not shipped in the repository: skip when absent.
if [ -d ${here:h}/Resources/SettingsPreview ]; then
    [ -f $GG_ROOT/Resources/SettingsPreview/clarus.heic ] && [ -f $GG_ROOT/Resources/SettingsPreview/Localizable.loctable ] && [ -d $GG_ROOT/Resources/SettingsPreview/vi.lproj ] \
        && ok "install copies Resources (Settings preview images, string tables)" || bad "install Resources"
    $tool install >/dev/null 2>&1 && [ -f $GG_ROOT/Resources/SettingsPreview/pond.heic ] && [ ! -e $GG_ROOT/.Resources.old ] && [ ! -e $GG_ROOT/.Resources.tmp ] \
        && ok "second install replaces Resources, leaves no temporary directory" || bad "second install Resources"
else
    print "SKIP install Resources: ggapp/Resources/SettingsPreview not present"
fi
$tool session-on >/dev/null 2>&1 && [ "$(envval)" = "$GG_ROOT/GGAppLoader.dylib" ] && ok "session-on sets DYLD_INSERT_LIBRARIES to the loader" || bad "session-on: $(envval)"
$tool session-on >/dev/null 2>&1 && [ "$(envval)" = "$GG_ROOT/GGAppLoader.dylib" ] && ok "second session-on does not duplicate" || bad "session-on twice: $(envval)"
$tool session-off >/dev/null 2>&1 && [ ! -f $t/env ] && ok "session-off removes the variable" || bad "session-off: $(envval)"
print -rn -- "/x/other.dylib" > $t/env
$tool session-on >/dev/null 2>&1 && [ "$(envval)" = "/x/other.dylib:$GG_ROOT/GGAppLoader.dylib" ] && ok "session-on keeps an existing dylib" || bad "keep other dylib: $(envval)"
$tool session-off >/dev/null 2>&1 && [ "$(envval)" = "/x/other.dylib" ] && ok "session-off removes only the ggapp part" || bad "remove own part: $(envval)"
rm -f $t/env
$tool off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.disable 2>/dev/null)" = 1 ] && ok "off sets GGApp.disable" || bad "off"
touch $t/home/Library/Logs/GoldenGate/guard/vn.x.excluded
$tool on >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.disable 2>/dev/null)" != 1 ] && ok "on clears GGApp.disable" || bad "on"
[ ! -e $t/home/Library/Logs/GoldenGate/guard/vn.x.excluded ] && ok "on clears the crash guard history" || bad "on did not clear the guard"
$tool set pocket off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.pocket 2>/dev/null)" = 0 ] && ok "set pocket off" || bad "set pocket off"
$tool set toolbarPress off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.toolbarPress 2>/dev/null)" = 0 ] && ok "set toolbarPress off" || bad "set toolbarPress off"
$tool set appex off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.appex 2>/dev/null)" = 0 ] && ok "set appex off" || bad "set appex off"
$tool set sidebar off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.sidebar 2>/dev/null)" = 0 ] && ok "set sidebar off" || bad "set sidebar off"
$tool set sidebarGlass on >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.sidebarGlass 2>/dev/null)" = 1 ] && ok "set sidebarGlass on" || bad "set sidebarGlass on"
$tool set sidebarCatalyst on >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.sidebarCatalyst 2>/dev/null)" = 1 ] && ok "set sidebarCatalyst on" || bad "set sidebarCatalyst on"
$tool set settingsSlider off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.settingsSlider 2>/dev/null)" = 0 ] && ok "set settingsSlider off" || bad "set settingsSlider off"
$tool set settingsMoof on >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.settingsMoof 2>/dev/null)" = 1 ] && ok "set settingsMoof on" || bad "set settingsMoof on"
$tool set windowCorners off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.windowCorners 2>/dev/null)" = 0 ] && ok "set windowCorners off" || bad "set windowCorners off"
$tool set menuGlass off >/dev/null 2>&1 && [ "$(defaults read $GG_PREFS GGApp.menuGlass 2>/dev/null)" = 0 ] && ok "set menuGlass off" || bad "set menuGlass off"
$tool set abc on >/dev/null 2>&1 && bad "set with an unknown key must fail" || ok "set with an unknown key fails"
print "test log line" > $t/home/Library/Logs/GoldenGate/ggapp.log
out=$($tool status 2>&1); print -r -- "$out" | grep -q "test log line" && print -r -- "$out" | grep -q "GGApp.pocket" && ok "status prints settings and log" || bad "status"
$tool xyz >/dev/null 2>&1 && bad "unknown command must fail" || ok "unknown command fails"
rm -rf $t
[ $fail -eq 0 ] && print "TOTAL: all passed" || print "TOTAL: some failed"
exit $fail
