# Update Nasty3DS on another Mac

Your games and saves stay as they are. The script copies all saves first, then it replaces only the app.

## The command

1. Quit Nasty3DS.
2. Open Terminal.
3. Paste this line and press Return:

```sh
curl -fsSL https://raw.githubusercontent.com/esoteric-frog/nasty3ds/main/Resources/update.sh | zsh
```

## What it does

1. It gets the newest release from GitHub.
2. It copies all saves to `~/Library/Application Support/Nasty3DS/save-backups/`.
3. It puts the new app in `/Applications`. If that fails, the old app comes back.

It changes nothing when the Mac already has the newest version.

## Later updates

From version 0.5, the app updates itself: select **Nasty3DS > Check for Updates…**.

## What the Mac needs

- A Mac with Apple Silicon.
- Nasty3DS in `/Applications` (or no Nasty3DS at all: the script then installs it).
