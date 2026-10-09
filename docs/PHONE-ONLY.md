# iPhone-only mode (beta)

Change the iPhone's location from the iPhone itself, with no Mac nearby. It
works on Wi-Fi and on cellular. You set it up once with a Mac.

**Status: built, not yet tried on a real iPhone.** It builds for iPhones and
runs in the iOS Simulator (setup, importing the pairing file, the error when
LocalDevVPN is off). The part that talks to the iPhone's developer services
needs a real iPhone to test. If you try it, send the result to the developer,
working or not.

## What you need

- An iPhone with **iOS 17.4 or later**, with **Developer Mode** on.
- A Mac with **iOS GPS Spoofer**, for the one-time setup.
- The **SpoofRemote** app on the iPhone. For now you build it with Xcode
  ([how](IPHONE-REMOTE.md#build-the-iphone-app)). A free Apple ID works, but
  the app then stops opening after 7 days until you install it again.
- **LocalDevVPN**, a free app on the
  [App Store](https://apps.apple.com/app/localdevvpn/id6755608044)
  ([source](https://github.com/seomin0610/LocalDevVPN)). StikDebug and
  SideStore users use the same app.

## Set it up (once)

1. **Plug the iPhone into the Mac**, unlock it and tap **Trust**.
2. **Load Apple's developer support.** In iOS GPS Spoofer, teleport anywhere,
   then click **Stop**. This loads the support onto the iPhone. It stays loaded
   until the iPhone restarts.
3. **Save the pairing file.** In iOS GPS Spoofer, choose **File ▸ Save iPhone
   Pairing File…** and save it. The AirDrop window opens. Pick your iPhone.
4. **Open it on the iPhone.** Accept the AirDrop and choose **SpoofRemote**.
   SpoofRemote opens its setup screen, and "Pairing file added" gets a tick.
5. **Turn on LocalDevVPN.** Install it, open it and tap **Connect**. Back in
   SpoofRemote, "LocalDevVPN is on" gets a tick.

The pairing file lets SpoofRemote act like your Mac towards this iPhone. Send
it to that iPhone only. SpoofRemote keeps it in the iPhone's Keychain, and it
isn't backed up.

## Use it

1. In SpoofRemote, tap **This iPhone** at the top of the bottom card.
2. Search for a place or tap the map, then tap **Start Here**.
3. Tap another place and **Move Here** to jump again, or **Stop** to get the
   real location back.

Keep LocalDevVPN connected. While SpoofRemote holds a location, iOS shows a
blue pill in the status bar. That's SpoofRemote staying awake in the
background, because the location only lasts while the app runs.

**After the iPhone restarts,** connect it to the Mac once and do step 2 again.
Apple's developer support has to be loaded again after every restart.

## If something goes wrong

| What you see | What to do |
|---|---|
| "Can't reach this iPhone's developer services" | Open LocalDevVPN and tap **Connect**. If it's already on, allow SpoofRemote in **Settings ▸ Privacy & Security ▸ Local Network**. |
| "The iPhone didn't accept the pairing file" | Save a new pairing file on the Mac (step 3) and open it again. For example, resetting **Location & Privacy** makes the iPhone forget the computers it trusted, and the old file with them. |
| "Apple's developer support isn't loaded" | Connect the iPhone to the Mac and do step 2. |
| "Developer Mode is off" | **Settings ▸ Privacy & Security ▸ Developer Mode**. The iPhone restarts. Then do step 2. |
| The location jumps back to the real one | iOS may have stopped SpoofRemote in the background. Open it and tap **Start Here** again. If this keeps happening, tell the developer what you were doing. |

## How it works

On iOS 17.4 and later, an app on the iPhone can reach the iPhone's own
developer services. It does the same handshake a Mac does, over the network
instead of USB:

1. **The pairing file.** The Mac exports the iPhone's lockdown pairing record
   (`pymobiledevice3 lockdown save-pair-record`) and turns on lockdown's network
   connections (`lockdown wifi-connections on`). The record proves to the
   iPhone that the app is a trusted computer.
2. **A loopback VPN.** An app can't reach the iPhone's own lockdown port
   directly. LocalDevVPN routes only the address `10.7.0.1` into its tunnel,
   swaps each packet's source and destination, and hands it back, so the
   iPhone answers itself. Other traffic doesn't go through it. Using
   LocalDevVPN means SpoofRemote doesn't need Apple's Network Extension
   entitlement, which free developer accounts can't get.
3. **The developer tunnel, inside the app.** The [idevice](https://github.com/jkcoxson/idevice)
   library (Rust, MIT) connects to lockdown at `10.7.0.1:62078` with the
   pairing file, opens CoreDeviceProxy, runs its own small TCP stack over the
   tunnel, then talks RSD and DVT. DVT's location simulation sets and clears
   the location. This is the same service Xcode's "Simulate Location" uses.
4. **Staying awake.** The simulated location belongs to the connection that set
   it. SpoofRemote holds a background location session
   (`CLBackgroundActivitySession`, `UIBackgroundModes: location`) so iOS
   doesn't suspend it and close that connection.

The code:

| Part | File |
|---|---|
| Fetching idevice (pinned version and SHA-256) | `iPhoneRemote/scripts/fetch-idevice.sh` |
| The connection, set and clear (idevice's C API) | `iPhoneRemote/SpoofRemote/OnDevice/OnDeviceSimulator.swift` |
| State, LocalDevVPN check, staying awake | `iPhoneRemote/SpoofRemote/OnDevice/OnDeviceController.swift` |
| The pairing file: checking it, the Keychain | `iPhoneRemote/SpoofRemote/OnDevice/PairingFile.swift` |
| The setup screen | `iPhoneRemote/SpoofRemote/OnDevice/PhoneOnlySetupView.swift` |
| Mac: File ▸ Save iPhone Pairing File… | `Sources/iosgpsspoofer-gui/AppModel+PhoneOnly.swift` |
| Command line: `iosgpsspoof export-pairing` | `Sources/iosgpsspoof/Commands.swift` |

### Trying it in the iOS Simulator

The Simulator can't reach `10.7.0.1`, so **Start Here** stops with the
LocalDevVPN message. Everything before that works. Debug builds take two
launch arguments:

```bash
xcrun simctl launch booted com.iosgpsspoof.remote -SpoofRemoteShow phoneSetup   # the setup screen
xcrun simctl launch booted com.iosgpsspoof.remote -SpoofRemoteShow phoneStart   # start at Apple Park
```

To import a pairing file, build with signing (the Keychain needs it, even in
the Simulator), then open the file:

```bash
xcrun simctl openurl booted "file:///path/to/iPhone.mobiledevicepairing"
```

The pretend iPhone in `Tests/Fixtures/fake-pymobiledevice3` makes a pairing
file with the right keys (`iosgpsspoof export-pairing` with
`PYMOBILEDEVICE3` pointing at it). Its values aren't real, so it only gets as
far as importing.

## Still to do

How this compares with Vanish Mobile, what's documented and what's inferred,
and the order of the remaining work: [design/iphone-standalone.md](design/iphone-standalone.md).

- Test on a real iPhone (iOS 17.4 and later, iOS 26).
- Mount Apple's developer support from the iPhone after a restart, so the Mac
  is needed only once. idevice can do it (`mobile_image_mounter` with `tss`),
  which needs the internet once per restart.
- Routes and the joystick on the iPhone. The app would send positions itself,
  like the Mac's motion loop.
- Easier installs than Xcode:

| Option | For testers | Catch |
|---|---|---|
| Xcode with a free Apple ID | Build and run from Xcode. | Expires after 7 days. 3 apps per free account. |
| SideStore | SideStore installs and refreshes the app from the iPhone. | Testers set up SideStore first (it also uses a pairing file and LocalDevVPN). |
| Paid developer account ($99/year) and TestFlight | Install TestFlight, accept an invite. Builds last 90 days. | Internal testers must be on the App Store Connect team (up to 100). |

## Risks

- Apple can change CoreDeviceProxy or RSD in any iOS update. idevice usually
  catches up within days, but it's a moving target.
- iOS may still stop the app in the background in some cases, which ends the
  location.
- A pairing file grants full developer access to the iPhone. It must only go
  to the iPhone it belongs to.

## Also worth testing: unplug and go (Mac mode)

On iOS 17 and later, the simulated location belongs to the developer
connection that set it. If that connection is **closed** (Stop, quitting the
app), iOS ends the simulation. If the cable is **pulled** instead, the
connection isn't closed properly, and other tools report that iOS then keeps
the location until the iPhone restarts. The Mac app already behaves this way:
when the iPhone disappears mid-session it waits for it and never sends a
clear.

To check on a real iPhone: teleport somewhere with the Mac app, unplug the
cable, open Maps on the iPhone. Does the location stay? Does it survive
locking the iPhone, and switching to cellular? Restarting the iPhone must bring
the real location back.
