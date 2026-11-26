#!/bin/zsh
# Builds GGIsland.dylib (ObjC bridge + Swift island, loaded into ControlCenter by GGLegibility, or once by tools/cc-once.sh) and IslandDemo.app
# (x86_64, ad-hoc signed). Run: island/build.sh
set -e
here=${0:A:h}; b=${ISLAND_BUILD:-$here/build}
mkdir -p $b/obj
clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -c -o $b/obj/OSDBridge.o $here/Bridge/OSDBridge.m
swiftc -target x86_64-apple-macos26.0 -O -module-name GGIsland -emit-library -o $b/GGIsland.dylib \
    -Xlinker -install_name -Xlinker @executable_path/GGIsland.dylib \
    -framework AppKit -framework SwiftUI -framework CoreAudio $here/Sources/*.swift $b/obj/OSDBridge.o
codesign -f -s - $b/GGIsland.dylib 2>/dev/null
app=$b/IslandDemo.app
mkdir -p $app/Contents/MacOS
swiftc -target x86_64-apple-macos26.0 -O -o $app/Contents/MacOS/IslandDemo $here/Sources/*.swift $here/demo/main.swift
print '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>vn.gg.islanddemo</string><key>CFBundleExecutable</key><string>IslandDemo</string><key>LSUIElement</key><true/></dict></plist>' > $app/Contents/Info.plist
codesign -f -s - $app 2>/dev/null
echo "built $b/GGIsland.dylib and $app"
