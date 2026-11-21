#!/bin/zsh
# GGGlass tests: runs tests/host with and without the dylib, in safe scenarios.
# No root needed: GG_ROOT points to a temp directory, GG_SOURCE to the harness shader.
# Run: ggglass/tests/run-tests.sh   (exits 1 if any case fails)
set -u
here=${0:A:h}; top=${here:h}
build=$top/build; mkdir -p $build
# SkyLight is linked into the host as in WindowServer (to test the coordinated notification type limit patch).
clang -arch x86_64 -fobjc-arc -framework Foundation -framework Metal -F/System/Library/PrivateFrameworks -framework SkyLight \
    -o $build/host $here/host.m || exit 1
[ -f $build/GGGlass.dylib ] || { echo "FAIL: missing $build/GGGlass.dylib (run ggglass/build.sh)"; exit 1; }
src=${top:h}/glass-harness/shaders/glass26_replica.metal
fail=0
# Tests must not touch WindowServer's real log/boots.plist (this once made the real crash guard disable itself by mistake).
# A WindowServer running the dylib still writes the real log, so only compare boots.plist and the number of lines carrying
# test traces (test shader/tmp paths).
real=/Library/Logs/WindowServer/GoldenGate
realstate() { cat $real/boots.plist 2>/dev/null | md5; grep -cE "glass-harness/shaders|/tmp/gg-test|nonexistent.metal" $real/ggglass.log 2>/dev/null; }
real_before=$(realstate)

# check <case name> <string expected in output> <command...>
check() {
    local name=$1 want=$2; shift 2
    local out; out=$("$@" 2>&1)
    if print -r -- "$out" | grep -q -- "$want"; then print "OK  $name"
    else print "FAIL $name: want '$want'"; print -r -- "$out" | sed 's/^/      /'; fail=1; fi
}
fresh() { root=$(mktemp -d /tmp/gg-test.XXXXXX); }
run() { env GG_ROOT=$root GG_STATE=$root GG_SOURCE=$src DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib "$@" $build/host; }

