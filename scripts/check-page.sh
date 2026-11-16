#!/bin/zsh
# End to end in WebKit (Safari's engine): real PhoneServer, real page over https, wss, frames, touch.
set -euo pipefail
R=${0:A:h:h}
O=$R/.build/pagecheck
rm -rf $O && mkdir -p $O
cd $O
swiftc -emit-module -emit-library -module-name Nasty3DSKit -parse-as-library $R/Sources/Nasty3DSKit/*.swift -o libNasty3DSKit.dylib
swiftc -swift-version 5 -I . -L . -lNasty3DSKit $R/Sources/Nasty3DS/PhoneServer.swift $R/Sources/Nasty3DS/LocalAddress.swift \
  $R/Sources/Nasty3DS/PhoneTLS.swift $R/Tests/PageCheck/main.swift -o driver
[[ -x driver ]] || { echo "FAIL: the driver did not build"; exit 1; }
DYLD_LIBRARY_PATH=$O ./driver
