#!/bin/zsh
# Build GGGlass.dylib (x86_64, ad-hoc signed). The shader is compiled at runtime from
# glass-harness/shaders/glass26_replica.metal (installed as /Library/GoldenGate/gg27.metal).
# Run: ggglass/build.sh
set -e
here=${0:A:h}
mkdir -p $here/build
clang -arch x86_64 -dynamiclib -fobjc-arc -O2 -Wall \
    -framework Foundation -framework Metal \
    -o $here/build/GGGlass.dylib $here/Sources/GGGlass/GGGlass.m
codesign -f -s - $here/build/GGGlass.dylib
# gg27.metallib: precompiled shader, installed next to gg27.metal. GGGlass loads the metallib when it is not older than
# the .metal (saves ~1 s of compilation at WindowServer startup), otherwise it compiles from source.
xcrun -sdk macosx metal -o $here/build/gg27.metallib ${here:h}/glass-harness/shaders/glass26_replica.metal
# ggtint: the writer side of the slider (like 27's setSystemLegibility), shares ggapp/Legibility/Legibility.m.
leg=${here:h}/ggapp/Legibility
clang -arch x86_64 -fobjc-arc -O2 -Wall -I $leg -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -F/System/Library/PrivateFrameworks -framework SkyLight \
    -o $here/build/ggtint $here/tools/ggtint/ggtint.m $leg/Legibility.m $leg/Recipe27.c $leg/Recipe.m
codesign -f -s - $here/build/ggtint
echo "built $here/build/GGGlass.dylib and $here/build/ggtint"