fresh; check "no dylib: Apple function" "sdf=glass_background_sdf_lpf pipeline=ok" $build/host
fresh; check "dylib: replaces sdf, builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run
fresh; check "dylib: replaces no_bleed (constantValues)" "nobleed=gg27_glass_background_sdf_no_bleed_lpf" run
fresh; check "dylib: replaces via descriptor" "desc=gg27_glass_background_sdf_lpf" run
fresh; check "no dylib: Apple _lph pipeline" "lph=glass_background_sdf_lph pipeline=ok" $build/host
fresh; check "dylib: replaces _lph variant, builds pipeline with _lph vertex" "lph=gg27_glass_background_sdf_lph pipeline=ok" run
fresh; check "dylib: replaces texture SDF variant" "texsdf=gg27_glass_background_lph" run
fresh; check "dylib: replaces texture no_bleed variant (constantValues)" "texnobleed=gg27_glass_background_no_bleed_lph" run
fresh; check "dylib: name outside the list keeps Apple" "fg=glass_foreground_sdf_lph" run
fresh; check "dylib: non-glass function keeps Apple" "vert=sdf_filter_vert_lpf" run
# The 26.6 highlight layer (uber shader, constant 28 = 66) draws white over the dark 27 ring at button edges when the window is key: dropped.
fresh; check "no dylib: 26.6 uber highlight keeps Apple" "kf=fixed_frag_lph_cph pipeline=ok" $build/host
fresh; check "dylib: drops 26.6 highlight (constant 28 = 66), builds pipeline with uber vertex" "kf=gg_no_kf_highlight pipeline=ok" run
fresh; check "dylib: drops 26.6 highlight when the constant is set by name" "kfname=gg_no_kf_highlight" run
fresh; check "dylib: drops 26.6 highlight via descriptor (fixed_frag_lpf_cpf)" "kfdesc=gg_no_kf_highlight" run
fresh; check "dylib: drops 26.6 highlight on async request" "kfasync=gg_no_kf_highlight" run
fresh; check "dylib: uber with another texture function keeps Apple" "kfother=fixed_frag_lph_cph" run
fresh; touch $root/disable; check "kill-switch: 26.6 uber highlight keeps Apple" "kf=fixed_frag_lph_cph" run
fresh; run >/dev/null 2>&1
grep -q "drop 26.6 highlight" $root/ggglass.log 2>/dev/null && print "OK  log: has the 26.6 highlight drop line" || { print "FAIL log: missing the 26.6 highlight drop line"; fail=1; }
# Generic uber (config at fragment buffer 0, texture function byte 33): draws with config 66 (26.6 highlight) must be
# skipped, draws with other configs kept. The host binds 66 via setFragmentBytes and via setFragmentBuffer, 7 via setFragmentBytes.
fresh; check "no dylib: generic uber builds pipeline, draws" "uber=fixed_frag_lph_cph pipeline=ok" $build/host
fresh; check "dylib: generic uber keeps Apple function" "uber=fixed_frag_lph_cph pipeline=ok" run
n=$(grep -c "skip 26.6 highlight draw (uber generic" $root/ggglass.log 2>/dev/null)
[ "$n" = "2" ] && print "OK  generic uber: skips exactly 2 highlight draws (bytes, buffer), keeps the other draw" || { print "FAIL generic uber: skipped $n draws, want 2"; fail=1; }
# traceDraws (diagnostics, off by default): logs the draw sequence right after each of our glass draws (fragment function
# name, uber with generic/texture function), to see what WindowServer draws over the glass. Host: glass then 3 generic uber draws (66, 7, 66).
fresh; defaults write $root/settings traceDraws -bool true; run >/dev/null 2>&1
grep -q "after glass: gg27_glass_background_sdf_lph -> fixed_frag_lph_cph(generic, tf 66) -> fixed_frag_lph_cph(generic, tf 7) -> fixed_frag_lph_cph(generic, tf 66)" $root/ggglass.log 2>/dev/null \
    && print "OK  traceDraws: logs the draw sequence after glass" || { print "FAIL traceDraws: missing draw sequence"; grep "after glass" $root/ggglass.log; fail=1; }
fresh; run >/dev/null 2>&1
grep -q "after glass:" $root/ggglass.log 2>/dev/null && { print "FAIL traceDraws: logs while disabled"; fail=1; } || print "OK  traceDraws: off by default"
fresh; touch $root/disable; run >/dev/null 2>&1
grep -q "skip 26.6 highlight draw" $root/ggglass.log 2>/dev/null && { print "FAIL kill-switch: still skips generic uber draws"; fail=1; } || print "OK  kill-switch: skips no draws"
fresh; touch $root/disable; check "kill-switch: Apple function" "sdf=glass_background_sdf_lpf" run
fresh; check "build other than 25G72: Apple function" "sdf=glass_background_sdf_lpf" run GG_FAKE_BUILD=25A100
fresh; check "missing shader source: Apple function" "sdf=glass_background_sdf_lpf" env GG_ROOT=$root GG_STATE=$root GG_SOURCE=/nonexistent.metal DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host
fresh; defaults write $root/settings enabled -bool false; check "settings enabled=false: Apple function" "sdf=glass_background_sdf_lpf" run
fresh; print 'not metal' > $root/bad.metal
check "shader source fails to compile: Apple function" "sdf=glass_background_sdf_lpf" env GG_ROOT=$root GG_STATE=$root GG_SOURCE=$root/bad.metal DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host

# Crash guard: 3 loads in a row within 120 s (each exits immediately), the 3rd disables itself.
fresh
run >/dev/null 2>&1; run >/dev/null 2>&1
check "crash guard: 3rd load disables" "sdf=glass_background_sdf_lpf" run
[ -f $root/disable ] && print "OK  crash guard: disable file created" || { print "FAIL crash guard: no disable file"; fail=1; }

