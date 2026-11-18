# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
