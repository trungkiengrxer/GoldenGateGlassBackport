#!/bin/zsh
# ABI test of GGApp.dylib: (a) every undefined SwiftUI symbol must be in the exports of the running SwiftUICore/SwiftUI
# (25G72); (b) SPI type sizes (tests/vwt.swift). Run after ggapp/build.sh. Exits 1 if any case fails.
set -u
here=${0:A:h}; b=${GG_BUILD:-${here:h}/build}; fail=0   # GG_BUILD as in build.sh
tmp=$(mktemp -d /tmp/gg-abi.XXXXXX)
[ -f $b/GGApp.dylib ] || { print "FAIL missing $b/GGApp.dylib"; exit 1; }
for f in SwiftUICore SwiftUI; do dyld_info -exports /System/Library/Frameworks/$f.framework/Versions/A/$f | awk '{print $2}'; done | sort -u > $tmp/exp
nm -u $b/GGApp.dylib | sed 's/^ *//' | grep '^_\$s7SwiftUI' | sort -u > $tmp/need
missing=$(comm -23 $tmp/need $tmp/exp)
[ -z "$missing" ] && print "OK  all $(wc -l < $tmp/need | tr -d ' ') SwiftUI symbols are in the 25G72 exports" || { print "FAIL missing symbols:"; print -r -- "$missing"; fail=1; }
swiftc -target x86_64-apple-macos26.0 -I $b/fake -Xlinker -framework -Xlinker SwiftUI -o $tmp/vwt $here/vwt.swift 2>$tmp/err || { print "FAIL build vwt"; cat $tmp/err; fail=1; }
[ -x $tmp/vwt ] && { $tmp/vwt || fail=1; }
rm -rf $tmp
[ $fail -eq 0 ] && print "TOTAL: all passed" || print "TOTAL: some failed"
exit $fail