# The crash guard also catches slow failure loops (e.g. kernel panic then reboot, each loop > 120 s):
# 2 earlier loads 10 and 5 minutes ago, none survived 120 s, so this is the 3rd consecutive load: disable.
fresh
print "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><array><date>$(date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)</date><date>$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)</date></array></plist>" > $root/boots.plist
check "crash guard: 3 consecutive loads more than 120 s apart still disable" "sdf=glass_background_sdf_lpf" run
[ -f $root/disable ] && print "OK  slow crash guard: disable file created" || { print "FAIL slow crash guard: no disable file"; fail=1; }

# If boots.plist cannot be written (read-only directory, e.g. wrong permissions for _windowserver) the crash guard cannot protect: keep Apple.
fresh; mkdir $root/ro; chmod 555 $root/ro
check "state directory not creatable/writable: Apple function" "sdf=glass_background_sdf_lpf" env GG_ROOT=$root GG_STATE=$root/ro/state GG_SOURCE=$src DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host
chmod 755 $root/ro

# WindowServer runs the constructor as root, then drops to _windowserver: files the dylib creates must be writable by every
# user (666), otherwise later logging and clearing the crash guard history both break.
fresh; run >/dev/null 2>&1
for f in ggglass.log boots.plist; do
    [ "$(stat -f %Lp $root/$f 2>/dev/null)" = "666" ] && print "OK  $f mode 666" || { print "FAIL $f mode $(stat -f %Lp $root/$f 2>/dev/null), want 666"; fail=1; }
done

# The WindowServer sandbox only allows reading GG_ROOT (settings, kill-switch); log and boots.plist must live in GG_STATE
# (default /Library/Logs/WindowServer/GoldenGate, writable in the sandbox). If GG_STATE is missing the dylib creates it, mode 777.
fresh; state=$root/state; defaults write $root/settings tintAmount -float 0.3
env GG_ROOT=$root GG_STATE=$state GG_SOURCE=$src DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host >/dev/null 2>&1
grep -q "tint 0.30" $state/ggglass.log 2>/dev/null && print "OK  log in GG_STATE, settings read from GG_ROOT" || { print "FAIL log not in GG_STATE or settings not read"; fail=1; }
[ -f $state/boots.plist ] && [ ! -f $root/boots.plist ] && print "OK  boots.plist in GG_STATE" || { print "FAIL boots.plist not in GG_STATE"; fail=1; }
[ "$(stat -f %Lp $state 2>/dev/null)" = "777" ] && print "OK  GG_STATE mode 777" || { print "FAIL GG_STATE mode $(stat -f %Lp $state 2>/dev/null), want 777"; fail=1; }

# The log has a replacement line.
fresh; run >/dev/null 2>&1
grep -q "replace glass_background_sdf_lpf" $root/ggglass.log 2>/dev/null && print "OK  log: has a replacement line" || { print "FAIL log: missing replacement line"; cat $root/ggglass.log 2>/dev/null; fail=1; }

# No Metal device / compilation at load time (too early inside WindowServer): compile only after the first request.
fresh; run GG_TRACE=1 >/dev/null 2>&1
first_req=$(grep -n "requested " $root/ggglass.log | head -1 | cut -d: -f1); compile=$(grep -n "compiling " $root/ggglass.log | head -1 | cut -d: -f1)
[ -n "$first_req" ] && [ -n "$compile" ] && [ $compile -gt $first_req ] && print "OK  lazy compile (after the first request)" || { print "FAIL compiled before the first request (request line $first_req, compile line $compile)"; fail=1; }

# tintAmount written by the ggglass tool must be read by the dylib (log shows tint 0.30).
fresh; GG_ROOT=$root GG_PREFS_WRITE=$root/prefs.plist GG_TINT_NOPOST=1 $top/ggglass tint 0.3 >/dev/null; run >/dev/null 2>&1
grep -q "replace glass_background_sdf_lpf -> gg27_glass_background_sdf_lpf (tint 0.30" $root/ggglass.log 2>/dev/null && print "OK  ggglass tint 0.3 -> dylib uses tint 0.30" || { print "FAIL dylib does not read tintAmount"; cat $root/ggglass.log; fail=1; }

