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

## Incident (mine, 03:00 PDT): a test removed the real old app from /Applications

While testing the new installer in a sandbox (temporary HOME and `SPOOFER_APP_DIR`, `launchctl` stubbed),
`setup.sh`'s cleanup of old-named apps also looked in the hard-coded `/Applications` and removed the real
`/Applications/iOS GPS Spoofer.app` on this Mac. It was not running. Nothing else was touched: saved
places (`~/Library/Application Support/iOS GPS Spoofer/`), the helper environment and the library are
intact, and `launchctl` was a stub, so no login item was changed.

- **Root cause (fixed):** with `SPOOFER_APP_DIR` set, `setup.sh` must touch only that folder, for both the
  install-time cleanup and `--uninstall`. It now does.
- **Restored:** rebuilt and reinstalled the previous version (v2.3.0, commit 1dece0f, from `main`) with the
  old installer into `/Applications`, so this Mac is back to the state it was in. See the progress log.
- **Lesson applied:** every later installer test sets `SPOOFER_APP_DIR` and a temporary `HOME`.

## Progress log

| Time | Commit | What |
|---|---|---|
| 02:36 | e74dbe6 | AnyWhere rename in scripts/CI, icon pipeline (`brand/make-icons.py`), data migration, tests |
| 02:41 | 01166cb | iPhone product name, ™ on main surfaces, offer to trash the old-named app |
| 02:47 | 0e7da80 | Pairing-file assistant (File ▸ Pairing File for the iPhone App…, ⇧⌘K), Desktop default, readiness messages |
| 02:50 | 07dd249 | Docs: names table, download-the-app install route, pairing steps |
| 02:55 | 55eb6dc | Palette follows the logo; offscreen renderer for UI checks |
| 03:00 | (next) | Launch self-test (`ANYWHERE_SELF_TEST=1`), installer gate + atomic swap + login-item repair, updater reports failures, CI runs the app |

## Blocked / needs a real device or the owner

(appended as found)
