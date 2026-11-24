#!/bin/zsh
# End to end: the real app updates itself from a local feed, keeps the saves, and starts again.
# Then three bad updates must change nothing. Everything happens in a scratch folder: no real
# app, no real saves, no network, no real signing key. Needs dist/Nasty3DS.app (scripts/make-app.sh).
set -uo pipefail
T=$(mktemp -d)
# Every signature here uses a throw-away key in the scratch folder, never the owner's key.
export N3_UPDATE_KEY_FILE="$T/test-key"
ROOT=${0:A:h:h}
DIST=$ROOT/dist/Nasty3DS.app
[[ -d $DIST ]] || { echo "No dist/Nasty3DS.app: run scripts/make-app.sh (or scripts/make-release.sh) first"; rm -rf "$T"; exit 1; }
FAILS=0
SERVER=""
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }
ok() { echo "ok   $1"; }
# The apps this check started: every process whose program is inside the scratch folder.
our_pids() { ps -axo pid=,comm= | awk -v t="$T" 'index($2, t) == 1 || index($2, "/private" t) == 1 { print $1 }'; }
cleanup() {
  [[ -n $SERVER ]] && kill $SERVER 2>/dev/null
  for p in $(our_pids); do kill $p 2>/dev/null; done
  sleep 1
  for p in $(our_pids); do kill -9 $p 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
plist() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist"; }
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }

sign() { (cd $ROOT && swift scripts/sign-update.swift sign "$1") || { echo "FAIL: signing failed"; exit 1; }; }
# Ad hoc signature again after a change, inner files first (like make-app.sh).
resign() { codesign --force -s - $1/Contents/Frameworks/*.dylib >/dev/null 2>&1; codesign --force -s - $1 >/dev/null 2>&1; }
TEST_KEY=$(cd $ROOT && swift scripts/sign-update.swift new-key) || { echo "FAIL: no test key"; exit 1; }
OTHER_KEY=$(cd $ROOT && N3_UPDATE_KEY_FILE=$T/other-key swift scripts/sign-update.swift new-key) || { echo "FAIL: no second key"; exit 1; }

# The "installed" app trusts the test key (Info.plist N3UpdatePublicKey). A second copy keeps the real constant.
mkdir -p $T/installed $T/new $T/www
ditto $DIST $T/installed/Nasty3DS.app
/usr/libexec/PlistBuddy -c "Add :N3UpdatePublicKey string $TEST_KEY" $T/installed/Nasty3DS.app/Contents/Info.plist
resign $T/installed/Nasty3DS.app
codesign --verify --deep --strict $T/installed/Nasty3DS.app || { echo "FAIL: the installed copy does not verify"; exit 1; }

# The new version: version 99.0 and a marker file.
ditto $DIST $T/new/Nasty3DS.app
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 99.0" $T/new/Nasty3DS.app/Contents/Info.plist
echo "new version" > $T/new/Nasty3DS.app/Contents/Resources/marker.txt
resign $T/new/Nasty3DS.app
(cd $T/new && ditto -c -k --keepParent Nasty3DS.app $T/new.zip)
sign $T/new.zip
# The same version as installed, signed with the trusted key: an old file sold as new.
(cd $T/installed && ditto -c -k --keepParent Nasty3DS.app $T/same.zip)
sign $T/same.zip

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server $PORT --bind 127.0.0.1 --directory $T/www >/dev/null 2>&1 &
SERVER=$!

# One case: its own installed app, its own profile with a save, its own feed.
setup_case() {
  local name=$1 zip=$2 sig=$3 installed=${4:-$T/installed/Nasty3DS.app}
  mkdir -p $T/$name/apps $T/$name/profile/saves/Azahar/test $T/www/$name
  ditto $installed $T/$name/apps/Nasty3DS.app
  head -c 65536 /dev/urandom > $T/$name/profile/saves/Azahar/test/save.bin
  cp $zip $T/www/$name/Nasty3DS.zip
  cp $sig $T/www/$name/Nasty3DS.zip.sig
  local base=http://127.0.0.1:$PORT/$name
  cat > $T/www/$name/latest.json <<JSON
{"tag_name": "v99.0", "name": "Nasty3DS 99.0", "draft": false, "prerelease": false,
 "assets": [{"name": "Nasty3DS.zip", "browser_download_url": "$base/Nasty3DS.zip"},
            {"name": "Nasty3DS.zip.sig", "browser_download_url": "$base/Nasty3DS.zip.sig"}]}
JSON
}
launch() {
  local name=$1
  N3_START_DURING_INSTALL=$T/$name/profile/games/any.cci N3_PROFILE=$T/$name/profile N3_BACKGROUND=1 N3_UPDATE_NOW=1 N3_UPDATE_FEED=http://127.0.0.1:$PORT/$name/latest.json \
    $T/$name/apps/Nasty3DS.app/Contents/MacOS/Nasty3DS >$T/$name/out.log 2>&1 &
  echo $!
}
# The PID of a Nasty3DS that runs from this program path, other than $2.
running_from() { ps -axo pid=,comm= | awk -v p="$1" -v not="$2" '($2 == p || $2 == "/private" p) && $1 != not { print $1; exit }'; }

defaults export app.nasty3ds $T/defaults-before.plist 2>/dev/null || : > $T/defaults-before.plist

# 1. A good update.
setup_case good $T/new.zip $T/new.zip.sig
SAVE=$(sum $T/good/profile/saves/Azahar/test/save.bin)
APP=$T/good/apps/Nasty3DS.app
FIRST=$(launch good)
NEWPID=""
for i in {1..180}; do
  NEWPID=$(running_from $APP/Contents/MacOS/Nasty3DS $FIRST)
  [[ -n $NEWPID && "$(plist $APP 2>/dev/null)" == 99.0 ]] && break
  sleep 0.5
done
grep -q "update: game start refused during install" $T/good/profile/core.log 2>/dev/null && ok "good: a game start during the install is refused" || fail "good: no 'game start refused during install' line"
grep -q "update: game closed" $T/good/profile/core.log 2>/dev/null && ok "good: the log says the game was closed before the install" || fail "good: no 'update: game closed' line"
[[ "$(plist $APP)" == 99.0 ]] && ok "good: the installed app is version 99.0" || fail "good: the installed app is version $(plist $APP)"
[[ -f $APP/Contents/Resources/marker.txt ]] && ok "good: the new files are in place" || fail "good: marker.txt is missing"
codesign --verify --deep --strict $APP 2>/dev/null && ok "good: the installed app passes codesign" || fail "good: codesign refuses the installed app"
[[ "$(sum $T/good/profile/saves/Azahar/test/save.bin)" == $SAVE ]] && ok "good: the save is unchanged" || fail "good: the save changed"
COPIES=($T/good/profile/save-backups/All\ saves\ before\ update\ */saves/Azahar/test/save.bin(N))
[[ ${#COPIES} -eq 1 && "$(sum "${COPIES[1]}")" == $SAVE ]] && ok "good: one copy of all saves, same bytes" || fail "good: copies of the saves: ${#COPIES}"
[[ ! -e $T/good/apps/.Nasty3DS-old.app ]] && ok "good: no old app is left" || fail "good: .Nasty3DS-old.app is left"
[[ -n $NEWPID ]] && ok "good: the new version runs from the same place (pid $NEWPID)" || fail "good: no new Nasty3DS process runs from $APP"
grep -q "update: installed 99.0" $T/good/profile/core.log 2>/dev/null && ok "good: the log says installed 99.0" || fail "good: no 'update: installed' line in core.log"
kill -0 $FIRST 2>/dev/null && fail "good: the old process still runs" || ok "good: the old process ended"
[[ -n $NEWPID ]] && kill $NEWPID 2>/dev/null

# 2. Three bad updates. Each must change nothing, and stop before the game would end.
cp $T/new.zip $T/changed.zip
printf '\x00' | dd of=$T/changed.zip bs=1 seek=4096 conv=notrunc 2>/dev/null     # one byte, after signing
cmp -s $T/new.zip $T/changed.zip && fail "setup: the changed zip did not change"
cp $T/new.zip.sig $T/changed.zip.sig
cp $T/new.zip $T/stranger.zip
(cd $ROOT && N3_UPDATE_KEY_FILE=$T/other-key swift scripts/sign-update.swift sign $T/stranger.zip)
cp $T/new.zip $T/realkey.zip; cp $T/new.zip.sig $T/realkey.zip.sig
for case in changed stranger same realkey; do
  # realkey: an installed copy with no N3UpdatePublicKey trusts only the real key, not the test key.
  if [[ $case == realkey ]]; then setup_case $case $T/$case.zip $T/$case.zip.sig $DIST; else setup_case $case $T/$case.zip $T/$case.zip.sig; fi
  APP=$T/$case/apps/Nasty3DS.app
  SAVE=$(sum $T/$case/profile/saves/Azahar/test/save.bin)
  OLD_VERSION=$(plist $APP)
  BEFORE=$(cd $APP && find . -type f -exec shasum {} + | sort | shasum)
  PID=$(launch $case)
  for i in {1..120}; do grep -q "update: stopped:" $T/$case/profile/core.log 2>/dev/null && break; sleep 0.5; done
  kill $PID 2>/dev/null
  LINE=$(grep -m1 "update: stopped:" $T/$case/profile/core.log 2>/dev/null)
  [[ -n $LINE ]] && ok "$case: refused ($LINE)" || fail "$case: no 'update: stopped:' line in core.log"
  [[ "$(plist $APP)" == $OLD_VERSION ]] && ok "$case: the version is still $OLD_VERSION" || fail "$case: the version is $(plist $APP)"
  [[ "$(cd $APP && find . -type f -exec shasum {} + | sort | shasum)" == $BEFORE ]] && ok "$case: the app bundle is unchanged" || fail "$case: the app bundle changed"
  [[ "$(sum $T/$case/profile/saves/Azahar/test/save.bin)" == $SAVE ]] && ok "$case: the save is unchanged" || fail "$case: the save changed"
  grep -q "update: game closed" $T/$case/profile/core.log 2>/dev/null && fail "$case: the game was closed before the refusal" || ok "$case: the game was not closed"
  [[ -z "$(print -l $T/$case/profile/save-backups/All\ saves\ before\ update\ *(N))" ]] && ok "$case: no copy of the saves (stopped before the game would end)" || fail "$case: a saves copy was made"
done
[[ $(grep -c "not from the Nasty3DS maker" $T/changed/profile/core.log) -ge 1 ]] || fail "changed: the reason is not the signature"
[[ $(grep -c "not from the Nasty3DS maker" $T/stranger/profile/core.log) -ge 1 ]] || fail "stranger: the reason is not the signature"
[[ $(grep -c "older version" $T/same/profile/core.log) -ge 1 ]] || fail "same: the reason is not the version"
[[ $(grep -c "not from the Nasty3DS maker" $T/realkey/profile/core.log) -ge 1 ]] || fail "realkey: the reason is not the signature"
[[ $TEST_KEY != $OTHER_KEY ]] || fail "setup: the two test keys are the same"

# The real settings, key by key (names only, never values). The owner's real app shares this domain
# and moves its own window: a changed "NSWindow Frame" key is its, if a real Nasty3DS runs now.
defaults export app.nasty3ds $T/defaults-after.plist 2>/dev/null || : > $T/defaults-after.plist
CHANGED=$(python3 - $T/defaults-before.plist $T/defaults-after.plist <<'PY'
import plistlib, sys
def load(p):
    try: return plistlib.load(open(p, 'rb'))
    except Exception: return {}
a, b = load(sys.argv[1]), load(sys.argv[2])
print("\n".join(sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))))
PY
)
OTHER=$(echo "$CHANGED" | grep -v '^NSWindow Frame ' | grep -v '^$')
FRAMES=$(echo "$CHANGED" | grep '^NSWindow Frame ')
REAL_APP=$(ps -axo pid=,command= | grep -i '/Nasty3DS.app/Contents/MacOS/Nasty3DS' | grep -v grep | grep -vF "$T" | grep -vF "/private$T")
if [[ -z $CHANGED ]]; then ok "the real app.nasty3ds settings are unchanged"
else
  echo "changed real settings: $(echo $CHANGED | tr '\n' ',' )"
  [[ -n $OTHER ]] && fail "real app.nasty3ds settings changed: $(echo $OTHER | tr '\n' ',')"
  if [[ -n $FRAMES ]]; then
    if [[ -n $REAL_APP ]]; then echo "note: a real Nasty3DS is open and moved its own window ($(echo $FRAMES | tr '\n' ','))"
    else fail "real window places changed with no real Nasty3DS open: $(echo $FRAMES | tr '\n' ',')"; fi
  fi
fi

if (( FAILS == 0 )); then echo "PASS: check-update"; else echo "FAILED: $FAILS checks"; exit 1; fi