# debugColor: the replacement colors by branch (function constant 42) and still builds a pipeline.
fresh; defaults write $root/settings debugColor -bool true
check "debugColor: still replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run
grep -q "replace glass_background_sdf_lpf.*debugColor" $root/ggglass.log 2>/dev/null && print "OK  debugColor: log records debug mode" || { print "FAIL debugColor: log does not record debug mode"; fail=1; }

# System appearance (AppleInterfaceStyle in the logged-in user's .GlobalPreferences) -> constant 46: adaptive glass takes
# light/dark from here (its face does not tell). GG_GLOBAL_PREFS points to a fake plist for tests.
fresh; defaults write $root/gp AppleInterfaceStyle Dark
check "dark appearance: still replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run GG_GLOBAL_PREFS=$root/gp.plist
grep -q "replace glass_background_sdf_lpf.*dark appearance" $root/ggglass.log 2>/dev/null && print "OK  dark appearance: logged" || { print "FAIL dark appearance: not logged"; fail=1; }
fresh; defaults write $root/gp AppleShowScrollBars Always
run GG_GLOBAL_PREFS=$root/gp.plist >/dev/null 2>&1
grep -q "replace glass_background_sdf_lpf.*light appearance" $root/ggglass.log 2>/dev/null && print "OK  light appearance (no AppleInterfaceStyle): logged" || { print "FAIL light appearance: not logged"; fail=1; }

# Live appearance change: every time one of our glass pipelines is bound, the dylib binds the appearance flag (buffer 28).
# WindowServer runs as _windowserver, so it cannot read the appearance file in ~/Library after startup (the flag used to
# get stuck on dark); the flag follows the Dock face in the uniforms (the Dock always follows the system appearance: #9
# light, #10 dark). The host binds uniforms with a dark Dock face.
fresh; defaults write $root/gp AppleShowScrollBars Always
run GG_GLOBAL_PREFS=$root/gp.plist HOST_DOCK=dark >/dev/null 2>&1
grep -q "bind GGLive" $root/ggglass.log 2>/dev/null && print "OK  appearance flag: bound with the glass pipeline" || { print "FAIL appearance flag: not bound"; fail=1; }
grep -q "appearance changed: dark (from Dock)" $root/ggglass.log 2>/dev/null && print "OK  appearance flag: follows the Dock face" || { print "FAIL appearance flag: does not follow the Dock face"; fail=1; }
# Initial appearance is light via a dedicated file (the machine's real appearance is not read: in Auto mode it is Dark at night).
fresh; defaults write $root/gp AppleShowScrollBars Always
run GG_GLOBAL_PREFS=$root/gp.plist HOST_DOCK=light >/dev/null 2>&1
grep -q "appearance changed" $root/ggglass.log 2>/dev/null && { print "FAIL appearance flag: light Dock in light appearance still changed it"; fail=1; } || print "OK  appearance flag: light Dock keeps the light flag"

# Runtime slider amount: buffer 28 is GGLive {appearance flag, slider amount}, 8 bytes; Darwin notify
# com.goldengate.glass.tint makes the dylib reread tintAmount without a restart.
fresh; defaults write $root/settings tintAmount -float 0.5
run HOST_WAIT=4 >/dev/null 2>&1 &
hp=$!; sleep 2
defaults write $root/settings tintAmount -float 0.3; notifyutil -p com.goldengate.glass.tint; sleep 1; wait $hp
grep -q "bind GGLive (light, tint 0.50, 8 bytes) at buffer 28" $root/ggglass.log 2>/dev/null && print "OK  GGLive: binds 8 bytes at buffer 28" || { print "FAIL GGLive: does not bind 8 bytes"; grep "buffer 28" $root/ggglass.log; fail=1; }
grep -q "runtime tint 0.30" $root/ggglass.log 2>/dev/null && print "OK  notify: changes tint at runtime" || { print "FAIL notify: tint not changed at runtime"; fail=1; }

