# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.6.0] - 2026-11-23

### Added
- Flip Upside Down (the Flip button in the game window, also Game > Flip Upside Down): the game reads a 3DS that is upside down, and the top screen turns to show it. Some Pokemon evolve only then (Inkay, at level 30 or more). Each game starts not flipped.
- Games that read the tilt sensor now get a steady reading: a console that lies flat.
- `Resources/update.sh` with no app next to it gets the newest release from GitHub. One line in Terminal updates a Mac whose Nasty3DS has no update button. It copies all saves first.

### Changed
- Rumble: the rumble listens to the sound effects only. The music gives no rumble. Before, a drum in the music gave a thump, also in calm places.

## [0.5.0] - 2026-11-19

### Added
- Settings > Check for Updates… (also in the Nasty3DS menu): gets a new version from GitHub, checks its signature, copies all saves, installs it and starts again. Games and saves stay as they are.
- Rumble: the controller gives a thump on each big sudden sound in the game, and a soft pulse in the triggers on a sudden sharp sound. A drum in the music can give a thump too. The game window has a Rumble button with one strength slider for each game (Game > Rumble…). 0 turns it off.

### Fixed
- The iPhone home screen icon keeps working: the phone ports stay the same (a busy port gets a port for one session only, and the live connection has a backup port), the app and a test build share one pairing file, and the page keeps a copy of itself, so the icon opens before the Mac is ready and connects by itself.
- The sound stops when the Mac changes its sound device in the middle of a game (headphones, AirPlay, a TV). Now the sound starts again on the new device.

## [0.4.0] - 2026-11-18

### Added
- The lower screen can go in its own window (Game > Lower Screen in Its Own Window, or the button at the top right). The phone has priority: while it shows the lower screen, the Mac shows no second window.
- View > Enter Full Screen for Lower Screen (Shift-Command-F). When the top screen goes to full screen and the lower screen is on another display, the lower screen goes to full screen too.

### Changed
- The game windows have no title bar. The window buttons and the controls show only while the pointer moves.

## [0.3.0] - 2026-11-15

### Added
- Start screen with the game library: icons and names from the game files, Continue for the last game, Add Game, drag and drop.
- A copy of the save before each game start (the newest 10 for each game).
- Game > Show Library.
- `Resources/update.sh` to update an installed copy without a change to games or saves.

## [0.2.0] - 2026-11-15

### Added
- Lower screen on an iPhone in Safari: QR code pairing, HTTPS with a local certificate, touch.
- Local play rooms between two Macs, found by Bonjour.
- App bundle script, app icon.

### Security
- Input checks in the engine's room and local wireless code (`patches/`).

## [0.1.0] - 2026-11-15

### Added
- The engine host: Azahar's libretro core in a native Mac window, Vulkan through MoltenVK, sound, controller and keyboard input.
