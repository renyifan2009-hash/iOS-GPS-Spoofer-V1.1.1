# Plan: spoofing from the iPhone alone (no Mac, works on cellular)

Status: **planned**. Nothing here is built yet, apart from what the
"Already possible" section describes.

Apps like Vanish sell this: set up once from a computer, then change the
location from the iPhone anywhere, on cellular. This page explains how that
works on iOS 17.4 and later, what we'd build, and what can go wrong.

## Already possible: unplug and go

On iOS 17 and later, the simulated location belongs to the developer
connection that set it. If that connection is **closed** (Stop, quitting the
app, a pymobiledevice3 process exiting), iOS ends the simulation. If the cable
is **pulled** instead, the connection isn't closed properly. Other tools report
that iOS then keeps the fake location until the phone restarts. Vanish calls
this a "locked spoof".

The app already behaves this way: when the iPhone disappears mid-session it
waits to reconnect and never sends a clear. So "start a location, unplug, go
out" should already work, with the location fixed in one place.

**To verify on a real iPhone (iOS 26):** teleport somewhere, unplug the
cable, open Maps on the iPhone. Does the fake location stay? Does it survive
locking the phone, and switching to cellular? Restarting the phone must bring
the real location back.

If it holds, the app should say so when the cable is pulled ("Unplugged: your
iPhone keeps this location until it restarts"), and the README can tell people.

## The full version: an iPhone app that changes its own location

### How it works

On iOS 17.4 and later, an app on the iPhone can reach the iPhone's own
developer services. It does the same handshake a Mac does, over the network
instead of USB:

1. **A pairing file.** The Mac exports the iPhone's lockdown pair record once
   (`pymobiledevice3 lockdown save-pair-record`). It proves to the iPhone that
   the app is a trusted computer.
2. **A loopback VPN.** iOS apps can't open a connection to the phone's own
   lockdown port directly. A small VPN app routes the phone's own address back
   to itself. [LocalDevVPN](https://github.com/seomin0610/LocalDevVPN) (free, on
   the App Store) is what StikDebug and SideStore users install for this. It
   keeps us from needing Apple's Network Extension entitlement, which free
   accounts can't get.
3. **The developer tunnel, in-process.** The [idevice](https://github.com/jkcoxson/idevice)
   library (Rust, MIT, ships an iOS XCFramework) connects to lockdown with the
   pairing file, opens CoreDeviceProxy, runs its own small TCP stack over the
   tunnel, and talks RSD and DVT. Its `location_simulation` module does
   `set` and `clear`. The flow is in its `ffi/examples/location_simulation.c`.
4. **The developer disk image.** It's mounted until the phone restarts. After a
   restart, idevice can mount the personalized image itself (`mobile_image_mounter`
   with `tss`), which needs the internet once.

### What we'd build

| Part | Work |
|---|---|
| Mac app | "Set up iPhone-only mode": turn on Wi-Fi connections (`lockdown wifi-connections on`), export the pairing file, and send it to the SpoofRemote app over its existing paired connection (or AirDrop it). |
| SpoofRemote | Add the idevice XCFramework. A Swift wrapper: connect, mount the disk image if needed, set, clear. A "This iPhone" mode next to "Control my Mac", with a setup checklist: pairing file, LocalDevVPN on, Developer Mode on. |
| Holding the location | The simulation lasts while the connection is open. Keep the app alive in the background with a background location session (`UIBackgroundModes: location`), or rely on the "unplugged" behavior above. Needs testing. |
| Routes and joystick | The app sends positions itself, like the Mac's motion loop. In the background this needs the same background session. |

### Getting the app onto iPhones

| Option | For testers | Catch |
|---|---|---|
| Xcode with a free Apple ID | Build and run from Xcode. | Expires after 7 days. 3 apps per free account. |
| SideStore | SideStore installs and refreshes our IPA from the phone. | Testers set up SideStore first (it also uses a pairing file and LocalDevVPN). |
| Paid developer account ($99/year) and TestFlight | Install TestFlight, accept an invite. Builds last 90 days. | Internal testers must be on the App Store Connect team (up to 100). |
| In-app re-signing (what Vanish does) | Nothing after the first install. | Means implementing Apple's sign-in and signing flow (anisette data, certificates). Big, and brittle when Apple changes it. |

TestFlight internal testing is the simplest for a small group of testers.

### Risks

- Apple can change CoreDeviceProxy or RSD in any iOS update. idevice usually
  catches up within days, but it's a moving target.
- It needs iOS 17.4 or later, Developer Mode, and a VPN app running.
- Background execution limits may end the simulation when iOS stops the app.
- A pairing file grants full developer access to the phone. It must only ever
  go to the phone it belongs to, over an authenticated channel.

### Steps, in order

1. Verify "unplug and go" on a real iPhone (above). If it works, ship the
   message and the README note.
2. Mac: export the pairing file (a button, and `iosgpsspoof export-pairing`).
3. SpoofRemote: add idevice, set and clear the location on a real iPhone
   through LocalDevVPN.
4. Background holding, then routes and the joystick on the phone.
5. Distribution: TestFlight, or documented Xcode installs.
