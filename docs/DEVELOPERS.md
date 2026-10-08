# iOS GPS Spoofer: developer guide

The [README](../README.md) is for people who just want to use the app. This
page covers how it works, building it, the command-line tool, tests and
packaging.

## Contents

- [How it works](#how-it-works)
- [Building](#building)
- [Where things live](#where-things-live)
- [Engines: live and classic](#engines-live-and-classic)
- [Tunnels (iOS 17 and later)](#tunnels-ios-17-and-later)
- [The Mac app](#the-mac-app)
- [The command-line tool](#the-command-line-tool)
- [Troubleshooting with pymobiledevice3](#troubleshooting-with-pymobiledevice3)
- [Packaging](#packaging)
- [Tests and CI](#tests-and-ci)
- [Project layout](#project-layout)

## How it works

The app drives Apple's developer **location simulation** service. Xcode uses
the same service for **Product ▸ Scheme ▸ Simulate Location**. All talking to
the iPhone goes through [pymobiledevice3](https://github.com/doronz88/pymobiledevice3),
a Python tool, which the app runs as a child process.

- **iOS 17 and later.** The service is reached through an encrypted tunnel to
  the device (RemoteXPC / RSD). The command is
  `pymobiledevice3 developer dvt simulate-location set`. The simulated location
  lasts while that connection stays open.
- **iOS 16 and older.** It's the plain lockdown service
  `com.apple.dt.simulatelocation`. A `set` is a quick one-off command that
  lasts until it's cleared or the phone restarts.

Before the first use, the developer disk image is mounted with
`pymobiledevice3 mounter auto-mount`. On iOS 17 and later that's a
personalised image fetched from Apple, so the Mac needs the internet once.
The image stays mounted until the phone restarts.

Two front ends share one core, `SpooferCore`:

- **iOS GPS Spoofer.app**, a SwiftUI macOS app (`Sources/iosgpsspoofer-gui`).
- **`iosgpsspoof`**, the command-line tool (`Sources/iosgpsspoof`).

## Building

You need macOS 14 or newer and Xcode 16+ or Apple's Command Line Tools
(Swift 6). Any of these work:

```bash
./setup.sh                  # what testers run: helper + release build + install to /Applications
swift build                 # debug build of everything
swift build -c release      # release build
./run-gui.sh                # build and run the GUI from the build folder, logs in this terminal
open Package.swift          # Xcode: pick the iosgpsspoofer-gui scheme and My Mac, then ⌘R
```

`setup.sh` options: `--no-open`, `--uninstall`, and the environment variables
`SPOOFER_APP_DIR` (where to install the app), `SPOOFER_HELPER_DIR` (where to
put the pymobiledevice3 environment) and `SPOOFER_COMMIT`. The full log goes to
`~/Library/Logs/iOS GPS Spoofer/install.log`.

`install.sh` is the one-line installer from the README. It downloads the
newest commit of `SPOOFER_REPO` at `SPOOFER_REF` (default `main`) to a temporary
folder and runs its `setup.sh`, passing the commit so the app knows its version.

**Liquid Glass.** The floating panels use Liquid Glass when the app is built
with the macOS 26 SDK, and frosted materials otherwise. The code checks the SDK
with `#if canImport(SwiftUI, _version: 7.0)`, not the compiler version: a
swift.org toolchain can pair Swift 6.2+ with an older SDK. CI builds both ways.

**Old build folders.** Swift build caches don't always survive a change of
toolchain. If a build fails after switching Swift versions, delete `.build`.
`setup.sh` does this by itself before retrying.

## Where things live

| What | Where |
|---|---|
| The app | `/Applications/iOS GPS Spoofer.app` (or `~/Applications`) |
| The CLI inside the app | `/Applications/iOS GPS Spoofer.app/Contents/MacOS/iosgpsspoof` |
| pymobiledevice3 environment | `~/Library/Application Support/iOS GPS Spoofer/venv` |
| Favorites, recents, saved routes | `~/Library/Application Support/iOS GPS Spoofer/library.json` |
| The live helper script | `~/Library/Application Support/iOS GPS Spoofer/helpers/` |
| iPhone Remote pairings | `~/Library/Application Support/iOS GPS Spoofer/remote-pairing.json` |
| Installer log | `~/Library/Logs/iOS GPS Spoofer/install.log` |

Both front ends look for pymobiledevice3 in this order:

1. the path chosen in Settings (or `--python-path`);
2. `$PYMOBILEDEVICE3`;
3. a venv bundled in the app (`Contents/Resources/venv`);
4. the environment `setup.sh` installs (above);
5. a `.venv` next to the working directory, the binary, or the checkout (debug builds);
6. `$PATH`, then Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), pipx
   (`~/.local/bin`) and `pip --user` (`~/Library/Python/3.x/bin`).

A venv only counts if pymobiledevice3 is actually installed in it and its
Python still runs. pymobiledevice3 runs with `PYTHONWARNINGS=ignore`, so Apple's
Python 3.9 doesn't fill the log with its LibreSSL warning.

The app can install that environment itself (the **Install** button on its
setup card, or **Settings ▸ Engine ▸ Update**). The same installer runs in a
terminal with:

```bash
"/Applications/iOS GPS Spoofer.app/Contents/MacOS/iOS GPS Spoofer" --install-helper
```

## Engines: live and classic

| | Live | Classic |
|---|---|---|
| Moving the device | one message, almost instant | a new pymobiledevice3 process and tunnel, a few seconds |
| Routes | driven by the app: pause, seek, live speed changes | a GPX file replayed by pymobiledevice3 |
| Joystick | yes | no |
| Works with | pymobiledevice3 versions the helper can patch (tested 11.0 to latest) | any pymobiledevice3 |

The live engine is a small Python helper embedded in the app
([`LiveHelperScript.swift`](../Sources/SpooferCore/LiveHelperScript.swift)).
It runs pymobiledevice3's **own** `simulate-location set` command in-process,
so device selection and every tunnel behave exactly like the installed
pymobiledevice3. It changes one thing: after the first fix it keeps the
channel open and reads new coordinates from stdin. If it can't find what it
needs to patch, the app says why (Settings ▸ Engine) and uses the classic
engine.

When a connection drops, the session retries for about two minutes with
growing waits (1 s up to 30 s), re-checking the disk image after a few tries.
Errors are read in plain English
([`SpoofSession.advice(for:)`](../Sources/SpooferCore/SpoofSession.swift)).
Developer Mode being off fails at once. A locked phone or a pending Trust
prompt keeps retrying while asking the user to act.

## Tunnels (iOS 17 and later)

| Setting | Flag | Notes |
|---|---|---|
| **Automatic** (default) | `--userspace` on iOS 17.4+, `--native` on 17.0-17.3 | No root. |
| Own tunnel | `--userspace` | pymobiledevice3's own tunnel. Nothing else on the Mac competes for it. iOS 17.4+. |
| Apple's tunnel | `--native` | Rides macOS's `remoted` tunnel. The device keeps one RSD connection for it, so `remoted` and this tool evict each other from time to time ([pymobiledevice3 #1994](https://github.com/doronz88/pymobiledevice3/issues/1994)), which drops the connection for a moment. |
| tunneld | `--tunnel <udid>` | Needs `sudo pymobiledevice3 remote tunneld` running. |

## The Mac app

The window is the map. The sidebar lists devices (rescanned every few
seconds), favorites, recent places and saved routes. The inspector on the
right holds the controls for the current mode, connection settings and the
activity log.

| Shortcut | Does |
|---|---|
| ⌘1 / ⌘2 / ⌘3 | Teleport / Route / Joystick mode |
| ⌘↩ | Start, or stop and restore the real location |
| ⇧⌘P | Pause or resume a route |
| ⌘F | Search places (also takes coordinates and Google / Apple Maps links) |
| ⇧⌘V / ⇧⌘C | Paste / copy coordinates |
| ⌘D | Add or remove the target from favorites |
| ⌘L | Re-center on the iPhone and follow it, or stop following |
| ⌘0 | Fit the map |
| ⌘O / ⇧⌘E / ⌘S | Import GPX/KML, export GPX, save the route |
| ⌥⌘I | Show or hide the inspector |

- **Map.** Right-click for Teleport Here, Add Waypoint Here, Start Joystick
  Here, Add to Favorites and Copy Coordinates. Drop a `.gpx` or `.kml` file on
  the map to import it.
- **Following.** The camera stays on the moving dot. Dragging the map, or a
  trackpad scroll, stops following; a pinch or mouse-wheel zoom doesn't.
  Re-center (or ⌘L) brings it back. The dot glides between position updates at
  the display's frame rate.
- **Routes.** Follow roads (walking or driving, via Apple Maps), once, loop or
  back-and-forth, pace by speed or total time, pause, seek and edit while
  playing.
- **Joystick.** The on-screen pad, the arrow keys or WASD. Shift goes 2.5×
  faster. "Up" is screen-up, so it follows map rotation.
- **Staying awake.** While a session runs, the app holds a power assertion: no
  App Nap and no idle system sleep. The display can still sleep.
- **Stopping.** Stop, quitting the app or closing the window restores the real
  location. A `kill` does too. If the app is force-killed, the live helper
  clears the location by itself, and the next launch cleans up stray
  processes.
- **Help ▸ Copy Diagnostics** copies versions, setup, device status and the
  recent log for a bug report.
- **Updates.** An installed app knows its commit and repository (Info.plist
  keys `SpooferGitCommit` and `SpooferRepository`). Every six hours it reads
  the newest commit on `main` from git's ref listing
  (`/info/refs?service=git-upload-pack`; GitHub's REST API allows only 60
  requests an hour per IP, which VPNs and school networks share). If it's
  newer, a banner offers **Update**. That runs the one-line installer in the
  background, which quits the app, replaces it and opens the new one. Output
  goes to `~/Library/Logs/iOS GPS Spoofer/update.log`.
- **Unplugged.** If the iPhone disappears mid-session, the status says
  "Unplugged" and the session waits for it, without clearing anything.
- **Automation.** `SPOOF_UDID=<udid>` and `SPOOF_START="lat,lon"` preselect a
  device and teleport on launch.

## The command-line tool

The CLI is inside the app bundle. Add it to your `PATH`, or call it directly:

```bash
alias iosgpsspoof='"/Applications/iOS GPS Spoofer.app/Contents/MacOS/iosgpsspoof"'
```

```bash
iosgpsspoof list                        # paired devices (add --json for scripts)
iosgpsspoof doctor                      # check pymobiledevice3, the live engine, devices, Developer Mode

# Hold a location until Ctrl-C, then restore the real GPS
iosgpsspoof spoof 48.8584 2.2945
iosgpsspoof spoof "48°51'30\"N 2°17'40\"E"
iosgpsspoof spoof "https://maps.apple.com/?ll=37.3349,-122.009"
iosgpsspoof spoof @Home                 # a favorite saved in the app
iosgpsspoof spoof "Sydney Opera House"  # place names are geocoded

# Routes: a GPX/KML file, or waypoints
iosgpsspoof route ./walk.gpx                           # keeps the file's own timing
iosgpsspoof route ./drive.kml --speed 50 --loop
iosgpsspoof route 48.8584,2.2945 48.8606,2.3376 --speed 5
iosgpsspoof route @Home @Work --duration 25m --ping-pong

iosgpsspoof clear                       # if a previous run was killed hard

# Let the SpoofRemote iPhone app control the location (prints a pairing code)
iosgpsspoof serve
iosgpsspoof serve --install-agent       # …and start it at every login
```

While `spoof` or `route` runs, it re-establishes the session if the device
disconnects and returns. On Ctrl-C (or SIGTERM) it clears the simulated
location. Pass `--no-clear-on-exit` to leave it in place.

| Option (spoof / route) | Default | Meaning |
|---|---|---|
| `--udid <id>` | first device | target device |
| `--connection any\|usb\|network` | `any` | which link to use or require |
| `--transport automatic\|userspace\|native\|tunneld` | `automatic` | iOS 17+ tunnel, see [Tunnels](#tunnels-ios-17-and-later) |
| `--python-path <path>` | auto | an explicit `pymobiledevice3` executable |
| `--no-clear-on-exit` | off | keep the fake location after exit |
| `--retry-interval <s>` (spoof) | `5` | delay before re-establishing after a drop |
| `--speed <km/h>` / `--duration <t>` (route) | the file's pace, else 5 km/h | pace; durations like `90`, `1:30`, `25m`, `1h30m` |
| `--loop` / `--ping-pong` (route) | off | repeat forever |
| `--timing-randomness <ms>` (route) | `0` | jitter between points |

## Troubleshooting with pymobiledevice3

The app's own pymobiledevice3 is at
`~/Library/Application Support/iOS GPS Spoofer/venv/bin/python3 -m pymobiledevice3`.

```bash
PMD=(~/"Library/Application Support/iOS GPS Spoofer/venv/bin/python3" -m pymobiledevice3)
"${PMD[@]}" usbmux list                       # what the Mac sees
"${PMD[@]}" lockdown pair                     # pair again (then tap Trust and enter the passcode)
"${PMD[@]}" amfi developer-mode-status        # true / false
"${PMD[@]}" amfi reveal-developer-mode        # show the Developer Mode switch in Settings
"${PMD[@]}" mounter auto-mount                # mount the developer disk image by hand
```

| Problem | Try |
|---|---|
| `usbmux list` is empty, and `system_profiler SPUSBDataType` shows no iPhone | A data cable straight into the Mac. Unlock the phone before plugging in: after about an hour locked, iOS turns the data port off (USB Restricted Mode). |
| The iPhone shows up in `system_profiler` but not in `usbmux list` | It isn't paired: `lockdown pair`, then tap Trust. |
| Stale `usbmuxd` after a macOS update | `sudo pkill -9 usbmuxd` (launchd restarts it), then plug in again. |
| The disk image won't mount | The Mac needs the internet; keep the phone unlocked; try `mounter auto-mount`. |
| The tunnel won't open | Try another tunnel in Settings ▸ Engine, or run `sudo … remote tunneld` and choose tunneld. |

## Packaging

```bash
./package-dmg.sh                        # → dist/iOS-GPS-Spoofer-<version>.dmg
```

It builds in release mode, wraps the binaries into `iOS GPS Spoofer.app` with
[`scripts/make-app.sh`](../scripts/make-app.sh), and makes a drag-to-install
DMG. `make-app.sh` writes the Info.plist (version from `VERSION`, plus the git
commit, repository and build date), renders the icon (the app draws its own
with `--render-icon`), puts the CLI next to the app binary, and signs both
ad hoc. The DMG holds just the app; it finds or installs pymobiledevice3
itself.

The app is ad-hoc signed, not notarized. A DMG downloaded from the internet is
blocked on first open: **System Settings ▸ Privacy & Security ▸ Open Anyway**.
The one-line installer avoids this, because it builds the app on the Mac it
runs on.

## Tests and CI

```bash
swift test                                              # SpooferCore and SpooferRemote unit tests
python3 Tests/LiveHelperTests/test_live_helper.py       # the live helper (needs pymobiledevice3)
```

The helper tests pull the script straight out of `LiveHelperScript.swift`, so
they run without Swift. The end-to-end ones drive pymobiledevice3's real CLI
with a mocked device, to catch upstream changes.

[CI](../.github/workflows/ci.yml) runs on every push and pull request:

| Job | Checks |
|---|---|
| Live helper | the helper against pymobiledevice3 11.0.0 and the latest release (Linux) |
| Build & test · macOS | Xcode 16: build, unit tests, the helper as compiled into the binary, a CLI smoke test, and a DMG artifact |
| Build · Xcode 26 | the Liquid Glass code path, build and tests |
| Build · swift.org toolchain + macOS 15 SDK | a new Swift with an old SDK, as on a tester's Mac where the build once broke |
| Installer · clean Mac | `./setup.sh`, the installed app finding its helper from `/`, running it again to update, the piped `install.sh`, and `--uninstall` |
| Build · SpoofRemote | the iPhone remote app for the simulator |

## Project layout

| Folder | What's in it |
|---|---|
| `Sources/SpooferCore` | engines, sessions, pymobiledevice3 discovery and process running, geodesy, routes, GPX/KML, coordinate parsing, the library |
| `Sources/SpooferRemote`, `Sources/RemoteAPI` | the iPhone remote's HTTP server and its wire format |
| `Sources/iosgpsspoof` | the CLI |
| `Sources/iosgpsspoofer-gui` | the Mac app |
| `iPhoneRemote/` | the SpoofRemote iPhone app ([guide](IPHONE-REMOTE.md)) |
| `scripts/make-app.sh` | turns a build into the `.app` |
| `setup.sh`, `install.sh` | the installer, and its one-line bootstrap |
| `docs/` | this guide, the iPhone remote guide, and a landing page |