# Coordinated notification type 12 via the MIG table: with coordinatedGlass on, the stub_routine cell of msgh_id 30591
# points to GGGlass's stub; types other than 12 and malformed messages go to the original _X. Apple code is not modified
# (an earlier byte patch killed WindowServer on 2026-11-19). Outside WindowServer there is no connection, so both paths
# return 1003; type 12 is counted.
fresh; check "coordinatedGlass off: MIG cell keeps Apple" "migcell=SkyLight" run GG_HOST_DUMP_MIG=1
check "coordinatedGlass off: callable through the cell, Apple returns 1003" "mig3=1003 mig12=1003 migbad=-304" run GG_HOST_DUMP_MIG=1
fresh; defaults write $root/settings coordinatedGlass -bool true
out=$(run GG_HOST_DUMP_MIG=1 2>&1)
print -r -- "$out" | grep -q "migcell=GGGlass" && ok2=1 || ok2=0
print -r -- "$out" | grep -q "mig3=1003 mig12=1003 migbad=-304 mig12calls=1" && [ $ok2 = 1 ] \
    && print "OK  coordinatedGlass on: MIG cell points to stub, type 12 via stub, other types and malformed messages go to Apple" \
    || { print "FAIL MIG on"; print -r -- "$out" | grep mig; fail=1; }
grep -q "redirected MIG 30591" $root/ggglass.log 2>/dev/null && print "OK  MIG: logged" || { print "FAIL MIG: not logged"; fail=1; }
fresh; defaults write $root/settings coordinatedGlass -bool true
out=$(run GG_HOST_DUMP_MIG=1 GG_MIG_EXPECT_CGX=0102030405 2>&1)
print -r -- "$out" | grep -q "migcell=SkyLight" && print -r -- "$out" | grep -q "sdf=gg27_glass_background_sdf_lpf pipeline=ok" \
    && grep -q "MIG not redirected: bytes differ" $root/ggglass.log 2>/dev/null && print "OK  MIG bytes differ: skipped, still runs" || { print "FAIL MIG bytes differ"; print -r -- "$out" | grep mig; fail=1; }
# The executable lives inside SkyLight.framework like the real WindowServer (.../SkyLight.framework/Versions/A/Resources/WindowServer):
# the slide must come from the SkyLight image, not the executable (2026-11-19: WindowServer died reading the MIG cell from the wrong one).
fresh; defaults write $root/settings coordinatedGlass -bool true
mkdir -p $root/SkyLight.framework/Versions/A/Resources; cp $build/host $root/SkyLight.framework/Versions/A/Resources/WindowServer
out=$(env GG_ROOT=$root GG_STATE=$root GG_SOURCE=$src DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib GG_HOST_DUMP_MIG=1 \
      $root/SkyLight.framework/Versions/A/Resources/WindowServer 2>&1); rc=$?
[ $rc -eq 0 ] && print -r -- "$out" | grep -q "migcell=GGGlass" && print -r -- "$out" | grep -q "mig12calls=1" \
    && print "OK  executable inside SkyLight.framework: correct MIG cell, no crash" || { print "FAIL executable inside SkyLight.framework (exit code $rc)"; print -r -- "$out" | grep -E "mig|lib=" ; fail=1; }
# Unwritable cell: must skip, not crash. GG_PATCH_NOPROTECT simulates it by skipping mach_vm_protect.
fresh; defaults write $root/settings coordinatedGlass -bool true
out=$(run GG_HOST_DUMP_MIG=1 GG_PATCH_NOPROTECT=1 2>&1); rc=$?
[ $rc -eq 0 ] && print -r -- "$out" | grep -q "migcell=SkyLight" && grep -q "MIG not redirected: write failed" $root/ggglass.log 2>/dev/null \
    && print "OK  MIG unwritable cell: skipped, no crash" || { print "FAIL MIG unwritable cell (exit code $rc)"; print -r -- "$out" | tail -3; fail=1; }

