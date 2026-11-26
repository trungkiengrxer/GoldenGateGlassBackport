#!/bin/zsh
# Loads build/GGIsland.dylib into ControlCenter for its next launch only (launchctl debug), then restarts ControlCenter.
# Keeps the session loader (GGAppLoader) first so GGLegibility still loads. Nothing is installed: the next normal restart,
# or a crash, brings ControlCenter back without the bridge.
#   island/tools/cc-once.sh           load once and restart
#   island/tools/cc-once.sh restore   restart ControlCenter without the bridge
set -e
here=${0:A:h}; b=${ISLAND_BUILD:-${here:h}/build}
svc=gui/$(id -u)/com.apple.controlcenter
if [[ ${1:-} == restore ]]; then
    launchctl kickstart -k $svc
    echo "ControlCenter restarted without the bridge"
    exit 0
fi
[[ -f $b/GGIsland.dylib ]] || { echo "missing $b/GGIsland.dylib, run island/build.sh"; exit 1; }
loader=$(launchctl getenv DYLD_INSERT_LIBRARIES)
libs=$b/GGIsland.dylib
[[ -n $loader ]] && libs=$loader:$libs
sudo launchctl debug $svc --environment DYLD_INSERT_LIBRARIES=$libs   # `debug` needs root
launchctl kickstart -k $svc
echo "ControlCenter restarted with DYLD_INSERT_LIBRARIES=$libs"
echo "logs: /usr/bin/log stream --style compact --predicate 'subsystem == \"com.goldengate.island\"'"
