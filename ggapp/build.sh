#!/bin/zsh
# Builds GGApp.dylib, GGAppLoader.dylib and GGLegibility.dylib (x86_64, ad-hoc signed) for macOS 26.6 (25G72).
# Swift uses SwiftUICore 26.6 SPI: interface = SDK interface + SPI/appendix.swiftinterface, combined into build/fake
# so this module replaces the SDK module at compile time. Links through SwiftUI (re-exports SwiftUICore), weakly:
# missing symbols become NULL instead of dyld stopping the app. A first link pass collects the needed SwiftUI symbols
# and generates the gg_spi_syms array that Loader.m checks with dlsym at load (if any is missing, flex and traffic
# lights are disabled).
# Run: ggapp/build.sh
set -e
here=${0:A:h}; b=${GG_BUILD:-$here/build}   # GG_BUILD: separate build directory when several sessions work in parallel
sdk=$(xcrun --show-sdk-path)
fake=$b/fake/SwiftUICore.swiftmodule
mkdir -p $fake $b/obj
cat $sdk/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/x86_64-apple-macos.swiftinterface \
    $here/SPI/appendix.swiftinterface > $fake/x86_64-apple-macos.swiftinterface
objs=()
for m in $here/Sources/*.m(N); do
    o=$b/obj/${m:t:r}.o
    clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -c -o $o $m
    objs+=$o
done
link() {   # link <output> <extra .o files>
    local out=$1; shift
    swiftc -target x86_64-apple-macos26.0 -O -module-name GGApp -emit-library -o $out \
        -I $b/fake -Xlinker -weak_framework -Xlinker SwiftUI -framework AppKit -framework QuartzCore \
        -Xlinker -install_name -Xlinker /Users/Shared/GoldenGate/GGApp.dylib \
        $here/Sources/*.swift $objs "$@"
}
print 'const char *const gg_spi_syms[] = {0};' > $b/obj/spisyms.c
clang -arch x86_64 -c -o $b/obj/spisyms.o $b/obj/spisyms.c
link $b/obj/pass1.dylib $b/obj/spisyms.o
{ print 'const char *const gg_spi_syms[] = {'
  nm -u $b/obj/pass1.dylib | sed 's/^ *_//' | grep '^\$s7SwiftUI' | sed 's/.*/  "&",/'
  print '  0};'; } > $b/obj/spisyms.c
clang -arch x86_64 -c -o $b/obj/spisyms.o $b/obj/spisyms.c
link $b/GGApp.dylib $b/obj/spisyms.o
clang -arch x86_64 -mmacosx-version-min=26.0 -O2 -Wall -dynamiclib -install_name /Users/Shared/GoldenGate/GGAppLoader.dylib \
    -o $b/GGAppLoader.dylib $here/Stage1/Stage1.c
# GGLegibility.dylib: 27 slider path, no AppKit/SwiftUI (can load into the Dock).
clang -arch x86_64 -mmacosx-version-min=26.0 -fobjc-arc -O2 -Wall -dynamiclib \
    -install_name /Users/Shared/GoldenGate/GGLegibility.dylib -framework Foundation -framework QuartzCore -framework CoreGraphics \
    -F/System/Library/PrivateFrameworks -framework SkyLight -o $b/GGLegibility.dylib $here/Legibility/Legibility.m \
    $here/Legibility/Recipe27.c $here/Legibility/Recipe.m   # in-app glass 27 recipes
codesign -f -s - $b/GGApp.dylib $b/GGAppLoader.dylib $b/GGLegibility.dylib 2>/dev/null
echo "built $b/GGApp.dylib ($(grep -c '"' $b/obj/spisyms.c) SPI symbols), $b/GGAppLoader.dylib and $b/GGLegibility.dylib"