# Capture the real sdf_texture (Settings button with a white rim: the harness always has the dark ring, the remaining
# difference is QuartzCore's sdf_texture data): while one of our glass pipelines is bound and a texture is at slot 4, the
# dylib copies the texture (blit to a buffer) and the slot 1 uniforms into <state>/sdf-capture/, only in the first session
# (skipped if the directory exists), with nothing to enable.
fresh
run HOST_WAIT=3 >/dev/null 2>&1
meta=$(ls $root/sdf-capture/*.txt 2>/dev/null | head -1); bin=${meta%.txt}.bin
grep -q "8x4" "$meta" 2>/dev/null && print "OK  sdf_texture capture: 8x4 description file" || { print "FAIL sdf_texture capture: missing description file ($meta)"; fail=1; }
[ -f "$bin" ] && [ "$(stat -f %z "$bin")" = "512" ] && print "OK  sdf_texture capture: 8x4x16 bytes of data" || { print "FAIL sdf_texture capture: wrong data size"; fail=1; }
first=$(python3 -I -c "import struct,sys; print(struct.unpack('<4f', open(sys.argv[1],'rb').read(16)))" "$bin" 2>/dev/null)
[ "$first" = "(1.5, -2.25, 0.5, 1.0)" ] && print "OK  sdf_texture capture: first texel correct" || { print "FAIL sdf_texture capture: first texel $first"; fail=1; }
grep -q "uniform hex: " "$meta" 2>/dev/null && print "OK  sdf_texture capture: includes uniforms" || { print "FAIL sdf_texture capture: missing uniforms"; fail=1; }
n1=$(ls $root/sdf-capture | wc -l); run HOST_WAIT=3 >/dev/null 2>&1; n2=$(ls $root/sdf-capture | wc -l)
[ "$n1" = "$n2" ] && print "OK  sdf_texture capture: first session only" || { print "FAIL sdf_texture capture: later session still writes ($n1 -> $n2)"; fail=1; }

# debugSize: colors by the glass short side the adapter uses (function constant 45), to compare the SDF and texture variants.
fresh; defaults write $root/settings debugSize -bool true
check "debugSize: still replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run
grep -q "replace glass_background_sdf_lpf.*debugSize" $root/ggglass.log 2>/dev/null && print "OK  debugSize: log records debug mode" || { print "FAIL debugSize: log does not record debug mode"; fail=1; }
# debugEdge: solid fill by SDF distance (function constant 48): purple ring band, green interior, blue outside the edge.
fresh; defaults write $root/settings debugEdge -bool true
check "debugEdge: still replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run
grep -q "replace glass_background_sdf_lpf.*debugEdge" $root/ggglass.log 2>/dev/null && print "OK  debugEdge: log records debug mode" || { print "FAIL debugEdge: log does not record debug mode"; fail=1; }
# The 26.6 SDF rim (uber sdf_rim, constant 28 = 14) must keep the Apple function: sdf_rim also draws sidebar content,
# Dock menus and Spotlight icons (a trial build that dropped it lost those on the real machine).
fresh; check "26.6 sdf_rim keeps Apple" "rim=fixed_frag_lph_cph" run
# noHighlight27: disables the 27 highlight in the glass shader (function constant 50), A/B test for the white toolbar button rim.
fresh; defaults write $root/settings noHighlight27 -bool true
check "noHighlight27: still replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" run
grep -q "replace glass_background_sdf_lpf.*noHighlight27" $root/ggglass.log 2>/dev/null && print "OK  noHighlight27: log records mode" || { print "FAIL noHighlight27: log does not record mode"; fail=1; }
# debugScale: the texture variant encodes texels/point and distance slope into color (function constant 49).
fresh; defaults write $root/settings debugScale -bool true
check "debugScale: still replaces and builds pipeline" "texsdf=gg27_glass_background_lph" run
grep -q "replace glass_background_sdf_lpf.*debugScale" $root/ggglass.log 2>/dev/null && print "OK  debugScale: log records debug mode" || { print "FAIL debugScale: log does not record debug mode"; fail=1; }

# dumpUniforms: logs the real uniforms QuartzCore binds for glass pipelines (to tune classify on the real machine).
fresh; defaults write $root/settings dumpUniforms -bool true
check "dumpUniforms: encodes normally" "encode=ok" run
grep -q "uniform glass_background_sdf_lph off 16 hex: 00509a44" $root/ggglass.log 2>/dev/null && print "OK  dumpUniforms: logs uniforms with the Apple function name" || { print "FAIL dumpUniforms: missing uniform line"; fail=1; }
# Glass pipeline creation time (color format, thread): tests the hypothesis that a dialog is gray when it first appears
# because the replacement's pipeline compiles slowly (no binary archive like Apple's functions), so QuartzCore draws a
# placeholder meanwhile.
grep -Eq "pipeline glass_background_sdf_lph: [0-9]+ ms, pixelFormat 80, (main|bg)" $root/ggglass.log 2>/dev/null && print "OK  dumpUniforms: logs glass pipeline creation time" || { print "FAIL dumpUniforms: missing pipeline creation time line"; fail=1; }
# Deduplicate by the rounded face matrix (one line per recipe per function), not by all bytes: set 2 shares set 1's face,
# set 4 differs from set 1 by one low face bit (moving glass), so both are dropped; only set 3 has another face.
n=$(grep -c "uniform glass_background_sdf_lph " $root/ggglass.log 2>/dev/null)
[ "$n" = "2" ] && print "OK  dumpUniforms: dedup by rounded face (2 lines for 4 sets)" || { print "FAIL dumpUniforms: $n lines, want 2 (dedup by rounded face)"; fail=1; }
fresh; run >/dev/null 2>&1
grep -q "uniform " $root/ggglass.log 2>/dev/null && { print "FAIL dumpUniforms: logs while disabled"; fail=1; } || print "OK  dumpUniforms: off by default"

# Trace: logs every requested function name, including names not replaced (to learn which entries QuartzCore/WindowServer use).
fresh; run GG_TRACE=1 >/dev/null 2>&1
grep -q "requested glass_foreground_sdf_lph" $root/ggglass.log 2>/dev/null && print "OK  trace: logs names not replaced" || { print "FAIL trace: missing requested glass_foreground_sdf_lph line"; fail=1; }
fresh; run >/dev/null 2>&1
grep -q "requested glass_foreground_sdf_lph" $root/ggglass.log 2>/dev/null && { print "FAIL trace: logs while disabled"; fail=1; } || print "OK  trace: off by default"
fresh; defaults write $root/settings trace -bool true; run >/dev/null 2>&1
grep -q "requested glass_foreground_sdf_lph" $root/ggglass.log 2>/dev/null && print "OK  trace: enabled via settings" || { print "FAIL trace: settings trace has no effect"; fail=1; }

# Lag on the first Dock/Control Center open after WindowServer starts: replacements must be prebuilt on a background thread
# (warm-up) right after the first request, so later requests return immediately. The shader gets a random comment so
# Metal's disk cache misses (as right after installing a new shader).
fresh; cp $src $root/u.metal; print "// warm-up test $$ $RANDOM $(date +%s)" >> $root/u.metal
out=$(env GG_ROOT=$root GG_STATE=$root GG_SOURCE=$root/u.metal GG_HOST_WARM=1 DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host 2>&1)
ms=${${out#*warm=}%% *}; names=${out#*names=}
# Each function is built exactly once, during warm-up: 8 "replace" lines, the last one before "warm-up done".
nrep=$(grep -c "\] replace glass_" $root/ggglass.log 2>/dev/null); lastrep=$(grep -n "\] replace glass_" $root/ggglass.log | tail -1 | cut -d: -f1)
warmline=$(grep -n "warm-up done" $root/ggglass.log | head -1 | cut -d: -f1)
if [ -n "$warmline" ] && [ "$nrep" = "8" ] && [ "$lastrep" -lt "$warmline" ] && [ "$ms" -lt 10 ] 2>/dev/null \
   && ! print -r -- "$names" | tr ',' '\n' | grep -vq '^gg27_'; then
    print "OK  warm-up: 7 later glass functions returned within $ms ms"
else print "FAIL warm-up: slowest $ms ms, functions: $names"; grep -E "warm-up|replace " $root/ggglass.log | sed 's/^/      /'; fail=1; fi

# Precompiled shader (build/gg27.metallib, ggglass/build.sh): a <shader>.metallib newer than or as new as the .metal is
# loaded (saves ~1 s of compilation); a metallib older than the .metal (only the .metal reinstalled) or corrupt falls back to source.
if [ -f $build/gg27.metallib ]; then
    mrun() { env GG_ROOT=$root GG_STATE=$root GG_SOURCE=$root/gg27.metal DYLD_INSERT_LIBRARIES=$build/GGGlass.dylib $build/host; }
    fresh; cp $src $root/gg27.metal; touch -t 202001010000 $root/gg27.metal; cp $build/gg27.metallib $root/
    check "metallib newer than .metal: replaces and builds pipeline" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" mrun
    grep -q "loaded metallib $root/gg27.metallib" $root/ggglass.log 2>/dev/null && ! grep -q "compiling " $root/ggglass.log \
        && print "OK  metallib: loaded, source not compiled" || { print "FAIL metallib: not loaded"; sed 's/^/      /' $root/ggglass.log; fail=1; }
    fresh; cp $src $root/gg27.metal; cp $build/gg27.metallib $root/; touch -t 202001010000 $root/gg27.metallib
    check "metallib older than .metal: replaces" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" mrun
    grep -q "compiling $root/gg27.metal" $root/ggglass.log 2>/dev/null && ! grep -q "loaded metallib" $root/ggglass.log \
        && print "OK  stale metallib: compiles source" || { print "FAIL stale metallib still loaded"; fail=1; }
    fresh; cp $src $root/gg27.metal; touch -t 202001010000 $root/gg27.metal; print 'corrupt' > $root/gg27.metallib
    check "corrupt metallib: compiles source, still replaces" "sdf=gg27_glass_background_sdf_lpf pipeline=ok" mrun
else print "FAIL missing $build/gg27.metallib (run ggglass/build.sh)"; fail=1; fi

# Handshake with ggapp: when GGGlass is enabled it sets notify state ABI = 2 (a dedicated test name so the real name the
# app reads is untouched); with the kill-switch it does not.
abi=com.goldengate.glass.abi.test.$$
fresh; run GG_ABI_NAME=$abi HOST_WAIT=3 >/dev/null 2>&1 &
sleep 2; st=$(notifyutil -g $abi 2>/dev/null | awk '{print $2}'); wait
[ "$st" = "2" ] && print "OK  app ABI: notify state 2 when enabled" || { print "FAIL app ABI: state '$st', want 2"; fail=1; }
abi2=com.goldengate.glass.abi.test2.$$
fresh; touch $root/disable; run GG_ABI_NAME=$abi2 HOST_WAIT=3 >/dev/null 2>&1 &
sleep 2; st=$(notifyutil -g $abi2 2>/dev/null | awk '{print $2}'); wait
[ "$st" != "2" ] && print "OK  app ABI: kill-switch does not set state" || { print "FAIL app ABI: kill-switch still sets state 2"; fail=1; }

[ "$(realstate)" = "$real_before" ] && print "OK  did not touch $real" || { print "FAIL tests wrote to $real"; fail=1; }

rm -rf /tmp/gg-test.*
[ $fail -eq 0 ] && print "TOTAL: all passed" || print "TOTAL: some failed"
exit $fail
