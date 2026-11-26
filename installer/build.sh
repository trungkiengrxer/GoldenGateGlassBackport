#!/bin/zsh
# Build the Golden Gate Glass package: ggd, the management app, installer/build/GoldenGateGlass.pkg.
# Requires ggapp/build (ggapp/build.sh), ggglass/build (ggglass/build.sh) and island/build (island/build.sh).
# GG_APP_RESOURCES overrides the ggapp resources folder (default ggapp/Resources). It holds Apple assets that are not in
# the repository; when missing, the package is still built, only the Settings preview lacks its images and strings.
# GG_VERSION sets the package and app version (CI passes the tag without its "v"); local builds use 0.0.0.
set -eu
here=${0:A:h}; repo=${here:h}; b=$here/build
version=${GG_VERSION:-0.0.0}
app="$b/Golden Gate Glass.app"
res=${GG_APP_RESOURCES:-$repo/ggapp/Resources}
for f in $repo/ggapp/build/{GGApp,GGAppLoader,GGLegibility}.dylib $repo/ggglass/build/{GGGlass.dylib,gg27.metallib} $repo/island/build/GGIsland.dylib; do
    [[ -f $f ]] || { print -u2 "missing $f: run ggapp/build.sh, ggglass/build.sh and island/build.sh first"; exit 1; }
done
rm -rf $b && mkdir -p $b/cache
sw=(swiftc -target x86_64-apple-macos26.0 -O -module-cache-path $b/cache)

$sw -o $b/ggd $here/ggd/*.swift
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
$sw -parse-as-library -o "$app/Contents/MacOS/GoldenGateGlass" $here/app/*.swift
cp $here/app/Info.plist "$app/Contents/"
plutil -replace CFBundleShortVersionString -string $version "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string $version "$app/Contents/Info.plist"
# App icon (Icon Composer file: glass "27" over the macOS 26 Tahoe still wallpaper, light and dark) -> Assets.car + AppIcon.icns.
xcrun actool --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist $b/icon-info.plist $here/app/AppIcon.icon >/dev/null
cp $here/pkg/check.sh $here/uninstall.sh "$app/Contents/Resources/"
codesign -f -s - $b/ggd "$app" 2>/dev/null

# Payload tree: replaceable files go to /Library/GoldenGate/.payload, postinstall moves them into place.
r=$b/root; pl=$r/Library/GoldenGate/.payload
mkdir -p $pl/app $r/Library/LaunchDaemons $r/Library/LaunchAgents $r/Applications
cp $repo/ggglass/build/GGGlass.dylib $repo/ggglass/build/gg27.metallib $b/ggd $pl/
cp $repo/glass-harness/shaders/glass26_replica.metal $pl/gg27.metal
cp $repo/ggapp/build/{GGApp,GGAppLoader,GGLegibility}.dylib $repo/island/build/GGIsland.dylib $pl/app/   # GGAppLoader loads GGIsland in ControlCenter
if [[ -d $res ]]; then
    cp -R $res $pl/app/Resources
else
    print -u2 "note: $res not found, building without Settings preview assets"
fi
cp $here/pkg/com.goldengateglass.daemon.plist $r/Library/LaunchDaemons/
cp $here/pkg/com.goldengateglass.agent.plist $r/Library/LaunchAgents/
cp -R "$app" $r/Applications/

# The app must not be "relocated" to another copy with the same bundle id somewhere else.
pkgbuild --analyze --root $r $b/component.plist >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO $b/component.plist
pkgbuild --root $r --component-plist $b/component.plist --scripts $here/pkg/scripts \
    --identifier com.goldengateglass.pkg --version $version --install-location / $b/component.pkg >/dev/null
# system.run('check.sh') in distribution.xml reads from productbuild's --scripts (--resources does not carry this file).
mkdir -p $b/dist-scripts && cp $here/pkg/check.sh $b/dist-scripts/ && chmod +x $b/dist-scripts/check.sh
mkdir -p $b/resources && cp $here/pkg/conclusion.html $b/resources/   # Installer conclusion page
sed "s/__VERSION__/$version/" $here/pkg/distribution.xml > $b/distribution.xml
productbuild --distribution $b/distribution.xml --scripts $b/dist-scripts --resources $b/resources \
    --package-path $b $b/GoldenGateGlass.pkg >/dev/null
print "built $b/GoldenGateGlass.pkg ($version)"
