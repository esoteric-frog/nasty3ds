#!/bin/zsh
# Builds Azahar's libretro core at a pinned commit. Output: vendor/core/azahar_libretro.dylib
set -euo pipefail
ROOT=${0:A:h:h}
PIN=11eceda5e0e682a1f44e396bf954a1b9137097ca
SRC=$ROOT/vendor/azahar
BUILD=$SRC/build-libretro

if [[ ! -d $SRC/.git ]]; then
  git clone https://github.com/azahar-emu/azahar.git "$SRC"
fi
git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$PIN"
git -C "$SRC" submodule update --init --recursive --depth 1

for p in "$ROOT"/patches/*.patch(N); do
  # Already applied (a second run) is fine; a patch that no longer fits is an error.
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p"
  elif ! git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then echo "patch does not apply: $p"; exit 1; fi
done

# -ffile-prefix-map: no home folder path goes into the engine file (it can be given to other people).
MAP="-ffile-prefix-map=$SRC=azahar -ffile-prefix-map=$ROOT=nasty3ds"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DCMAKE_C_FLAGS="$MAP" -DCMAKE_CXX_FLAGS="$MAP" \
  -DENABLE_LIBRETRO=ON \
  -DENABLE_VULKAN=ON
cmake --build "$BUILD" --target citra_libretro

mkdir -p "$ROOT/vendor/core"
cp "$BUILD/bin/Release/azahar_libretro.dylib" "$ROOT/vendor/core/"
echo "OK: $ROOT/vendor/core/azahar_libretro.dylib"
