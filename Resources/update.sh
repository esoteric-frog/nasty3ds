#!/bin/zsh
# Updates Nasty3DS on this Mac. Run it from Terminal:   zsh update.sh
# It replaces the app only. Games, saves and the iPhone certificate are not changed.
# Before it starts, it makes a copy of all saves.
# With Nasty3DS.app next to this script, it installs that app. With no app next to it, it gets the
# newest release from GitHub. That is the way for a Mac whose Nasty3DS has no update button
# (UPDATE.md in the repo has the one line for Terminal).
set -euo pipefail
HERE=${0:A:h}
NEW="$HERE/Nasty3DS.app"
APPS=${N3_APPS_DIR:-/Applications}
DATA=${N3_DATA_DIR:-$HOME/Library/Application Support/Nasty3DS}
OLD="$APPS/Nasty3DS.app"
version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || echo 0; }

[[ "$(uname -m)" == arm64 ]] || { echo "This app needs a Mac with Apple Silicon."; exit 1; }
if [[ ! -d "$NEW" || "$NEW" -ef "$OLD" ]]; then
  # GitHub's "latest release" by repo number, as the app's own update check: a new account or repo
  # name does not break it. HTTPS and the code signature guard the download; the update button in
  # the app also checks the maker's signature. N3_UPDATE_FEED and N3_UPDATE_URL are for the check.
  GOT=$(mktemp -d)
  trap 'rm -rf "$GOT"' EXIT
  echo "Getting the newest Nasty3DS…"
  URL=${N3_UPDATE_URL:-}
  if [[ -z "$URL" ]]; then
    FEED=${N3_UPDATE_FEED:-https://api.github.com/repositories/1459367212/releases/latest}
    URL=$(curl -fsSL --proto '=https,file' "$FEED" | grep -o '"browser_download_url": *"[^"]*/Nasty3DS\.zip"' | cut -d'"' -f4) || true
    [[ -n "$URL" ]] || { echo "GitHub gave no Nasty3DS release. Nothing is changed."; exit 1; }
  fi
  curl -fsSL --proto '=https,file' --proto-redir '=https' -o "$GOT/Nasty3DS.zip" "$URL" || { echo "The download failed. Nothing is changed."; exit 1; }
  ditto -x -k "$GOT/Nasty3DS.zip" "$GOT" || { echo "The download is damaged. Nothing is changed."; exit 1; }
  NEW="$GOT/Nasty3DS.app"
  [[ -d "$NEW" ]] || { echo "The download has no Nasty3DS.app. Nothing is changed."; exit 1; }
  autoload -Uz is-at-least
  if [[ -d "$OLD" ]] && is-at-least "$(version "$NEW")" "$(version "$OLD")"; then
    echo "Nasty3DS $(version "$OLD") is on this Mac and the newest release is $(version "$NEW"). Nothing is changed."
    exit 0
  fi
fi
codesign --verify --deep --strict "$NEW" || { echo "The new app is damaged. Get it again."; exit 1; }

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
  echo "Nasty3DS is updated to version $(version "$OLD")."
  echo "Your games and saves are unchanged."
else
  rm -rf "$OLD"
  [[ -d "$OLD.old" ]] && mv "$OLD.old" "$OLD"
  echo "The update failed. The old app is back in place."; exit 1
fi
