# Contributing to Nasty3DS

Thank you for your help. Small, clear changes are the easiest to review.

## Report a bug

Open a [GitHub issue](https://github.com/esoteric-frog/nasty3ds/issues) with the bug report form. Please include:

- your Mac model and macOS version,
- what you did, what you expected, and what happened,
- the last lines of `~/Library/Application Support/Nasty3DS/core.log`.

Do not attach game files or save files that hold personal data.

## Set up

```sh
brew install cmake ninja molten-vk
git clone https://github.com/esoteric-frog/nasty3ds.git
cd nasty3ds
scripts/test.sh          # unit tests; these need no engine
scripts/build-core.sh    # the engine, about 40 minutes, only needed to run games
```

`swift test` alone does not find the test framework with the Command Line Tools. Use `scripts/test.sh`.

For a run that must not touch your real games and saves, set `N3_PROFILE=/some/scratch/folder`.

## Branches and commits

- Work from `main` on a branch such as `fix/stuck-keys` or `feat/controller-setup`.
- Commit messages: `feat:`, `fix:`, `docs:`, `test:`, `build:`, then a short summary.

## Pull requests

1. A bug fix comes with a test or a check that fails without the fix.
2. `scripts/test.sh` and `scripts/check-host.sh` pass.
3. Changes to the phone server or to `patches/` say what a hostile device on the network can do, and why the change is safe.
4. User-facing changes update `README.md` and `CHANGELOG.md`.

## Rules for this project

- No games, keys, firmware files or copyrighted game art in the repository, in tests or in pictures.
- Changes to the engine go in `patches/` as a patch against the pinned Azahar commit. Do not send them to the Azahar project (see the README).
- All text in the app is plain and short: sentence case, no jargon.

By contributing, you agree that your work is licensed under GPL-3.0-or-later. Please follow the [Code of Conduct](CODE_OF_CONDUCT.md).
