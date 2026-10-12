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
| A5 | Nothing is published overnight: no merge to `main`, no tag or GitHub Release, no production deploy of the landing page. Everything is on branches (`overnight/anywhere-rebrand` here, `anywhere-rebrand` in `igs-landing`). | Publishing is outward-facing and `main` is what testers install. The CI release job and the landing branch are ready; shipping is a few commands (see "Ship it" below). |
| A6 | The "own loader" is an install assistant (download, checksum, check the app is AnyWhere, hand it to Sideloadly / AltStore / SideStore), not a new Apple-ID signer. | `docs/design/iphone-standalone.md` already rules out a home-made re-signer (Apple credentials, anisette). The assistant does everything that can be verified without them. |
| A7 | The tester's crash is treated as a locally compiled build on a mismatched toolchain (the audit's most-confirmed finding, and what happened before). It could not be reproduced here (no crash report exists on this Mac), so the fix is a gate, not a patch: every source build must pass a launch self-test before it replaces anything, and CI now launches the app on the same toolchain mix. | There is no crash log from the tester. If it happens again with the DMG build, the `.ips` file is the next step. |

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
| 03:00 | 47719d6 | Launch self-test (`ANYWHERE_SELF_TEST=1`), installer gate + atomic swap + login-item repair, updater reports failures, CI runs the app |
| 03:10 | fae4a8c, faa5eb5 | First-run fixes from the audit; install assistant (download, checksum, bundle-ID check, hand-off to Sideloadly/AltStore) |
| 03:25 | f30a7aa | Release-channel updates (DMG from the newest release, checksum, signature, self-test, atomic swap) with 14 tests on real DMGs |
| 04:20 | f1e3544 … 1d079ee | Merged the four implementers' branches (route engine, process layer, Mac UX, iPhone app): 388 + 111 tests |
| 04:40 | 6c566f7 | Fixed a Swift 6.1 data-race compile error in the startup restore (it compiled on Swift 6.4; only CI's older compiler saw it) |
| 05:00 | 5ee5745 | Found and fixed a 100% CPU freeze of the packaged app on macOS 15 (menu bar item binding) |
| 05:02 | 982e871, 9dbe88e | Removed the throwaway diagnostic workflow; wrote up what was found about the tester's crash |
| 05:09 | b62eb84 | Sidebar footer keeps "AnyWhere" on one line (CI's screenshot showed it wrapping to "AnyWh/ere") |
| 05:10 | 603d58c | Device checklist: sleep/wake, unplug/replug, force-quit recovery |
| 05:14 | 51e4fa9 | **A second crash found and fixed:** following the device to a pole (or typing latitude 90) made MapKit raise an exception nothing can catch. Every camera move now goes through `GeoPoint.mapSafe` |
| 05:16 | 8dcec36 | CodeRabbit round 2 (4 findings: 3 fixed, 1 checked and skipped: `ps -ww`, because `ps` does not truncate when piped) |
| 05:17 | 9d41662 | Route import reads and thins big files off the main thread; dragged pins, saved routes and dropped links can't hand the map a non-place |

## The tester's crash: what was found (the launch self-test earned its keep)

The self-test and the diagnostics below were written to answer "why does the tester's app quit unexpectedly".
No crash report from the tester exists, so this is what could be proven:

1. **A real freeze on macOS 15 (fixed).** On GitHub's macOS 15 runners the packaged app sat at ~100% CPU with the
   main thread inside SwiftUI's scene update, and never became responsive. Experiments (one scene removed at a time,
   built on CI) showed the cause was the `MenuBarExtra` scene: its `isInserted` binding is written back by SwiftUI during
   its own updates, and an `@Observable` setter invalidates observers even for an unchanged value, so each write caused
   another update. `App.menuBarInserted` now stores only a real change. After the fix: 0% CPU and the self-test passes on
   macOS 15. (It did not reproduce on this Mac's macOS 27.) A frozen app is what a person would force-quit.
2. **`NSApp.terminate` is ignored while the first-launch Welcome sheet is up**, when called from a timer in an inactive app
   (AppKit never even asks the delegate). The self-test works around it; whether a real ⌘Q is affected is untested
   (`docs/DEVICE-TESTING.md` A7).
3. **The merged code did not compile on Swift 6.1** (CI's Xcode 16): a `[weak self]` captured into a detached task.
   Fixed (the app now hops back through `AppModel.shared`). It had compiled on this Mac's Swift 6.4, so CI is the only check
   for the older compiler.
4. **A crash that really aborts the app (fixed):** MapKit's `setCenter` raises an Objective-C exception ("Invalid Coordinate") for
   a place it can't put on its flat map: latitude ±90 (following the device to a pole, or typing 90), NaN, or the invalid
   value MapKit itself returns when the camera is shifted past the north or south edge. Swift cannot catch that, so the app
   aborts, which macOS shows as "quit unexpectedly". The audit's verifier reproduced it. Every camera move now goes through
   `GeoPoint.mapSafe` (refuses non-places, clamps to ±85°), with unit tests; dragged pins, saved routes and dropped files are
   checked too. It is a real, reproduced way to get the "quit unexpectedly" dialog, but with no crash log from the tester it
   is not proven to be theirs.
5. Still the strongest theory for the tester's own crash (alongside 4): an app compiled locally on a toolchain/SDK mismatch, and the
   in-app Update rebuilding from source. Both are now gated by the self-test (and the release channel avoids the rebuild).

## Blocked / needs a real device or the owner

- Everything on a real iPhone: `docs/DEVICE-TESTING.md` is the checklist (pairing file over AirDrop, installing through a
  signing tool, the iPhone-only mode, update behavior).
- The iPhone-only mode on iOS 26.4+ is Apple's change and is not worked around (see Boundaries).
- GitHub repo rename, `main` merge, release tag and landing deploy: owner's call (A4, A5).
- The release-channel update (the in-app Update downloading the release DMG, checking it and swapping it in) is built (f30a7aa) but
  cannot run until a release exists, because nothing is published overnight. Until then the in-app Update still rebuilds from
  source, and the self-test gate is what keeps that safe.

## Ship it (when you are ready)

1. Review and merge `overnight/anywhere-rebrand` into `main` (CI must be green; it was green on the first push).
2. Tag a release: `git tag v2.4.0 && git push origin v2.4.0`. The CI `release` job builds the DMG and `AnyWhere.ipa`, runs the
   launch self-test, and publishes the release with `SHA256SUMS.txt`.
3. Landing page: merge `anywhere-rebrand` in `svaka2000/igs-landing`, then `vercel --prod` there.
4. Optional: rename the GitHub repo (`gh repo rename AnyWhere`), then update the slug in `Sources/PhoneOnlyCore/SpoofRemoteVersion.swift`,
   `install.sh`, `scripts/make-app.sh` (GitHub redirects the old name meanwhile).
