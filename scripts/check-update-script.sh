#!/bin/zsh
# Runs Resources/update.sh against a scratch Applications folder and a scratch data folder.
# The "release" is a zip of dist/Nasty3DS.app on this disk (N3_UPDATE_URL, N3_UPDATE_FEED): nothing comes from the network,
# and the real app and the real saves are not touched.
set -euo pipefail
R=${0:A:h:h}
[[ -d $R/dist/Nasty3DS.app ]] || { echo "Make the app first: scripts/make-app.sh"; exit 1; }
# update.sh quits a running Nasty3DS (the real one, in any folder). A check must never close the owner's game.
pgrep -x Nasty3DS >/dev/null && { echo "Nasty3DS is open. Quit it first: this check would close it."; exit 1; }
O=$(mktemp -d)
trap 'rm -rf "$O"' EXIT
mkdir -p $O/apps $O/data/saves/deep $O/empty
print -n "my save" > $O/data/saves/deep/main
ditto -c -k --keepParent $R/dist/Nasty3DS.app $O/Nasty3DS.zip
NEWEST=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $R/dist/Nasty3DS.app/Contents/Info.plist)
run() { (cd $O/empty && N3_APPS_DIR=$O/apps N3_DATA_DIR=$O/data N3_UPDATE_URL=$1 zsh < $R/Resources/update.sh) > $O/out 2>&1; }
fail() { cat $O/out; echo "FAIL: $1"; exit 1; }
save_ok() { [[ "$(cat $O/data/saves/deep/main)" == "my save" ]] || fail "$1: the save changed"; }

# A download that fails changes nothing.
run file://$O/no-such.zip && fail "a failed download must give an error"
[[ ! -e $O/apps/Nasty3DS.app && ! -e $O/data/save-backups ]] || fail "a failed download must change nothing"
save_ok "failed download"

# A Mac with no app: the piped script gets the release, copies the saves, installs the app.
run file://$O/Nasty3DS.zip || fail "the install from a download failed"
codesign --verify --deep --strict $O/apps/Nasty3DS.app || fail "the installed app is damaged"
COPY=($O/data/save-backups/*/saves/deep/main(N))
[[ ${#COPY} == 1 && "$(cat $COPY[1])" == "my save" ]] || fail "the saves were not copied first"
save_ok "install"

# The same version again: nothing changes, and no second copy of the saves.
run file://$O/Nasty3DS.zip || fail "a second run must not fail"
grep -q "Nothing is changed" $O/out || fail "the same version must not install again"
COPIES=($O/data/save-backups/*(N))
[[ ${#COPIES} == 1 ]] || fail "the same version must not copy the saves again"

# An older app on the Mac: the update replaces it and the save stays.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 0.1' $O/apps/Nasty3DS.app/Contents/Info.plist
run file://$O/Nasty3DS.zip || fail "the update of an older app failed"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $O/apps/Nasty3DS.app/Contents/Info.plist)" == $NEWEST ]] || fail "the older app was not replaced"
[[ ! -e $O/apps/Nasty3DS.app.old ]] || fail "the old app was left behind"
save_ok "update"

# A newer app on the Mac: no step back.
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 99.0' $O/apps/Nasty3DS.app/Contents/Info.plist
run file://$O/Nasty3DS.zip || fail "a newer app on the Mac must not be an error"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $O/apps/Nasty3DS.app/Contents/Info.plist)" == 99.0 ]] || fail "a newer app must stay"

# With no address given, the script reads GitHub's release list and takes the zip, not the signature file.
print -r -- '{"tag_name": "v9", "assets": [
  {"name": "Nasty3DS.zip.sig", "browser_download_url": "file://'$O'/Nasty3DS.zip.sig"},
  {"name": "Nasty3DS.zip", "browser_download_url": "file://'$O'/Nasty3DS.zip"}]}' > $O/feed.json
mkdir -p $O/apps3
(cd $O/empty && N3_APPS_DIR=$O/apps3 N3_DATA_DIR=$O/data N3_UPDATE_FEED=file://$O/feed.json zsh < $R/Resources/update.sh) > $O/out 2>&1 || fail "the install from the release list failed"
codesign --verify --deep --strict $O/apps3/Nasty3DS.app || fail "the release list way did not install the app"
print -r -- '{"message": "Not Found"}' > $O/feed.json
(cd $O/empty && N3_APPS_DIR=$O/apps3 N3_DATA_DIR=$O/data N3_UPDATE_FEED=file://$O/feed.json zsh < $R/Resources/update.sh) > $O/out 2>&1 && fail "a release list with no zip must give an error"
grep -q "no Nasty3DS release" $O/out || fail "a release list with no zip must say so"
save_ok "release list"

# The folder way (the app next to the script) still works.
mkdir -p $O/folder $O/apps2
ditto $R/dist/Nasty3DS.app $O/folder/Nasty3DS.app
cp $R/Resources/update.sh $O/folder/
N3_APPS_DIR=$O/apps2 N3_DATA_DIR=$O/data N3_UPDATE_URL=file://$O/no-such.zip zsh $O/folder/update.sh > $O/out 2>&1 || fail "the folder way failed"
codesign --verify --deep --strict $O/apps2/Nasty3DS.app || fail "the folder way did not install the app"
save_ok "folder way"
echo "PASS: check-update-script (release $NEWEST)"
