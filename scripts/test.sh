#!/bin/zsh
# Runs the tests. Swift Testing lives in the Command Line Tools, and SwiftPM does not find it
# there without these paths (no full Xcode on this Mac).
set -euo pipefail
cd ${0:A:h:h}
CLT=/Library/Developer/CommandLineTools
F=$CLT/Library/Developer/Frameworks
exec swift test \
  -Xswiftc -F -Xswiftc $F \
  -Xswiftc -plugin-path -Xswiftc $CLT/usr/lib/swift/host/plugins/testing \
  -Xlinker -F -Xlinker $F -Xlinker -rpath -Xlinker $F \
  -Xlinker -rpath -Xlinker $CLT/Library/Developer/usr/lib "$@"
