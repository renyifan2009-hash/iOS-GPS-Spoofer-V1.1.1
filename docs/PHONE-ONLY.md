# iPhone-only mode (beta)

Change the iPhone's location from the iPhone itself, with no Mac nearby. It
works on Wi-Fi and on cellular. You set it up once with a Mac.

**Status: built, not yet tried on a real iPhone.** It builds for iPhones and
runs in the iOS Simulator (setup, importing the pairing file, the error when
LocalDevVPN is off). The pairing file, the choice of connection and the error
messages are covered by tests. The part that talks to the iPhone's developer
services needs a real iPhone to test. If you try it, send the result to the
developer, working or not, with the small print under any error.

## What you need

- An iPhone with **iOS 17.4 or later**, with **Developer Mode** on.
- A Mac with **AnyWhere**, for the one-time setup. Use the current
  version: older ones save a pairing file that newer iOS versions can't use.
- The **AnyWhere** app on the iPhone. Each
  [release](https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases)
  has a `SpoofRemote.ipa` to install with [Sideloadly](https://sideloadly.io),
  which signs it with your Apple ID, and step-by-step instructions. You can
  also build it with Xcode ([how](IPHONE-REMOTE.md#build-the-iphone-app)).
  Either way a free Apple ID works, but the app then stops opening after 7
  days until you install it again.
- **LocalDevVPN**, a free app on the
  [App Store](https://apps.apple.com/app/localdevvpn/id6755608044)
  ([source](https://github.com/seomin0610/LocalDevVPN)). StikDebug and
  SideStore users use the same app.

## Set it up (once)

1. **Plug the iPhone into the Mac**, unlock it and tap **Trust**.
2. **Load Apple's developer support.** In AnyWhere, teleport anywhere,
   then click **Stop**. This loads the support onto the iPhone. It stays loaded
   until the iPhone restarts.
3. **Make the pairing file.** Keep the iPhone plugged in and unlocked. In
   AnyWhere on the Mac, choose **File ▸ Pairing File for the iPhone App…**
   (**⇧⌘K**, or the iPhone icon at the bottom of the sidebar). The window says
   if anything is missing (no iPhone, no helper tool, iOS older than 17.4). Click
   **Create Pairing File**. It's saved on your **Desktop**, and the window shows
   where. If it says **This file works on older iOS only**, see the table below
   before going on.
4. **Open it on the iPhone.** Accept the AirDrop and choose **AnyWhere**.
   AnyWhere opens its setup screen, and "Pairing file added" gets a tick.
5. **Turn on LocalDevVPN.** Install it, open it and tap **Connect**. Back in
   AnyWhere, "LocalDevVPN is on" gets a tick.

The pairing file lets AnyWhere act like your Mac towards this iPhone. Send
it to that iPhone only. AnyWhere keeps it in the iPhone's Keychain, and it
isn't backed up.

## Use it

1. In AnyWhere, tap **This iPhone** at the top of the bottom card.
2. Search for a place or tap the map, then tap **Start Here**.
3. Tap another place and **Move Here** to jump again, or **Stop** to get the
   real location back.

Keep LocalDevVPN connected. While AnyWhere holds a location, iOS shows a
blue pill in the status bar. That's AnyWhere staying awake in the
background, because the location only lasts while the app runs.

**After the iPhone restarts,** connect it to the Mac once and do step 2 again.
Apple's developer support has to be loaded again after every restart.

## Keeping the two apps in step

The Mac app updates itself. AnyWhere does not: it only changes when you
reinstall the `.ipa` from the
[releases page](https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases/latest).
So you can end up with a new Mac app and an old AnyWhere, and the
iPhone-only mode then fails with a confusing error. Two notices catch this:

- **On the Mac.** When an iPhone is plugged in, and again when you save a
  pairing file, the Mac reads which AnyWhere is on it. If it's older than
  the Mac app expects, a banner says so, with a button that opens the releases
  page. If AnyWhere isn't installed, or the check can't run, the Mac says
  nothing. The check never blocks or slows down saving the file or normal use.
  The command line does the same after `iosgpsspoof export-pairing`.
- **On the iPhone.** AnyWhere carries the version it was built from. At most
  once a day it asks GitHub for the newest release and, if that's newer, shows
  a small notice on the main screen and the setup screen, with a button to the
  releases page. You can dismiss it; it comes back only for a newer release.
  When "This iPhone" mode fails to connect and a newer release is out, the
  error says so too, because updating is the likely fix. This is the only thing
  AnyWhere sends to the internet, it sends nothing about you or the iPhone,
  and no network or an odd answer simply shows nothing.

## If something goes wrong

| What you see | What to do |
|---|---|
| "Can't reach this iPhone's developer services" | Open LocalDevVPN and tap **Connect**. If it's already on, allow AnyWhere in **Settings ▸ Privacy & Security ▸ Local Network**. |
| "The iPhone didn't accept the pairing file" | Save a new pairing file on the Mac (step 3) and open it again. For example, resetting **Location & Privacy** makes the iPhone forget the computers it trusted, and the old file with them. |
| "This iPhone needs a newer pairing file", or the setup screen says "This pairing file is too old" | The file has only the older of its two identities, and this iPhone's iOS needs the newer one. Update AnyWhere on the Mac, plug the iPhone in, and do step 3 and 4 again. |
| The Mac says "Saved, for older iOS only" | The Mac couldn't add the identity newer iOS versions need. The **Activity** section of the inspector gives the reason. Usually: plug the iPhone in with a cable (Wi-Fi isn't enough for this), unlock it, check Developer Mode is on, or update pymobiledevice3 by running `./setup.sh` again. Then save the file again. |
| The iPhone asks whether to trust AnyWhere when you tap **Start Here** | The iPhone no longer knows the identity in the file, so AnyWhere is pairing again. Tap **Trust**. AnyWhere keeps the new identity, so it shouldn't ask again. |
| "Connecting took too long" | Check LocalDevVPN is connected and try again. If the iPhone is asking whether to trust AnyWhere, tap **Trust**. |
| "Moving took too long, so AnyWhere stopped" | The connection stopped answering in the middle of a move. Start again. The iPhone can keep the last location for a while; if it stays, close AnyWhere and open it again. |
| "This iPhone closed the connection while the tunnel was opening" | Turn LocalDevVPN off and on, then try again. If it keeps happening, save a new pairing file (step 3). A StikDebug user reported the same on iOS 26.7 ([issue 474](https://github.com/StikDebug/StikDebug/issues/474)), so tell the developer your iOS version. |
| "Can't find this iPhone's pairing service" | LocalDevVPN is on, but the service AnyWhere needs didn't answer. Turn LocalDevVPN off and on. Restarting the iPhone also restarts the service (then do step 2 again). |
| "Apple's developer support isn't loaded" | Connect the iPhone to the Mac and do step 2. |
| "Developer Mode is off" | **Settings ▸ Privacy & Security ▸ Developer Mode**. The iPhone restarts. Then do step 2. |
| The location jumps back to the real one | iOS may have stopped AnyWhere in the background. Open it and tap **Start Here** again. If this keeps happening, tell the developer what you were doing. |

Under an error, on the main screen and on the setup screen, there's a line of
small print: the step that failed, the kind of connection, and the library's
own message. Include it when you report a problem. Press and hold to copy it.

## How it works

On iOS 17.4 and later, an app on the iPhone can reach the iPhone's own
developer services. It does the same handshake a Mac does, over the network
instead of USB:

1. **The pairing file.** It proves to the iPhone that the app is a trusted
   computer. The Mac puts two identities in it, because iOS has two doors:
   - The **lockdown record**: the certificates the iPhone gave the Mac when
     you tapped Trust (`pymobiledevice3 lockdown save-pair-record`). The Mac
     also turns on lockdown's network connections (`lockdown wifi-connections
     on`).
   - A **Remote Pairing identity**: an Ed25519 key the iPhone's
     `remotepairingd` knows this Mac by. The Mac makes it over the USB
     connection, which is already trusted, so the iPhone asks nothing
     (pymobiledevice3's `RemotePairingLockdownService`). If the Mac already
     paired this way, it uses the same key again.
2. **A loopback VPN.** An app can't reach the iPhone's own developer ports
   directly. LocalDevVPN routes only the address `10.7.0.1` into its tunnel,
   swaps each packet's source and destination, and hands it back, so the
   iPhone answers itself. Other traffic doesn't go through it. Using
   LocalDevVPN means AnyWhere doesn't need Apple's Network Extension
   entitlement, which free developer accounts can't get.
3. **The developer tunnel, inside the app.** The [idevice](https://github.com/jkcoxson/idevice)
   library (Rust, MIT) opens the tunnel one of two ways:
   - **Remote Pairing** (tried first): it connects to `remotepairingd` at
     `10.7.0.1`, proves the identity (pair-verify), and opens that service's
     own tunnel. This works on every iOS version this mode supports, and it's
     the only way on newer ones.
   - **Lockdown** (a second chance on older iOS): it connects to lockdown at
     `10.7.0.1:62078` with the lockdown record and opens CoreDeviceProxy.
     Newer iOS versions don't answer lockdown through LocalDevVPN. StikDebug
     and SideStore moved to Remote Pairing for iOS 26.4 for that reason.

   Either way idevice then runs its own small TCP stack over the tunnel and
   talks RSD and DVT. DVT's location simulation sets and clears the location.
   This is the same service Xcode's "Simulate Location" uses.
4. **Staying awake.** The simulated location belongs to the connection that set
   it. AnyWhere holds a background location session
   (`CLBackgroundActivitySession`, `UIBackgroundModes: location`) so iOS
   doesn't suspend it and close that connection.

Some details of step 3:

- **Which ports answer.** Before connecting, AnyWhere knocks on both ports
  at `10.7.0.1`. If neither answers, LocalDevVPN is off. If only
  `remotepairingd` answers and the file has no Remote Pairing identity, it
  asks for a newer file instead of failing with a connection error.
- **Where remotepairingd listens.** Usually port 49152, the first port iOS
  hands out, and StikDebug connects there without asking. iOS doesn't promise
  it, so when 49152 doesn't answer, or isn't the right service, AnyWhere
  looks the port up with Bonjour (`_remotepairing._tcp`), as SideStore does,
  and remembers it for as long as it works.
- **Pairing again.** If the iPhone no longer knows the identity, idevice pairs
  again on the same connection and the iPhone asks you to trust AnyWhere.
  AnyWhere saves the new identity over the old one in the Keychain, also
  when the connection fails after the pairing went through.
- **A time limit.** idevice's reads never time out, so a connection that gets
  no answer would leave the app stuck on "Starting…". After 60 seconds
  AnyWhere gives up on it and says so. A call it gave up on can still
  return later. It then only closes its own connection, and AnyWhere sets
  the current location again in case that disturbed it.

The code:

| Part | File |
|---|---|
| The pairing file's format, which connection to try, what an error means (shared by the Mac and the iPhone, with tests) | `Sources/PhoneOnlyCore/` |
| Fetching idevice (pinned version and SHA-256) | `iPhoneRemote/scripts/fetch-idevice.sh` |
| The connection, set and clear (idevice's C API) | `iPhoneRemote/SpoofRemote/OnDevice/OnDeviceSimulator.swift` |
| State, the port check, finding remotepairingd's port, the time limit, staying awake | `iPhoneRemote/SpoofRemote/OnDevice/OnDeviceController.swift` |
| The pairing file in the Keychain | `iPhoneRemote/SpoofRemote/OnDevice/PairingFile.swift` |
| The setup screen | `iPhoneRemote/SpoofRemote/OnDevice/PhoneOnlySetupView.swift` |
| Mac: saving both identities | `Sources/SpooferCore/Device.swift` (`exportPairingFile`) |
| Mac: making the Remote Pairing identity (Python, run by pymobiledevice3's interpreter) | `Sources/SpooferCore/RemotePairingScript.swift` |
| Mac: File ▸ Pairing File for the iPhone App… | `Sources/iosgpsspoofer-gui/AppModel+PhoneOnly.swift` |
| Command line: `iosgpsspoof export-pairing` | `Sources/iosgpsspoof/Commands.swift` |
| AnyWhere's version and the release check (shared, with tests) | `Sources/PhoneOnlyCore/SpoofRemoteVersion.swift`, `ReleaseVersion.swift` |
| Mac: reading the iPhone's installed AnyWhere | `Sources/SpooferCore/Device.swift` (`installedSpoofRemoteVersion`) |
| AnyWhere: the newer-release notice | `iPhoneRemote/SpoofRemote/UpdateChecker.swift`, `UpdateNoticeView.swift` |

### Trying it in the iOS Simulator

The Simulator can't reach `10.7.0.1`, so **Start Here** stops with the
LocalDevVPN message. Everything before that works. Debug builds take two
launch arguments:

```bash
xcrun simctl launch booted com.iosgpsspoof.remote -SpoofRemoteShow phoneSetup   # the setup screen
xcrun simctl launch booted com.iosgpsspoof.remote -SpoofRemoteShow phoneStart   # start at Apple Park
# Pretend a newer release is out, so the "A newer version is out" notice shows
# without the network (both screens):
xcrun simctl launch booted com.iosgpsspoof.remote -hasSeenIntro YES -SpoofRemotePretendUpdate 9.9.9
```

To import a pairing file, build with signing (the Keychain needs it, even in
the Simulator), then open the file:

```bash
xcrun simctl openurl booted "file:///path/to/iPhone.mobiledevicepairing"
```

The pretend iPhone makes a pairing file with the right keys. Its values
aren't real, so it only gets as far as importing:

```bash
PYMOBILEDEVICE3="$PWD/Tests/Fixtures/fake-pymobiledevice3" PYTHONPATH="$PWD/Tests/Fixtures/fake-site" \
  "$(swift build --show-bin-path)/iosgpsspoof" export-pairing
```

`PYTHONPATH` gives the export a stand-in for pymobiledevice3's library, which
makes the Remote Pairing identity. Without it the file has the lockdown record
only, the kind an older Mac app saved. `FAKE_PMD_RP` picks what the pretend
iPhone does (see `Tests/Fixtures/fake-site/pymobiledevice3/__init__.py`).

## Still to do

How this compares with Vanish Mobile, what's documented and what's inferred,
and the order of the remaining work: [design/iphone-standalone.md](design/iphone-standalone.md).

- Test on a real iPhone: one on an older iOS (17.4 to 26.3), where both
  connections should work, and one on a newer iOS (26.4 or later, and iOS 27),
  where only Remote Pairing can. On the newer one, check that 49152 is still
  the port, and whether the Bonjour lookup finds it when it isn't.
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

- Apple can change Remote Pairing, CoreDeviceProxy or RSD in any iOS update.
  idevice usually catches up within days, but it's a moving target. It already
  happened once: newer iOS versions stopped answering lockdown through
  LocalDevVPN, which is why the pairing file now carries a Remote Pairing
  identity too.
- Remote Pairing through LocalDevVPN isn't proven on the newest iOS versions.
  One StikDebug user reports the connection being reset on iOS 26.7
  ([issue 474](https://github.com/StikDebug/StikDebug/issues/474), open, no
  cause found yet), and reports say iOS 27 changes how a computer pairs over
  the network. If it fails for you, the small print under the error says
  where.
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
