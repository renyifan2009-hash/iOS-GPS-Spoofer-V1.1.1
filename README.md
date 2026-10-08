# iOS GPS Spoofer

Simulate the GPS location of a **connected iPhone** — hold it at any place on
Earth, drive it along a route, or steer it live with a joystick. Nothing is
installed on the phone, and the real location comes back the moment you stop.

It drives Apple's developer *location-simulation* service — the same mechanism
as Xcode's **Product ▸ Scheme ▸ Simulate Location** — through
[`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3). On iOS 17+
that service sits behind the encrypted CoreDevice tunnel; on iOS 16 and older
it's a plain lockdown service. Both are supported.

Two front-ends over a shared core (`SpooferCore`):

- **iOS GPS Spoofer.app** — a SwiftUI macOS app (`iosgpsspoofer-gui`).
- **`iosgpsspoof`** — the command-line tool.

## What's new in 2.0

- **A brand-new look** — a full-window map with a floating search bar and mode
  switcher, a "Now simulating" HUD with live speed, distance, ETA and a
  draggable progress bar, a gradient route line that fills in as you travel,
  toasts for every action, a new app icon, and a first-launch **welcome &
  setup checklist** that checks pymobiledevice3, the live engine, your iPhone
  and Developer Mode for you.
- **Live engine** — one long-lived channel to the phone. Moves are instant
  (no new tunnel per move), which makes smooth routes, pause / resume /
  scrubbing, and a real-time **joystick** possible. Falls back to the classic
  engine automatically if your pymobiledevice3 can't support it.
- **Three modes**: **Teleport**, **Route** and **Joystick**.
- **Place search** with autocomplete. The same box understands coordinates in
  decimal or degrees-minutes-seconds and **Google Maps / Apple Maps /
  OpenStreetMap links**.
- **Road-following routes** (walking or driving, via Apple Maps directions),
  **loop** and **back-and-forth** modes, pace by speed or by duration, live
  progress with ETA, **GPX / KML import & export**, drag-and-drop.
- **Favorites, recent places and saved routes** in the sidebar (the CLI can use
  favorites as `@Name`).
- **Live device marker** with heading, travelled-route overlay, standard /
  satellite / hybrid maps, right-click menu, follow-device.
- **Settings** window, **menu bar** quick controls, keyboard shortcuts,
  realism options (speed variation, GPS wobble).
- **iOS 16 and older** supported; marketing model names ("iPhone 15 Pro").
- Fixed: routes now really **finish and loop** (pymobiledevice3 ≥ 10's `play`
  never exits on its own, so "Loop" and "Arrived" never fired before).
- CLI: `spoof "Eiffel Tower"`, `spoof <maps link>`, `route` from waypoints with
  `--speed` / `--duration` / `--loop` / `--ping-pong`, `list --json`, `doctor`.
- Unit tests and CI (macOS build + tests, helper tests against real
  pymobiledevice3, DMG artifact).

## Download

Grab the DMG from the
**[Releases page](https://github.com/SegFault42/iOS-GPS-Spoofer/releases/latest)**,
open it and drag **iOS GPS Spoofer** to Applications. First launch:
**right-click ▸ Open** (the app is ad-hoc signed, so Gatekeeper asks once).
Every CI run also attaches a freshly built DMG as a workflow artifact.

Then prepare your iPhone — see **[IPHONE-SETUP.md](IPHONE-SETUP.md)**.

## Screenshots

> These show the 1.x layout; the 2.0 window is redesigned around a full-window
> map with a floating search bar, mode switcher, inspector and live HUD.

| Fixed location | Route |
|:---:|:---:|
| ![Fixed-point mode](img/fix.png) | ![Route mode](img/route.png) |

The spoofed position as the iPhone itself sees it — Apple Park, the
mid-Atlantic, and the Eiffel Tower:

| Apple Park | North Atlantic | Eiffel Tower |
|:---:|:---:|:---:|
| ![](img/IMG_0111.PNG) | ![](img/IMG_0112.PNG) | ![](img/IMG_0113.PNG) |

## Requirements

- macOS 14 Sonoma or newer (building needs Xcode 16 / Swift 6).
- [`pymobiledevice3`](https://github.com/doronz88/pymobiledevice3) — `./setup.sh`
  installs it into `./.venv`; `pipx install pymobiledevice3` or Homebrew work
  too. Version 11 or newer is recommended (it's what the default `native`
  tunnel needs).
- An iPhone that is **paired & trusted** with **Developer Mode** on — see
  **[IPHONE-SETUP.md](IPHONE-SETUP.md)**.
- With the default `native` tunnel, **no root / password** is needed.

## Setup (build it yourself)

```bash
cd ~/Downloads/iOS-GPS-Spoofer   # wherever you cloned or unzipped the repo
./setup.sh                       # first time: creates .venv with pymobiledevice3, builds CLI + GUI
swift build -c release           # rebuild after pulling changes
./run-gui.sh                     # build (if needed) and launch the app
```

### Open in Xcode

It's a plain Swift package, so Xcode opens it directly — no project file needed:

```bash
open Package.swift               # or: xed .
```

Pick the **iosgpsspoofer-gui** scheme and **My Mac**, then **⌘R**. Debug builds
find the repo's `.venv` on their own; otherwise choose pymobiledevice3 in the
app's setup card or Settings (or set `PYMOBILEDEVICE3` in the scheme's
environment). The **iosgpsspoof** scheme is the CLI (add arguments under
*Edit Scheme ▸ Run ▸ Arguments*); **⌘U** on the **iosgpsspoof-Package** scheme
runs the unit tests.

The CLI lands at `.build/release/iosgpsspoof` — copy it onto your `PATH` if you
like. Both front-ends look for `pymobiledevice3` in: an explicit path
(`--python-path` / Settings), `$PYMOBILEDEVICE3`, a venv bundled in the app,
`./.venv`, `$PATH`, then Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), pipx
(`~/.local/bin`) and `pip --user` locations.

## Using the app

The window is the map. The **sidebar** lists connected devices (auto-refreshed),
your **favorites**, **recent** places and **saved routes**. The **inspector** on
the right holds the controls for the current mode, connection settings and the
activity log; **⌥⌘I** hides it.

Search with **⌘F**: type a place or address and press **Return** (or pick a
suggestion as you type), or paste `48.8584, 2.2945`, `48°51'30"N 2°17'40"E`, or
a Google / Apple Maps link. **Right-click** anywhere
on the map for *Teleport Here*, *Add Waypoint Here*, *Start Joystick Here*,
*Add to Favorites…* and *Copy Coordinates*. Drop a `.gpx` / `.kml` file on the
map to import it.

### Teleport (⌘1)

Click the map (the pin is draggable), search, pick a favorite or type
coordinates, then **Teleport** (⌘↩). While spoofing, pick somewhere else and hit
**Move Here** — with the live engine that's instant. Turn on *Move as soon as I
click the map* to skip the button. **⌘D** stars the place.

### Route (⌘2)

Click to drop the start, the destination, then any stops in between (pins are
draggable; hover a row in the list to reorder, insert or delete). Options:

- **Follow roads & paths** — snaps each leg to real walking or driving routes.
- **At the end** — *Once* (stay at the destination), *Loop* (drive back to the
  start and repeat) or *Back & forth*.
- **Pace** — a speed (with walk / run / cycle / drive / highway presets) or a
  total duration.

**Start Route** and watch the HUD: progress, ETA, lap count. With the live
engine you can **pause / resume** (⇧⌘P), **drag the progress bar** to jump, and
change the speed on the fly. Edit waypoints mid-route and **Apply Changes**
without losing your place. Save routes to the library (⌘S), or export / import
GPX and KML (⌘O, ⇧⌘E).

### Joystick (⌘3)

Start from the teleport target or wherever the device already is, then drag the
on-screen pad or use **arrow keys / WASD** (hold **⇧** to go 2.5× faster).
"Up" is screen-up, so it follows map rotation. Pick a top speed with the preset
chips. Needs the live engine.

### Stopping

**Stop & Restore Real Location** (⌘↩), quitting the app, or closing the window
restores the real GPS. Cleanup is robust: a `kill` still clears it, and if the
app is ever force-killed the live helper notices and clears the location by
itself (the next launch also reaps any stray `pymobiledevice3`). Rebooting the
phone always clears a simulated location.

### Settings (⌘,)

Units (metric / imperial), map style, follow-device, menu bar icon, scan
interval; **engine** (Automatic / Live / Classic) with a live status check,
tunnel transport, and which `pymobiledevice3` to use; movement update rate,
**speed variation** and **GPS wobble** for more natural-looking movement.

**Automation:** set `SPOOF_UDID=<udid>` and/or `SPOOF_START="lat,lon"` in the
environment to preselect a device and teleport on launch.

## Engines: live vs classic

| | Live | Classic |
|---|---|---|
| Moving the device | one message (~instant) | new pymobiledevice3 process + tunnel (seconds) |
| Routes | driven by the app: pause, seek, live speed | GPX replayed by pymobiledevice3 |
| Joystick | ✅ | ❌ |
| Works with | pymobiledevice3 whose CLI the helper can patch (tested 11.0 → latest) | any pymobiledevice3 |

The live engine is a ~300-line Python helper embedded in the app
([`LiveHelperScript.swift`](Sources/SpooferCore/LiveHelperScript.swift)). It
runs pymobiledevice3's **own** `simulate-location set` command in-process — so
device selection and every tunnel transport behave exactly like the installed
pymobiledevice3 — and only changes one thing: after the first fix it keeps the
channel open and reads further coordinates from stdin. If it can't find what it
needs to patch, the app says so (Settings ▸ Engine) and uses the classic engine.

## CLI

```bash
iosgpsspoof list                        # paired devices (add --json for scripts)
iosgpsspoof doctor                      # check pymobiledevice3, the live engine, devices, Developer Mode

# Hold a location until Ctrl-C, then restore the real GPS
iosgpsspoof spoof 48.8584 2.2945
iosgpsspoof spoof "48.8584,2.2945"
iosgpsspoof spoof "48°51'30\"N 2°17'40\"E"
iosgpsspoof spoof "https://maps.apple.com/?ll=37.3349,-122.009"
iosgpsspoof spoof @Home                 # a favorite saved in the app
iosgpsspoof spoof "Sydney Opera House"  # place names are geocoded
iosgpsspoof spoof 37.3349 -122.0090 --udid 00008110-000815C10CD1801E --connection usb

# Routes: a GPX/KML file, or waypoints
iosgpsspoof route ./walk.gpx                           # keeps the file's own timing
iosgpsspoof route ./drive.kml --speed 50 --loop
iosgpsspoof route 48.8584,2.2945 48.8606,2.3376 --speed 5
iosgpsspoof route @Home @Work --duration 25m --ping-pong

iosgpsspoof clear                       # if a previous run was killed hard
```

While `spoof` / `route` runs it re-establishes the session if the device
disconnects and returns, and on Ctrl-C (or SIGTERM) clears the simulated
location. Pass `--no-clear-on-exit` to leave it in place.

| option (spoof / route) | default | meaning |
|---|---|---|
| `--udid <id>` | first device | target device |
| `--connection any\|usb\|network` | `any` | which link to use / require |
| `--transport native\|tunneld\|userspace` | `native` | iOS 17+ tunnel. `native` = no root (macOS). `tunneld` needs `sudo pymobiledevice3 remote tunneld`. `userspace` = in-process, no root, slower |
| `--python-path <path>` | auto | explicit `pymobiledevice3` executable |
| `--no-clear-on-exit` | off | keep the fake location after exit |
| `--retry-interval <s>` (spoof) | `5` | delay before re-establishing after a drop |
| `--speed <km/h>` / `--duration <t>` (route) | recorded pace, else 5 km/h | pace; durations like `90`, `1:30`, `25m`, `1h30m` |
| `--loop` / `--ping-pong` (route) | off | repeat forever |
| `--timing-randomness <ms>` (route) | `0` | jitter between points |

## Package as a DMG

```bash
./package-dmg.sh              # → dist/iOS-GPS-Spoofer-<version>.dmg (bundles ./.venv)
./package-dmg.sh --no-venv    # lean build; the app finds pymobiledevice3 on its own
```

Builds `iOS GPS Spoofer.app` (generated icon, ad-hoc signed) and a
drag-to-install DMG. The bundled venv's Python still references this machine's
Homebrew Python, so that DMG runs on this Mac and Macs with the same
`brew install python@3.x`; for a portable build use `--no-venv` (users can point
the app at their pymobiledevice3 from the setup card or Settings).

**Publishing a release** (maintainer):

```bash
VERSION=2.0.0 ./package-dmg.sh
gh release create v2.0.0 "dist/iOS-GPS-Spoofer-2.0.0.dmg" --title "v2.0.0" --notes "iOS GPS Spoofer 2.0.0"
```

## Development

```bash
swift build                                  # debug build of everything
swift test                                   # SpooferCore unit tests
python3 Tests/LiveHelperTests/test_live_helper.py   # live helper (needs pymobiledevice3 installed)
```

The helper tests extract the script straight from `LiveHelperScript.swift`, so
they run without a Swift toolchain; the end-to-end ones drive pymobiledevice3's
real CLI with a mocked device to catch upstream API drift. CI
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) runs them against
pymobiledevice3 11.0.0 and the latest release, builds and tests on macOS,
re-tests the helper as compiled into the binary, smoke-tests the CLI, and
uploads a DMG.

Layout: `Sources/SpooferCore` (engines, geodesy, routes, GPX/KML, parsing,
library), `Sources/iosgpsspoof` (CLI), `Sources/iosgpsspoofer-gui` (app).

## Notes & limitations

- The first run on a device may take a few seconds while the developer disk
  image is mounted (needs internet once per iOS version) and the tunnel opens.
- Only latitude / longitude are simulated (altitude, course and speed are
  derived by iOS), exactly like Xcode.
- Some apps cache location or run their own checks; force-quit and reopen them.
- This is for developing and testing location-aware apps on your own devices.
