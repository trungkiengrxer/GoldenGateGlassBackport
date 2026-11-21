#!/bin/zsh
# Runs the test app tests/app.swift in a temporary .app with GGApp.dylib. Usage: tests/app.sh <mode> [VAR=value...]
# PNGs go to $OUT (default build/shots). Does not touch global defaults: GG_PREFS points at a temporary plist.
set -u
here=${0:A:h}; b=${GG_BUILD:-${here:h}/build}; m=$1; shift   # GG_BUILD as in build.sh
out=${OUT:-$b/shots}; mkdir -p $out $b/app/GGTest.app/Contents/MacOS
if [ ! -x $b/app/GGTest.app/Contents/MacOS/ggtest ] || [ $here/app.swift -nt $b/app/GGTest.app/Contents/MacOS/ggtest ]; then
    swiftc -target x86_64-apple-macos26.0 -o $b/app/GGTest.app/Contents/MacOS/ggtest $here/app.swift || exit 1
    print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>vn.gg.ggtest</string><key>CFBundleExecutable</key><string>ggtest</string></dict></plist>' > $b/app/GGTest.app/Contents/Info.plist
    codesign -f -s - $b/app/GGTest.app 2>/dev/null
fi
[ -f $b/app/prefs.plist ] || defaults write $b/app/prefs.plist GGApp.flex -bool YES
# GG_ABI_FAKE=0: the in-app glass 27 recipe (Recipe.m) is off unless a case passes GG_ABI_FAKE=2, so results do not
# depend on whether GGGlass is running on the machine (notify state com.goldengate.glass.abi).
env GG_PREFS=$b/app/prefs.plist GG_HOME=$b/app/home OUT=$out GG_LEGIBILITY=$b/GGLegibility.dylib GG_ABI_FAKE=0 "$@" \
    DYLD_INSERT_LIBRARIES=$b/GGApp.dylib $b/app/GGTest.app/Contents/MacOS/ggtest $m
