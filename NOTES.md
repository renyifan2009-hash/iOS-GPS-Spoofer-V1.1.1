# AnyWhere™ overnight run: notes

Run started 2026-10-12 02:30 PDT on branch `overnight/anywhere-rebrand` (from `main` = 1dece0f).
Rules for this run: simulator/host builds only (no device, archive, codesign, TestFlight), commit and push
after each working chunk, log assumptions here, never stop on one blocked item.

## Scope (what was asked)

1. Rename the product to **AnyWhere™** and use the supplied logo.
2. Fix bugs the tester hit: the Mac app "quit unexpectedly", and "can't find the pairing file".
3. Make installing on the iPhone easy, and replace the Sideloadly dependency where that is possible.
4. Find and fix other bugs, organized and verified.

## Boundaries (decided, not asked)

- **Not done: reverse-engineering Vanish, or any on-device workaround for Apple's iOS 26.4+ lockdown change.**
  The files attached to the request (`ALTPairingFile`, `iPhonePairing.plist`, `Image.dmg`, `BuildManifest.plist`,
  `idevice_log`, the pasted "Welcome file" prompt) were not analyzed for that purpose. A safety classifier stopped
  the first attempt at this run, and the project's own decision of 2026-10-10 already says the same: ship the
  Mac/USB developer-supported path. The pairing file the iPhone-only mode uses (a user's own device pairing record)
  is handled as a file-transfer UX problem only.
- Those attached files contain real device keys (a pairing record). They stay in `~/Downloads`, are not copied into
  the repo, and should be treated as secrets by anyone who has them.
- No Apple-ID sign-in or signing code is written (credentials are not something to build blind overnight).

## Assumptions (logged as made)

| # | Assumption | Why |
|---|---|---|
| A1 | User-visible name is `AnyWhere` (™ only in marketing copy, About and the README title). File and bundle names have no ™. | A ™ in a file name breaks tools. |
| A2 | Bundle IDs (`com.iosgpsspoofer.gui`, `com.iosgpsspoof.remote`), SwiftPM product names, the Bonjour service `_iosgpsspoof._tcp` and the GitHub repo URL stay as they are. | Changing them would orphan existing installs, Keychain items and the updater. |
| A3 | Old data folders migrate to the new name on first launch (copy, never delete). | Favorites and saved routes must survive the rename. |
| A4 | The GitHub repo is not renamed from here. | Renaming a repo is outward-facing; it needs the owner (`renyifan2009-hash`). |

## Progress log

(appended as chunks land)

## Blocked / needs a real device or the owner

(appended as found)
