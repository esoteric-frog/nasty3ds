#!/bin/zsh
# Makes the files of a release: dist/Nasty3DS.zip and its signature dist/Nasty3DS.zip.sig.
# It publishes nothing. The owner says yes first, then runs the gh line it prints.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
scripts/make-app.sh
ZIP=dist/Nasty3DS.zip
rm -f $ZIP $ZIP.sig
ditto -c -k --keepParent dist/Nasty3DS.app $ZIP
swift scripts/sign-update.swift sign $ZIP
# The zip must hold an app that macOS accepts, as the updater checks it.
CHECK=$(mktemp -d)
trap 'rm -rf "$CHECK"' EXIT
ditto -x -k $ZIP "$CHECK"
codesign --verify --deep --strict "$CHECK/Nasty3DS.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Nasty3DS.app/Contents/Info.plist)
echo "Version: $VERSION"
echo "Files: $ROOT/$ZIP"
echo "       $ROOT/$ZIP.sig"
echo "To publish: the owner must say yes first. Then: gh release create v$VERSION $ZIP $ZIP.sig --repo <the repo>"
