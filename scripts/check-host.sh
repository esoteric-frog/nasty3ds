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
