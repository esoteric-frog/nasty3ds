#!/bin/zsh
# Updates Nasty3DS on this Mac. Run it from Terminal:   zsh update.sh
# It replaces the app only. Games, saves and the iPhone certificate are not changed.
# Before it starts, it makes a copy of all saves.
set -euo pipefail
HERE=${0:A:h}
NEW="$HERE/Nasty3DS.app"
APPS=${N3_APPS_DIR:-/Applications}
DATA=${N3_DATA_DIR:-$HOME/Library/Application Support/Nasty3DS}
OLD="$APPS/Nasty3DS.app"

[[ -d "$NEW" ]] || { echo "Nasty3DS.app is not next to this script. Keep the folder together."; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "This app needs a Mac with Apple Silicon."; exit 1; }
codesign --verify --deep --strict "$NEW" || { echo "The new app is damaged. Get the folder again."; exit 1; }

# The app must not run: it writes the save when it quits.
osascript -e 'tell application "Nasty3DS" to quit' >/dev/null 2>&1 || true
for i in {1..20}; do pgrep -x Nasty3DS >/dev/null || break; sleep 0.5; done
pgrep -x Nasty3DS >/dev/null && { echo "Nasty3DS is still open. Quit it, then run this again."; exit 1; }

if [[ -d "$DATA/saves" ]]; then
  COPY="$DATA/save-backups/All saves before update $(date +%Y-%m-%d-%H%M%S)"
  mkdir -p "$COPY"
  ditto "$DATA/saves" "$COPY/saves"
  echo "Saves copied to: $COPY"
else
  echo "No saves found on this Mac. Nothing to copy."
fi

# Put the new app in place. If that fails, the old app comes back.
rm -rf "$OLD.old"
[[ -d "$OLD" ]] && mv "$OLD" "$OLD.old"
if ditto "$NEW" "$OLD" && xattr -dr com.apple.quarantine "$OLD" 2>/dev/null; codesign --verify --deep --strict "$OLD"; then
  rm -rf "$OLD.old"
  echo "Nasty3DS is updated to version $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OLD/Contents/Info.plist")."
  echo "Your games and saves are unchanged."
else
  rm -rf "$OLD"
  [[ -d "$OLD.old" ]] && mv "$OLD.old" "$OLD"
  echo "The update failed. The old app is back in place."; exit 1
fi
