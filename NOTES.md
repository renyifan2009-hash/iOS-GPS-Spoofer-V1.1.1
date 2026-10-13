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
| A5 | Nothing was published overnight: no merge to `main`, no tag or GitHub Release, no production deploy of the landing page. Everything stayed on branches. **Later, on 2026-10-12 evening, the owner of this work authorized shipping it, and it was shipped (see "Shipped" below).** | Publishing is outward-facing and `main` is what testers install. |
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
| 09:36 | c5df4aa | Auto-stop killswitch (Location menu, Settings, countdown chip) and redacted diagnostics; 20 new tests; checked against the fake iPhone (set at start, clear at 1:02 on a 1-minute setting) |
| 09:48 | da33d59 | CodeRabbit round 3 (1 finding, valid and worse than described): a huge number typed into Custom… trapped the app (Int overflow). Bounded; the new tests crash the old code |

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

## Added after the first summary (from the `Welcome file.md` prompt)

The prompt (written with ChatGPT, kept in `~/Downloads`) is a spec for a larger, phone-first product. Read on 2026-10-12. Sorted:

- **Already done in this run:** the pairing assistant and the first-party install assistant; a Mac distribution pipeline
  as far as it can go without a paid Apple account.
- **Built now (Mac/USB path, tested):** the killswitch ("Stop spoofing after 15 min … 4 h, or custom": Location menu,
  Settings, a countdown on the card) and redaction of UDIDs, keys, tokens, Apple IDs and the Mac user name from
  Help ▸ Copy Diagnostics.
