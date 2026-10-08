# iPhone Remote

Control the simulated location entirely from your iPhone. Your Mac stays in a
bag, a car or another room and keeps the location alive; the **SpoofRemote**
app on the iPhone picks places and tells it to start, move or stop.

## The constraint, stated plainly

iOS has **no public API that lets an installed app change the location the
whole system reports** (Maps, Find My, other apps). Location simulation is a
*developer* service that iOS only exposes to a connected computer, which is how
Xcode's *Simulate Location* works and how this project works. So:

- the **Mac** holds the developer connection to the iPhone (USB, or Wi-Fi after
  pairing) and sets the location through `pymobiledevice3`, exactly as before;
- the **iPhone app is a remote control**. It never touches the location
  itself.

No jailbreak, private entitlement, or system modification is used or needed.

```
 iPhone (SpoofRemote app) ──HTTP/JSON, local network──▶ Mac helper ──developer service──▶ same iPhone
        pick a place                                      SpooferCore                    reports that place
```

## What you get

- **Mac helper**: `iosgpsspoof serve` (headless, can run as a login item), or
  **Settings ▸ iPhone Remote** in the Mac app (you see the phone's commands on
  the Mac's map).
- **iPhone app**: Apple Maps, search ("Apple Park", any address, coordinates),
  tap anywhere to drop a pin, favorites and recents, Start / Move Here / Stop,
  live status (Mac reachable, iPhone linked, what's being simulated), and an
  animated first-run introduction. Liquid Glass design on iOS 26 and later;
  it still runs on iOS 17.
- **Discovery** over Bonjour (`_iosgpsspoof._tcp`), with a type-an-address
  fallback.
- **Pairing** with a one-time 6-digit code. The token lives in the iPhone's
  Keychain; the Mac stores only its SHA-256.
- **Local network only**: the Mac refuses connections from anything but
  private, link-local or loopback addresses.
- **Self-healing**: if the iPhone unplugs or the tunnel drops, the session
  waits and re-applies the last location; if it gives up, the helper retries
  every 15 s for as long as you want the location held. The Mac doesn't
  idle-sleep while a location is held.

## Folder structure

```
Package.swift                         # adds RemoteAPI, SpooferRemote, tests
Sources/
  RemoteAPI/RemoteAPI.swift           # wire types, shared by Mac and iPhone
  SpooferRemote/
    MacRemoteServer.swift             # NWListener HTTP server, routing, local-only filter
    PairingManager.swift              # codes, tokens (hashed), lockout
    BonjourService.swift              # advertising, local addresses, IP checks
    SessionRemoteController.swift     # drives SpooferCore's SpoofSession headlessly
  iosgpsspoof/Serve.swift             # `iosgpsspoof serve` + LaunchAgent
  iosgpsspoofer-gui/RemoteHost.swift  # Mac app: Settings ▸ iPhone Remote
Tests/SpooferRemoteTests/             # parser, pairing, routing, IP filter tests
iPhoneRemote/
  project.yml                         # XcodeGen spec
  SpoofRemote/
    SpoofRemoteApp.swift              # @main
    ContentView.swift                 # map + status + controls
    MapSearchView.swift               # MKLocalSearchCompleter / MKLocalSearch
    ConnectionManager.swift           # Bonjour, pairing, HTTP, polling
    LocationController.swift          # selection, favorites, recents, geocoding
    PairingView.swift                 # find Mac, 6-digit code, manual address
    IntroView.swift                   # animated introduction
    Glass.swift                       # Liquid Glass helpers + fallbacks
    KeychainStore.swift               # token storage
    Info.plist                        # Local Network / Bonjour / ATS keys
    Assets.xcassets                   # app icon, accent colour
```

## Which SpooferCore code the server calls

Fixed-point spoofing already existed, so the server reuses it instead of
duplicating it.

**Headless helper (`iosgpsspoof serve`)**: `SessionRemoteController`:

| Remote command | SpooferCore call |
|---|---|
| first `POST /start` | `Pymobiledevice3.selectDevice(udid:connection:)` → `SpoofSession(pmd:device:transport:engine:python:callbackQueue:)` → `SpoofSession.start(at:)` |
| `POST /location` or `/start` while running | `SpoofSession.move(to:)` (one message with the live engine) |
| `POST /stop` | `SpoofSession.stop()` (restores the real location) |
| Ctrl-C / `launchctl` stop | `SpoofSession.stopBlocking()` |
| `GET /status` | state from `onStateChange` / `onPosition` / `onEngineChange`, and `Pymobiledevice3.listDevices()` every 5 s |
| engine choice at startup | `LiveHelper.probe(python:)` with `Pymobiledevice3.pythonInterpreter` |

Reconnects: `SpoofSession` already waits for a device that disappeared
(`.reconnecting`) and relaunches a dropped channel with back-off. On top of
that, when it reports `.failed` the controller calls `start(at:)` again after
15 s while the iPhone still wants the location.

**Mac app (Settings ▸ iPhone Remote)**: `AppRemoteBridge` calls the same
methods as the Teleport button: `AppModel.teleport(to:name:)` (which uses
`obtainSession()` → `SpoofSession.start(at:)`, or `move(to:)` if a session is
running) and `AppModel.stop()` (→ `SpoofSession.stop()`).

## The API

Plain HTTP/1.1 + JSON on port **47653**. Every request except `GET /info` and
`POST /pair` needs `Authorization: Bearer <token>`.

```http
POST /pair        {"code": "482913", "clientName": "iPhone", "clientID": "…"}
               →  {"token": "…", "server": {"serverID": "…", "name": "MacBook Air", "version": 1}}

POST /location    {"latitude": 37.3349, "longitude": -122.0090, "name": "Apple Park"}
POST /start       (same body, optional: without one it starts at the last location)
POST /stop
GET  /status
POST /unpair
GET  /info        → {"serverID": "…", "name": "MacBook Air", "version": 1}
```

`/status` (and every command) returns:

```json
{
  "connected": true,
  "spoofing": true,
  "latitude": 37.3349,
  "longitude": -122.009,
  "placeName": "Apple Park",
  "phase": "active",
  "device": {"name": "iPhone", "model": "iPhone 15 Pro", "iosVersion": "18.1", "connection": "usb"},
  "engine": "Live",
  "serverName": "MacBook Air"
}
```

`phase` is `idle`, `starting`, `active`, `reconnecting`, `stopping` or
`failed`. Errors are a non-2xx status with `{"error": "message"}`: 400 bad
input, 401 not paired, 403 wrong code, 409 can't do that now (no iPhone,
still stopping), 429 too many wrong codes.

Try it from the Mac itself:

```bash
curl -s localhost:47653/info
TOKEN=$(curl -s -X POST localhost:47653/pair -d '{"code":"482913","clientName":"curl","clientID":"curl"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])')
curl -s -X POST localhost:47653/start -H "Authorization: Bearer $TOKEN" -d '{"latitude":37.3349,"longitude":-122.009,"name":"Apple Park"}'
curl -s localhost:47653/status -H "Authorization: Bearer $TOKEN"
curl -s -X POST localhost:47653/stop -H "Authorization: Bearer $TOKEN"
```

## Set up the Mac

Install the Mac app first (see the [README](../README.md#install)). The
command-line tool is inside it:

```bash
alias iosgpsspoof='"/Applications/iOS GPS Spoofer.app/Contents/MacOS/iosgpsspoof"'
iosgpsspoof serve
```

It prints the Mac's name, the **pairing code** and the addresses the iPhone
can use. Leave it running. Ctrl-C stops it and restores the real location.

- **Start at login** (user LaunchAgent, no admin rights):
  `iosgpsspoof serve --install-agent`. New pairing codes go to
  `~/Library/Logs/iosgpsspoof-remote.log`. Remove it with `--uninstall-agent`.
- **Or use the Mac app**: Settings ▸ iPhone Remote ▸ turn it on. The code,
  addresses and paired iPhones are shown there. Run either the app's remote
  or `serve`, not both (they share the port).
- Options: `--port`, `--name`, `--engine automatic|live|classic`, `--udid`,
  `--connection usb|network|any`, `--transport automatic|userspace|native|tunneld`,
  `--forget-paired`, `--verbose`.
- If macOS asks whether `iosgpsspoof` may accept incoming network
  connections, click **Allow**.

## Build the iPhone app

You need Xcode 16 or later (Xcode 26 or later for the Liquid Glass look) and
an Apple ID. A free one is enough to run on your own iPhone.

### Option A: XcodeGen (one command)

```bash
brew install xcodegen
cd iPhoneRemote
xcodegen
open SpoofRemote.xcodeproj
```

Select the **SpoofRemote** target ▸ *Signing & Capabilities* ▸ choose your
**Team**, pick your iPhone as the run destination, and press **⌘R**.

### Option B: by hand in Xcode

1. **File ▸ New ▸ Project ▸ iOS ▸ App**. Product Name `SpoofRemote`,
   Interface **SwiftUI**, Language **Swift**. Save it inside `iPhoneRemote/`.
2. Delete the template's `ContentView.swift`, `SpoofRemoteApp.swift` and
   `Assets.xcassets` (Move to Trash).
3. Drag everything in `iPhoneRemote/SpoofRemote/` into the project navigator
   (*Copy items if needed* off, *Create groups*, target **SpoofRemote** ticked).
4. **File ▸ Add Package Dependencies… ▸ Add Local…**, choose the repository
   folder (the one with `Package.swift`), and add the **RemoteAPI** library to
   the SpoofRemote target.
5. Target ▸ **Build Settings**:
   - *Info.plist File* = `SpoofRemote/Info.plist` (keep *Generate Info.plist
     File* = Yes; Xcode merges the two)
   - *iOS Deployment Target* = 17.0
   - *Swift Language Version* = Swift 6
   - On Xcode 26: *Default Actor Isolation* = **nonisolated** (the template
     sets MainActor; the code is written for nonisolated)
6. Target ▸ *Signing & Capabilities* ▸ your Team. Run on the iPhone (⌘R).

### Info.plist keys

Already in `iPhoneRemote/SpoofRemote/Info.plist`; add them on the *Info* tab
if you skip step 5:

| Key | Value | Why |
|---|---|---|
| `NSLocalNetworkUsageDescription` | "SpoofRemote finds your Mac on this network…" | iOS asks before an app talks to the local network |
| `NSBonjourServices` | `_iosgpsspoof._tcp` | required to browse for the Mac |
| `NSAppTransportSecurity` ▸ `NSAllowsLocalNetworking` | YES | plain HTTP to local addresses |
| `NSLocationWhenInUseUsageDescription` | "Shows where iOS currently reports this iPhone to be…" | the optional blue dot that confirms the simulated location |

The Mac app's bundle (`package-dmg.sh`) also declares
`NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## Use it

1. Start the Mac helper once and leave the Mac awake (plugged in, lid open,
   or clamshell mode with power and an external display).
2. Open **SpoofRemote**. The introduction ends with **Find My Mac**; allow
   **Local Network** access when iOS asks.
3. Tap your Mac and enter the 6-digit code. You only do this once.
4. Search for a place or tap the map, then **Start Here**.
5. The Mac receives the coordinates and holds them; the status pill turns
   green ("Simulating"). Open Maps to see it.
6. Pick somewhere else and tap **Move Here**, or **Stop** to restore the real
   location, without touching the Mac.

## Test: iPhone → Personal Hotspot → Mac → USB back to the iPhone

The setup where the Mac has no other network and gets internet from the
iPhone it's spoofing:

1. iPhone: **Settings ▸ Personal Hotspot ▸ Allow Others to Join** on.
2. Connect the iPhone to the Mac with a cable and tap **Trust** if asked.
   The Mac gets a network interface from the iPhone (*System Settings ▸
   Network* shows "iPhone USB") with an address like `172.20.10.2`. Turn the
   Mac's Wi-Fi off if you want to be sure it uses only the hotspot.
3. On the Mac: `.build/release/iosgpsspoof doctor` should list the iPhone,
   then run `.build/release/iosgpsspoof serve`. The banner shows
   `172.20.10.x  iPhone Personal Hotspot` under *Reachable at*.
4. In SpoofRemote: **Find My Mac**. If the Mac doesn't appear (Bonjour across
   the hotspot isn't guaranteed), tap **Enter an address instead** and type
   the `172.20.10.x` address, port `47653`, and the code.
5. **Start Here**. The Mac log shows `holding … on <iPhone>`; Maps on the
   iPhone jumps to the place.
6. Unplug the cable for a moment: the status shows *Reconnecting*, and when
   you plug it back in the location is re-applied by itself.
7. **Stop**: the real location returns.

The same flow works with both devices on ordinary Wi-Fi, where Bonjour finds
the Mac automatically.

## Security notes

- Only devices on the local network can connect; the server never listens
  for, or forwards, internet traffic, and nothing is exposed through your
  router unless you forward port 47653 yourself (don't).
- Commands need a token, obtained only with the code currently shown on the
  Mac. Codes are single-use; 5 wrong codes lock pairing for 5 minutes and
  burn the code.
- Unpair from the iPhone (Your Mac ▸ Unpair), from the Mac app (Settings ▸
  iPhone Remote), or all at once with `iosgpsspoof serve --forget-paired`.
- Traffic is plain HTTP inside your local network (the token is sent with
  each request). Use networks you trust.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Can't reach the Mac" | Is `serve` (or the app setting) running? Same network? Firewall asked to allow `iosgpsspoof`? Try the address shown in the banner. |
| Mac not listed | Allow Local Network for SpoofRemote (Settings ▸ Privacy & Security ▸ Local Network), or connect by address. |
| "The Mac can't see this iPhone" | Plug it in, unlock it, tap Trust. `iosgpsspoof doctor` should list it. |
| "port 47653 is already in use" | Another helper (or the Mac app's iPhone Remote) is running. Stop one, or use `--port`. |
| Starts, then *Retrying* | See the Mac's log; usually Developer Mode is off or the developer disk image needs internet once. |
