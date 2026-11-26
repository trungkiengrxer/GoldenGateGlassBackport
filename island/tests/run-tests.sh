#!/bin/zsh
# Window-free tests: geometry, corner curve, path, animator, spring, controller, content metrics, system controls
# (island/Sources), and the bridge in GGIsland.dylib against fake ControlCenter classes. Run: island/tests/run-tests.sh
set -e
here=${0:A:h}; b=${ISLAND_BUILD:-${here:h}/build}
mkdir -p $b
swiftc -target x86_64-apple-macos26.0 -O -parse-as-library -o $b/metrics-tests ${here:h}/Sources/*.swift(N) $here/tests.swift $here/nowplaying-tests.swift
$b/metrics-tests
# Banners have their own @main (no hook in tests.swift).
swiftc -target x86_64-apple-macos26.0 -O -parse-as-library -o $b/banner-tests ${here:h}/Sources/*.swift(N) $here/banners-tests.swift
$b/banner-tests
swiftc -target x86_64-apple-macos26.0 -O -parse-as-library -o $b/airdrop-tests ${here:h}/Sources/*.swift(N) $here/airdrop-tests.swift
$b/airdrop-tests
swiftc -target x86_64-apple-macos26.0 -O -parse-as-library -o $b/activities-tests ${here:h}/Sources/*.swift(N) $here/activities-tests.swift
$b/activities-tests
ISLAND_BUILD=$b ${here:h}/build.sh > /dev/null
cc=(clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -framework Foundation)
$cc -o $b/bridge-tests $here/bridge.m $b/GGIsland.dylib
$cc -DNOCLASS -o $b/bridge-noclass $here/bridge.m $b/GGIsland.dylib
$b/bridge-tests
GG_ISLAND_DISABLE=1 $b/bridge-tests
$b/bridge-noclass
