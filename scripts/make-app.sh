#!/bin/zsh
# Makes dist/Nasty3DS.app: a copy of the app that runs on another Apple Silicon Mac.
# It holds the app, the engine and MoltenVK. It holds no game, no save data and no certificate.
# The script fails if it finds a personal name or path in the result.
set -euo pipefail
ROOT=${0:A:h:h}
cd "$ROOT"
OUT="$ROOT/dist"
APP="$OUT/Nasty3DS.app"
CORE="$ROOT/vendor/core/azahar_libretro.dylib"
MVK=/opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib
# The Source folder comes from the last commit. It must be the code that this app is built from.
[[ -z "$(git status --porcelain)" ]] || { echo "Commit your changes first: the source that ships must match the app"; exit 1; }
[[ -f "$CORE" ]] || { echo "No engine: run scripts/build-core.sh first"; exit 1; }
[[ -f "$MVK" ]] || { echo "No MoltenVK: brew install molten-vk"; exit 1; }

# -file-prefix-map: the folder path of this Mac does not go into the program.
swift build -c release --scratch-path "$ROOT/.build/app" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=nasty3ds" -Xswiftc -gnone \
  -Xcc "-ffile-prefix-map=$ROOT=nasty3ds" -Xcc -g0 2>&1 | tail -1
BIN="$ROOT/.build/app/release/Nasty3DS"

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN" "$APP/Contents/MacOS/Nasty3DS"
cp "$CORE" "$APP/Contents/Frameworks/"
cp -L "$MVK" "$APP/Contents/Frameworks/libMoltenVK.dylib"
chmod u+w "$APP/Contents/Frameworks/"*
cp Resources/Info.plist "$APP/Contents/Info.plist"

# The program finds MoltenVK inside the app, not in Homebrew.
X="$APP/Contents/MacOS/Nasty3DS"
strip -x "$X"
install_name_tool -change "$MVK" @rpath/libMoltenVK.dylib "$X"
for r in $(otool -l "$X" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}'); do
  [[ "$r" == /usr/lib/swift ]] || install_name_tool -delete_rpath "$r" "$X"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$X"
install_name_tool -id @rpath/libMoltenVK.dylib "$APP/Contents/Frameworks/libMoltenVK.dylib"

# Icon
ICONS=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONS"
swift scripts/make-icon.swift "$ICONS/../icon.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$ICONS/../icon.png" --out "$ICONS/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$ICONS/../icon.png" --out "$ICONS/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONS" -o "$APP/Contents/Resources/AppIcon.icns"

# Licenses, and the source of the engine change (the engine's license asks for this).
cp vendor/azahar/license.txt "$APP/Contents/Resources/Licenses/Azahar-GPL.txt"
cp vendor/azahar/externals/spirv-tools/LICENSE "$APP/Contents/Resources/Licenses/MoltenVK-Apache-2.0.txt"
AZAHAR=$(git -C vendor/azahar rev-parse HEAD)
cat > "$OUT/READ ME FIRST.txt" <<TXT
Nasty3DS
========
A 3DS player for the Mac. The top screen shows on the Mac. The lower screen can show on an iPhone.

You need
- A Mac with Apple Silicon (M1 or newer) and macOS $(otool -l "$CORE" | awk '/minos/{print $2; exit}') or newer.
- Your own 3DS game file (.3ds, .cci, .cxi). The app has no games and does not download games.
- Optional: an Xbox or PlayStation controller, connected in System Settings > Bluetooth.

First start
1. Move Nasty3DS to your Applications folder.
2. Open it. macOS says it cannot check the app. Click Done.
3. Open System Settings > Privacy & Security. Scroll down. Click "Open Anyway" next to Nasty3DS.
4. Open Nasty3DS again and select your game file.
5. If macOS asks about the local network, click Allow. The iPhone screen and local play need it.

Keys with no controller
Arrow keys = D-pad. The game window shows the status line at the bottom.

iPhone as the lower screen
Game menu > Use Phone for Lower Screen. Do the steps in the sheet one time.

Local play (for example a trade)
Both players start the same game, or games that can trade with each other, on the same network.
One player: Game menu > Local Play > Host a Room.
The other player: Game menu > Local Play > Join (the name of the first player).
Then use the local wireless function in the game.

Licenses
The engine inside this app is Azahar (https://github.com/azahar-emu/azahar, commit $AZAHAR),
under the GNU General Public License. The folder "Source" has the app's source code, the small
change made to the engine, and the script that builds the engine. MoltenVK is under the Apache
License 2.0. The license texts are in the app: Contents/Resources/Licenses.
TXT
mkdir -p "$OUT/Source"
git archive HEAD Package.swift Sources Tests scripts patches Resources .gitignore | tar -x -C "$OUT/Source"

# Sign (ad hoc: no developer account). Inner files first.
codesign --force -s - "$APP/Contents/Frameworks/"*.dylib
codesign --force -s - "$APP"
codesign --verify --deep --strict "$APP"

# No personal data can leave this Mac: names, home path, host names, e-mail addresses.
HOME_ROOT="/Us"; HOME_ROOT+="ers/"      # in two parts, so this script does not match itself
# Plain words, one per line (no patterns: a pattern that does not parse would switch the scan off).
# More private words (other host names, mail domains) come from a file that stays on this Mac.
WORDFILE=$(mktemp)
{ id -un; id -F | tr ' ' '\n'; scutil --get LocalHostName; scutil --get ComputerName; print -r -- "$HOME_ROOT"
  [[ -f .superpowers/private-words.txt ]] && cat .superpowers/private-words.txt; true
} | tr -d '\r' | sed 's/^ *//; s/ *$//' | awk 'length($0) >= 4' | sort -u > "$WORDFILE"
[[ $(wc -l < "$WORDFILE") -ge 3 ]] || { echo "SCAN ERROR: the word list is empty"; exit 1; }
bad_scan() { echo "$1"; rm -rf "$OUT.failed-scan"; mv "$OUT" "$OUT.failed-scan"; exit 1; }
HITS=""
find "$OUT" -type f -print0 | while IFS= read -r -d '' f; do
  rc=0; grep -qiF -f "$WORDFILE" "$f" || rc=$?                       # text, and names inside binary files
  (( rc > 1 )) && { echo "SCANERR"; break; }
  rc2=0; strings -a "$f" | grep -ciF -f "$WORDFILE" >/dev/null || rc2=$?     # no -q: an early exit would break the pipe
  (( rc2 > 1 )) && { echo "SCANERR"; break; }
  (( rc == 0 || rc2 == 0 )) && echo "$f"
done > "$WORDFILE.hits" || true
HITS=$(cat "$WORDFILE.hits")
[[ "$HITS" == *SCANERR* ]] && bad_scan "SCAN ERROR: grep failed, the result is not checked"
[[ -n "$HITS" ]] && bad_scan "PERSONAL DATA FOUND in:
$HITS"
echo "OK: $APP ($(du -sh "$APP" | cut -f1)), no personal data found"
