#!/bin/zsh
# Runs the real AudioOut.swift against a small driver (Tests/AudioCheck). No game. It plays silence.
set -euo pipefail
R=${0:A:h:h}
O=$R/.build/audiocheck
rm -rf $O && mkdir -p $O
cd $O
swiftc -emit-module -emit-library -module-name Nasty3DSKit -parse-as-library $R/Sources/Nasty3DSKit/*.swift -o libNasty3DSKit.dylib
swiftc -swift-version 5 -I . -L . -lNasty3DSKit $R/Sources/Nasty3DS/AudioOut.swift $R/Tests/AudioCheck/main.swift -o driver
[[ -x driver ]] || { echo "FAIL: the driver did not build"; exit 1; }
DYLD_LIBRARY_PATH=$O ./driver
