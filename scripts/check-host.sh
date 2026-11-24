#!/bin/zsh
# Runs the real Emulator.swift and n3host.c against a fake libretro core (Tests/HostCheck).
# Fails if a second start() overlaps the first game: two threads in retro_run, or a second
# retro_init before the first retro_deinit.
set -euo pipefail
R=${0:A:h:h}
O=$R/.build/hostcheck
rm -rf $O && mkdir -p $O/mm $O/run/vendor/core $O/home
cd $O
echo "module CN3Host { header \"$R/Sources/CN3Host/include/n3host.h\" export * }" > mm/module.modulemap
clang -dynamiclib -I $R/Sources/CN3Host $R/Tests/HostCheck/stubcore.c -o run/vendor/core/azahar_libretro.dylib
swiftc -emit-module -emit-library -module-name Nasty3DSKit -parse-as-library $R/Sources/Nasty3DSKit/*.swift -o libNasty3DSKit.dylib 2>/dev/null
for f in n3host n3vk; do
  clang -c -I $R/Sources/CN3Host/include -I $R/Sources/CN3Host -I/opt/homebrew/include $R/Sources/CN3Host/$f.c -o $f.o
done
swiftc -swift-version 5 -I . -I mm -L . -lNasty3DSKit $R/Sources/Nasty3DS/Emulator.swift $R/Sources/Nasty3DS/GameView.swift \
  $R/Tests/HostCheck/main.swift n3host.o n3vk.o \
  -L/opt/homebrew/lib -lMoltenVK -Xlinker -rpath -Xlinker /opt/homebrew/lib -o run/driver
[[ -x run/driver ]] || { echo "FAIL: the driver did not build"; exit 1; }
cd run
# CFFIXED_USER_HOME keeps the log and saves out of the real Application Support folder.
CFFIXED_USER_HOME=$O/home DYLD_LIBRARY_PATH=$O ./driver twice > $O/twice.out 2>&1 || true
cat $O/twice.out
# The fake core's counters start again when the dylib loads again, so count lines, not call numbers.
awk '
  /TWO THREADS INSIDE retro_run/ { print "FAIL: two threads ran the core at once"; bad = 1 }
  /retro_init call/   { inits++; if (inits == 2 && deinits < 1) { print "FAIL: second retro_init came before the first retro_deinit"; bad = 1 } }
  /retro_deinit call/ { deinits++; if ($0 !~ /right now: 0/) { print "FAIL: retro_deinit ran while a thread was in retro_run"; bad = 1 } }
  END {
    if (inits != 2 || deinits != 2) { print "FAIL: expected 2 inits and 2 deinits, got " inits " and " deinits; bad = 1 }
    if (bad) exit 1
    print "PASS: check-host"
  }' $O/twice.out

# The sound effects of the core (for the controller rumble) must reach Emulator.onEffects.
CFFIXED_USER_HOME=$O/home DYLD_LIBRARY_PATH=$O ./driver sfx > $O/sfx.out 2>&1 || true
grep -Eq '^effects has=true frames=[1-9][0-9]* bad=0$' $O/sfx.out || { cat $O/sfx.out; echo "FAIL: the sound effects did not reach onEffects"; exit 1; }
# A core without that output: no effects, and no crash.
mkdir -p $O/old/vendor/core && cp driver $O/old/
clang -dynamiclib -DNO_SFX -I $R/Sources/CN3Host $R/Tests/HostCheck/stubcore.c -o $O/old/vendor/core/azahar_libretro.dylib
(cd $O/old && CFFIXED_USER_HOME=$O/home DYLD_LIBRARY_PATH=$O ./driver sfx > $O/nosfx.out 2>&1 || true)
grep -q '^effects has=false frames=0 bad=0$' $O/nosfx.out || { cat $O/nosfx.out; echo "FAIL: a core with no sound effects output must give has=false"; exit 1; }
echo "PASS: check-host sound effects"

# Flip Upside Down: the core asks the host for the tilt sensor. It must read "flat" at the start,
# the upside-down value after the switch, and "flat" again in the next game. The top picture turns.
CFFIXED_USER_HOME=$O/home DYLD_LIBRARY_PATH=$O ./driver flip > $O/flip.out 2>&1 || true
want() { grep -Eq -- "$1" $O/flip.out || { cat $O/flip.out; echo "FAIL: flip: $2"; exit 1; } }
want '^\[stub\] accel enable=1 gyro enable=1$' "the host did not give the tilt sensor"
want '^flip: upsideDown=false$' "a game must start not flipped"
[[ "$(grep -E '^\[stub\] accel [-0-9]' $O/flip.out | tr '\n' '|')" == "[stub] accel 0.000 -1.000 0.000 gyro 0.000|[stub] accel 0.000 0.500 0.866 gyro 0.000|[stub] accel 0.000 -1.000 0.000 gyro 0.000|" ]] \
  || { cat $O/flip.out; echo "FAIL: flip: the core must read flat, then upside down, then flat in the next game"; exit 1; }
want '^flip: top=.*a: -1\.0, b: 0\.0, c: 0\.0, d: -1\.0.* lower=.*a: 1\.0, b: 0\.0, c: 0\.0, d: 1\.0' "only the top picture must turn"
want '^flip: topFrame=\(0\.0, 0\.0, 800\.0, 480\.0\)$' "the turned top picture must stay in its place"
want '^flip: back top=.*a: 1\.0, b: 0\.0, c: 0\.0, d: 1\.0' "the top picture must turn back"
want '^flip: after a new game upsideDown=false$' "a new game must start not flipped"
echo "PASS: check-host flip"