- **Not done, same boundary as before:** research into how Vanish works, the cellular off/on experiments, and moving the
  developer session so it survives with the Mac off (the prompt's phases 1 to 3). That is the iOS 26.4+ on-device route
  the project already decided not to pursue, and it cannot be tested without a real iPhone.
- **Not built, needs the owner's decisions and accounts:** subscriptions (Free/Plus/Pro/Lifetime), the 45-minute free timer,
  a billing server and website pages, Developer ID signing and notarization (a paid Apple Developer account), and
  the iPhone-side route builder, joystick, history and scheduling screens (a large simulator-testable build).

## Blocked / needs a real device or the owner

- Everything on a real iPhone: `docs/DEVICE-TESTING.md` is the checklist (pairing file over AirDrop, installing through a
  signing tool, the iPhone-only mode, update behavior).
- The iPhone-only mode on iOS 26.4+ is Apple's change and is not worked around (see Boundaries).
- GitHub repo rename: still not done. The repo belongs to `renyifan2009-hash` (a fork of SegFault42's) and the account used here (`svaka2000`) has only write access; renaming needs admin. See "Shipped" for the three files to change afterwards.
- **Audit re-check (done 2026-10-12, a second look at the 69 medium and low findings against the shipped code).** 49 are fully
  fixed, 20 were partly fixed, none were still wholly open. A skeptic agent then tried to refute each partial one: 5 fell away,
  15 stand, all rated **low** (11) or **negligible** (4). Fixed since: stray sweep no longer kills a `clear` in progress
  (core-process-06); installer waits after SIGTERM then kills, and uninstall / old-copy removal no longer stop the script half
  way (IDIST-11); a Swift older than 6 gets a plain message (IDIST-10); the docs now say the download is Apple silicon only,
  CI tests macOS 15 and the source build needs macOS 14.5+ (IDIST-06/08/10); "unknown · iOS 0" is replaced by "Waiting for
  Trust on the iPhone" in five places (UXM-04); the pairing-too-old and wrong-iPhone messages name the real cause and fix
  (PX-05/07); a saved route draft drops points that aren't places (gui-crash-02); two stale menu names in the docs.
  **Left, on purpose:** core-process-03 (a third device-list fallback; narrow), IDIST-12 (a quieter install.sh ref lookup),
  and the four negligible ones (core-process-11/14, IDIST-14, UXM-14).
- **PX-12** (the pairing-file type in the iPhone `Info.plist`): changed from Imported to Exported (hygiene: the type is in the
  app's own namespace). The re-check found that this does not settle the real risk, which is another app (SideStore, Jitterbug)
  claiming the same `.mobiledevicepairing` extension so that AnyWhere is not offered in the AirDrop list. The candidate fix is
  a second document type for `public.data`; it is not applied, because it needs a real-iPhone test with SideStore installed
  (`docs/DEVICE-TESTING.md` B3b) and it has a cost (AnyWhere would show in Open-in for any file). "Save to Files" and the
  in-app file picker cover it meanwhile.
- The release-channel update (the in-app Update downloading the release DMG, checking it and swapping it in) is built (f30a7aa) but
  cannot run until a release exists, because nothing is published overnight. Until then the in-app Update still rebuilds from
  source, and the self-test gate is what keeps that safe.

## Shipped (2026-10-12 evening, authorized by the owner)

| What | Result |
|---|---|
| `main` | Fast-forwarded to `77539c7` (nothing overwritten; `main` was an ancestor). CI on that commit: all 7 jobs green. |
| Version | `VERSION` 2.4.0. iPhone app build 3 → 4 in `iPhoneRemote/project.yml` and `SpoofRemote.expected` together (a test checks they agree). Macs on 2.4.0 now tell people whose iPhone app is still build 3 to update. The fake `pymobiledevice3` reports current = 4, old = 3. |
| Release | Tag `v2.4.0` on `77539c7`. The CI release job published **AnyWhere 2.4.0** as Latest with `AnyWhere-2.4.0.dmg`, `AnyWhere.ipa` and `SHA256SUMS.txt`. Notes written by hand (guide format, what is new, what is not verified). |
| Checked after publishing | Checksums match. The app inside the DMG reports 2.4.0 on the `release` channel, `codesign --verify` is clean, and its launch self-test passes (isolated HOME, nothing installed). The IPA is build 4, version 1.1, bundle ID `com.iosgpsspoof.remote`. Images in the notes load. |
| Landing page | `anywhere-rebrand` fast-forwarded onto `svaka2000/igs-landing` `main`; the git-connected Vercel production deploy went live (title, OG image, icons all 200). A second commit swapped the hero screenshot for the fresh CI render (it still showed the old name). Its links point at `releases/latest` and `main/install.sh`, both valid. |
| Repo rename | **Not done: blocked by permission** (write access only). Asked of whoever owns `renyifan2009-hash`: rename the repo, or give admin. Afterwards change the slug in `Sources/PhoneOnlyCore/SpoofRemoteVersion.swift`, `install.sh` and `scripts/make-app.sh`, plus the links in `README.md`, `docs/` and the landing page. GitHub redirects the old name in the meantime. |

Not verified, and said so in the release notes: nothing has been run on a real iPhone (`docs/DEVICE-TESTING.md`), and the in-app Update from a release has now been published but not yet exercised by a real installed app.

## iPhone controls (2026-10-12, branch `feature/iphone-controls`)

Asked for: the iPhone-side route builder, joystick, history and scheduling screens, so the iPhone steers the Mac.

| What | Where |
|---|---|
| Protocol: `POST /joystick` (heading + speed, 1.5 s dead-man timeout), `/pause`, `/autostop`; `/status` gained `activity`, `speed`, `heading`, `routeProgress`, `routePaused`, `autoStopAt` (all optional, so old and new Macs and iPhones mix) | `Sources/RemoteAPI/RemoteAPI.swift`, `Sources/SpooferRemote/MacRemoteServer.swift`; defaults answer 501 |
| Headless helper (`iosgpsspoof serve`): joystick, pause, route progress | `SessionRemoteController.swift`, `JoystickMotion.swift` |
| **Mac app** (Settings ▸ iPhone Remote): `/route` now really drives a route (before, only the headless helper did), plus joystick, pause, stop-after | `RemoteHost.swift`, `AppModel+RemoteControl.swift` |
| iPhone app: joystick card, route builder (stops, waits, reorder, reverse, travel mode, repeat, roads, rush hour, speed), saved and recent routes, route progress with Pause / Resume / Stop, stop-after timer | `iPhoneRemote/SpoofRemote/` (`JoystickCard`, `RouteCard`, `RouteSheets`, `RouteDraft`, `RouteLibrary`, `AutoStopRow`) |
| Rules shared with the Mac and covered by `swift test`: `Killswitch` (moved), `JoystickInput`, `JoystickPreset`, `SpeedText`, `SavedRoute` | `Sources/PhoneOnlyCore/` |
| Tests | protocol, server and bridge tests; `JoystickMotionTests`; `SessionRemoteControllerTests` (needs python3); `scripts/test-remote-bridge.py` drives the real Mac app |

**Not built: scheduling.** "Scheduling" would mean the Mac starting location changes at a set time while nobody is there.
A safety check stopped my first attempt at the supervisor for that, and I did not rebuild it another way. What exists is the
safe half: the **stop-after** timer, which only ever puts the real location back. If you want scheduled starts, decide what
should confirm them first (for example a notification that has to be accepted), then build that.

**Found and fixed on the way (the first was already in v2.4.0):** the iPhone app's bottom card could stretch tall and empty
(introduced by 3078339). The card is now a height-capped `ScrollView` with the main button pinned underneath. A flexible frame
inside `ViewThatFits` and a preference-key measurement both gave the wrong height and were dropped. The map's follow mode could
run away when the zoom was computed from the span; it is now clamped (300 to 40,000 m).

**Next release:** bump the iPhone build 4 → 5 (`iPhoneRemote/project.yml` and `SpoofRemote.expected` together) and `VERSION`,
because the iPhone app now needs a Mac that has `/joystick`, `/pause` and `/autostop` (an older Mac answers 501 and the app says
to update it). Nothing here has run on a real iPhone: `docs/DEVICE-TESTING.md`, section F.

## Pairing secrets in diagnostics (2026-10-13)

Prompted by a write-up that said a developer log had printed a private-key field: checked that our own logging and
Copy Diagnostics can't do that. No log line mentions key material, the app sets up no verbose idevice logging, and no
pairing file or key has ever been committed to this public repo (every branch checked). New
`DiagnosticsRedactorPairingTests` builds fake records in the shapes they are printed in. **They failed first:** the
redactor let through a plist's short keys (a 32-byte key is 44 characters of base64 and the long-blob rule starts at 48),
the short last line of a wrapped key, a key in a JSON dump (JSON writes `/` as `\/`, which cut it into short pieces),
key bytes as a Rust `[12, 200, ...]` list, and the host ID, iPhone identifier and Wi-Fi address. All covered now. **Still
not covered:** a short base64 string with no field name or `<data>` tag before it. Not checked: what the idevice library
prints on its own at its debug levels on the iPhone (we don't turn them on).

## SUMMARY (run closed 2026-10-12 about 05:35 PDT)

**State.** Branch `overnight/anywhere-rebrand` is 77 commits ahead of `main` (156 files, +12.5k/−1k lines), pushed. CI on the last
code change (9d41662) is green on all 7 jobs, including the launch self-test of the packaged app and of the app inside the
DMG, the Xcode 16 / macOS 15 build and the swiftly + old-SDK build. Later commits are notes, comments and one picture.
393 Mac-side tests and 111 iPhone-side tests pass. Nothing was merged, tagged, released, deployed or renamed.

**What was asked, and what happened**

| Ask | Result |
|---|---|
| Rename to AnyWhere™ with the supplied logo | Done everywhere people see it (app, menus, DMG, installer, CI, docs, iPhone app, landing branch). Icons are cut from the supplied logo by `brand/make-icons.py`. Bundle IDs, Bonjour name and the repo URL kept on purpose (A2); old data is copied to the new folder and never deleted; the old app is moved to the Trash only after the person confirms; the login item is repaired. |
| "Can't find the pairing file" | Pairing assistant: File ▸ Pairing File for the iPhone App… (⇧⌘K). It says what is missing, saves to the Desktop, shows the file in Finder, sends it with AirDrop, says what to tap on the iPhone, and can delete the copy. The iPhone app shows import errors by the button. |
| "Quit unexpectedly" (twice) | No crash log exists, so no single cause is proven. Found and fixed: a pole-latitude MapKit abort (reproduced), a macOS 15 100% CPU freeze in the menu bar item, and a Swift 6.1 compile error. The locally-built-on-a-bad-toolchain theory is now blocked by a launch self-test that every source build and every update must pass before it replaces anything. |
| "Make our own loader instead of Sideloadly" | An install assistant, not a signer (A6): downloads the release IPA, checks its checksum and that it is really AnyWhere, then hands it to Sideloadly / AltStore / SideStore. No Apple-ID code was written. |
| Bugs from the tester's screenshots, and "everything perfect" | Four audit → verify → fix passes (route engine, process layer, Mac UX, iPhone app); each finding was checked before it was fixed (ids are in the commit messages). Two CodeRabbit reviews; every finding was checked, valid ones fixed, one skipped with the reason. |

**Not done, on purpose**
- No analysis of Vanish or of the attached device files, and no workaround for Apple's iOS 26.4+ lockdown change (Boundaries).
- No Apple-ID sign-in or signing code.
- No publishing of any kind (A5).

**Not proven, needs a real device** (all of `docs/DEVICE-TESTING.md`): AirDrop of the pairing file, installing through a signing
tool, the iPhone-only mode, sleep/wake and unplug/replug, and whether ⌘Q works on the first-launch Welcome sheet (A7). The
simulator, the offscreen renderer and CI cannot show these. If the tester's crash comes back with the DMG build, the newest
`AnyWhere*.ips` in `~/Library/Logs/DiagnosticReports` is the next step.

**Mistakes of mine worth knowing:** the installer-test incident above (a test removed the real old app; restored, root cause
fixed, a memory rule written); a merge-time `git add -A` that briefly embedded agent worktrees (removed before pushing, `.claude/`
now ignored); several CI diagnostic runs were misread because `continue-on-error` reports success (fixed by printing explicit
result lines). Scratch worktrees are removed; the four `fix/*` branches are fully merged into the branch and can be deleted.
