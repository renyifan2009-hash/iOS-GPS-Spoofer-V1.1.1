# iPhone-only mode: Phase 1 feasibility report

Written 2026-10-08. It answers a brief that asked one question: can the iPhone
change its own location with no Mac, after a one-time setup, the way Vanish
Mobile says it does? It checks the brief against this repository and against
public sources. Anything a source doesn't state is marked **(inferred)**.

## The short answer

- **Yes, and this repository already does it, as a beta.** SpoofRemote has two
  modes: **Mac** (the remote that sends commands to the Mac over the network)
  and **This iPhone** (the iPhone-only mode). The brief was written from a copy
  of the code without `iPhoneRemote/SpoofRemote/OnDevice/`, which holds the
  iPhone-only mode. The user guide is [PHONE-ONLY.md](../PHONE-ONLY.md).
- **No jailbreak, no exploit, no change to iOS.** It uses the developer service
  Xcode uses to simulate a location. It needs Developer Mode, a pairing file
  from the Mac, and a free VPN app (LocalDevVPN) that sends traffic back to the
  iPhone itself.
- **It isn't a public Apple API.** Apple doesn't document these developer
  protocols for apps, and can change them in any iOS update.
- **It has never run on a real iPhone.** It builds, and it runs in the iOS
  Simulator up to the point where a real iPhone is needed. That test is the one
  missing proof (see "The missing proof").
- **Two things still need the Mac:** loading Apple's developer tools again after
  each iPhone restart, and reinstalling the app every 7 days on a free Apple
  ID. Both have known fixes (sections 6 and "Signing").

## Words used here

| Word | Meaning |
|---|---|
| Lockdown | The service on the iPhone that a computer talks to first (port 62078). It checks that the computer is trusted. |
| Pairing file | The keys the iPhone gives a computer when you tap **Trust**. Whoever has it can talk to the iPhone like that computer. |
| Developer Disk Image (DDI) | Apple's developer tools, which a Mac loads onto the iPhone. The location service is inside it. Since iOS 17, Apple signs a copy for each iPhone ("personalized"). It stays loaded until the iPhone restarts. |
| CoreDeviceProxy | A lockdown service added in iOS 17.4. It opens the encrypted tunnel that newer developer services run in. |
| RSD | Remote Service Discovery: the list of developer services reachable through that tunnel. |
| DVT | The protocol Xcode's Instruments uses to talk to developer services. Location simulation is one DVT channel. |
| Loopback VPN | A VPN app that sends traffic for one address (10.7.0.1) straight back to the iPhone, so an app can reach its own iPhone's lockdown. |

## 1. Why Mac Remote needs the Mac

In the Mac mode, SpoofRemote only sends commands. The Mac does the work:

```
SpoofRemote ──Bonjour + HTTP──▶ MacRemoteServer ──▶ SpoofSession ──▶ pymobiledevice3
                                                                        │ USB or Wi-Fi
                                                                        ▼
                                                     the iPhone's developer services
```

The Mac is needed because pymobiledevice3 runs there. It holds the pairing
record, opens the developer tunnel, and keeps the developer connection open. In
this mode the iPhone app has no developer connection of its own.

## 2. Which Apple service sets the location

- **iOS 17 and later:** the DVT channel
  `com.apple.instruments.server.services.LocationSimulation`, with two calls,
  `simulateLocationWithLatitude:longitude:` and `stopLocationSimulation`
  ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py)).
  It's reached through the CoreDevice tunnel and RSD.
- **iOS 16 and earlier:** the lockdown service `com.apple.dt.simulatelocation`
  ([pymobiledevice3](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/simulate_location.py)).
- Both come with the Developer Disk Image, and both need Developer Mode.

The location is system-wide: every app that asks Core Location gets it.

**On iOS 17 and later, the location lasts only while the connection that set
it stays open.** Tools that use this service report it, and pymobiledevice3's
own `simulate-location set` keeps running until you press Ctrl+C
([source](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/developer/dvt/simulate_location.py)).
So whatever sets the location has to keep running.

## 3. Can the iPhone reach that service by itself?

Yes, in practice:

- **idevice** ([GitHub](https://github.com/jkcoxson/idevice), Rust, MIT) does
  what pymobiledevice3 does, and it builds for iOS. It supports CoreDeviceProxy,
  RSD, DVT and location simulation, with "a naive in-process TCP stack" for the
  tunnel. Its examples include `location_simulation.c`.
- **StikDebug** ([GitHub](https://github.com/StephenDev0/StikDebug)) uses idevice
  on the iPhone itself to reach developer services "without needing a computer
  after the initial pairing setup", on iOS 17.4 and later. So an app can reach
  these services on its own iPhone.
- **SpoofRemote's iPhone-only mode** does the same for location.
  `OnDeviceSimulator.swift` connects to lockdown at 10.7.0.1 with the pairing
  file, opens CoreDeviceProxy, starts the tunnel's TCP stack, does the RSD
  handshake, opens the DVT server, then sets or clears the location.

**Not proven yet:** that SpoofRemote's code works on a real iPhone.

## 4. What iOS 17.4 changed

iOS 17.4 added CoreDeviceProxy, which opens the developer tunnel through
lockdown. pymobiledevice3's guide says its no-root tunnel "covers iOS 17.4+ …
(it uses the CoreDeviceProxy lockdown service)". Versions 17.0 to 17.3.1
"predate the CoreDeviceProxy service". For those, pymobiledevice3 uses macOS's
own tunnel, or a helper that needs root on Windows and Linux
([guide](https://doronz88.github.io/pymobiledevice3/guides/ios17-tunnels/)).
So iOS 17.4 is what made a tunnel inside an iPhone app possible:

- The iPhone-only mode requires iOS 17.4 (the app checks).
- Vanish's FAQ lists "iOS/iPadOS 17.4+". The same cut-off suggests Vanish uses
  CoreDeviceProxy too **(inferred)**.

## 5. What the VPN does, and what it doesn't

The VPN doesn't change the GPS. It only gives the app a way to reach the
iPhone's own lockdown:

- An app can't connect to its own iPhone's lockdown directly. A loopback VPN
  routes one address (10.7.0.1) back into the iPhone, and lockdown answers.
- LocalDevVPN says "All traffic stays on-device" ([GitHub](https://github.com/seomin0610/LocalDevVPN)).
  SideStore describes its VPN as one that "allows SideStore to communicate
  with internal services" ([docs](https://docs.sidestore.io/docs/installation/prerequisites)).
- Apple's capability table lists "Network extensions" and "Personal VPN" for
  paid memberships only (Apple Developer Program, Enterprise), not for free
  Apple accounts ([Apple](https://developer.apple.com/help/account/reference/supported-capabilities-ios)).
  So an app signed with a free Apple ID can't contain its own VPN. It must use a
  separate VPN app from the App Store. That's why SpoofRemote uses LocalDevVPN.
- Vanish calls its VPN step the "Connection Helper", which "keeps location
  simulation running". Vanish Mobile is signed with the user's own Apple ID
  (its FAQ says so), usually a free one. So its helper is most likely a separate
  App Store VPN app too **(inferred)**.

## 6. How the iPhone keeps going without the Mac

| When | What happens | Needs the Mac? |
|---|---|---|
| Once | Turn on Developer Mode. Install SpoofRemote. Save the pairing file on the Mac (**File ▸ Save iPhone Pairing File…**) and AirDrop it to the iPhone. Install LocalDevVPN. | Yes, once |
| Each spoof | SpoofRemote checks LocalDevVPN is on, opens the tunnel and sets the location. Moving re-uses the open connection. **Stop** clears it. | No |
| While spoofing | A background location session (the blue pill in the status bar) keeps the app running, so iOS doesn't close the connection. | No |
| After an iPhone restart | The Developer Disk Image is gone. Today the Mac must load it again. | **Yes, today** |
| Every 7 days (free Apple ID) | The app's signature expires and it won't open. Today it must be reinstalled from Xcode. | **Yes, today** |

**Fixing the restart:** idevice can load the developer image from the iPhone
itself (its `mount_personalized.c` example). It needs Apple's image files and a
signature from Apple's signing server (TSS) for this iPhone. So it needs the
internet once after each restart. Nothing else leaves the phone.

**Fixing the 7 days:** see "Signing" below.

## 7. Vanish: what's documented and what's inferred

"Documented" means Vanish says it on its site (read 2026-10-08) or in its app
(screenshots of Vanish Mobile 3.3.0's settings on iOS 26.6).

| Claim | Where it's from | Status |
|---|---|---|
| A computer is needed once, to install | Site FAQ: "Vanish Mobile needs a computer once, to install it." | Documented |
| Uses Apple's developer pathway; no jailbreak; iOS unchanged | Site: "It uses the developer location pathway Apple already ships." | Documented |
| Developer Mode is turned on once | Site FAQ | Documented |
| Works on cellular | Site ("Cellular"); app: "Use Vanish on Cellular" | Documented |
| System-wide | Site FAQ: "every app on your phone sees the spoofed location" | Documented |
| iOS 17.4 or later | Site FAQ | Documented |
| Renews its own signing inside the app | Site FAQ: "we engineered Vanish Mobile to renew itself from inside the app" | Documented |
| The Apple ID is saved in the app | Site FAQ: "you can remove the saved account from the app" | Documented |
| Uses a pairing file | App: "Get your pairing file from Vanish on your computer, then import it here." | Documented |
| Stays alive with silent audio and background location | App settings | Documented |
| Status in the Dynamic Island | App settings | Documented |
| Killswitch: stops spoofing after a while | Site | Documented |
| A spoof started from a computer can be "locked" so it survives unplugging, until a restart | Site FAQ | Documented |
| Uses CoreDeviceProxy, like idevice | The same iOS 17.4 cut-off | **Inferred** |
| The Connection Helper is a loopback VPN app, separate from Vanish Mobile | Free Apple IDs can't sign a VPN; the helper has its own "Tap to connect" | **Inferred** |
| The installer already puts a pairing file in the app | App: "Vanish Mobile will work as is. Import your pairing file to be safe." | **Inferred** |
| Renewal re-signs and reinstalls over the same tunnel, like SideStore | idevice has the pieces (app installation, `ipa_installer.c`) | **Inferred** |

## SpoofRemote next to Vanish Mobile

| Vanish feature | What it likely is | SpoofRemote today |
|---|---|---|
| Import Pairing File | The pairing file, kept on the phone | Has it: AirDrop or Files, kept in the Keychain on this iPhone only |
| Connection Helper | A loopback VPN | Uses LocalDevVPN and checks that it's on |
| Automatic Connection | Turns the helper on when the app opens **(inferred)** | Missing: asks you to open LocalDevVPN |
| Use Vanish on Cellular | Keeps the spoof going on mobile data | Should work (the loopback doesn't use Wi-Fi). Not tested |
| Background Location | The location background mode, to keep running | Has it (`CLBackgroundActivitySession`) |
| Silent Audio | The audio background mode, to keep running | Missing |
| Dynamic Island | A Live Activity (ActivityKit, a public API) | Missing |
| Satellite Map | A map style | Missing: standard map only |
| Killswitch | Stop after a set time | Missing on the iPhone |
| Bookmarks, history | Saved places | Has favorites and recents |
| Routes, scheduling | Moving along a path, on a timer | Missing on the iPhone (the Mac has routes) |
| Keep Vanish Installed | Re-signing inside the app | Missing |
| After a restart | Vanish doesn't say | Needs the Mac today (fixable, section 6) |

## Signing: the 7-day limit

- With a free Apple ID, the app's signature lasts 7 days, and only 3 such apps
  can be installed at once. A paid account ($99 a year) makes it 365 days
  ([SideStore FAQ](https://docs.sidestore.io/docs/faq)).
- Vanish renews from inside the app, with the Apple ID saved in the app.
  Re-signing on the phone means logging in to Apple's developer services with
  that Apple ID. SideStore does this, and its login needs an "anisette" server
  (an official one, or one you host yourself).
- The brief rules out sending Apple ID details to anyone but Apple. A home-made
  re-signing system would handle the password and depend on an anisette
  server. **Recommendation: don't build one.** Safer options, best first:
  1. **A paid Apple Developer account.** Installs last a year, and TestFlight
     builds last 90 days. Our code never touches an Apple ID.
  2. **SideStore.** Open source. It already refreshes apps on the phone and uses
     the same pairing file and LocalDevVPN. Testers install SpoofRemote through it.
  3. **Xcode with a free Apple ID**, every 7 days (how it works today).

## Limits nobody can remove

- **Apps can tell.** Since iOS 15, any app can read `isSimulatedBySoftware`.
  Apple says Core Location sets it to true "if the system generated the location
  using on-device software simulation", and gives Xcode's simulation as the
  example ([Apple](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware)).
  Vanish's FAQ also warns that "some apps and games detect simulated location".
- **Apple can break it.** CoreDeviceProxy, RSD and DVT are private developer
  protocols, and any iOS update can change them. idevice usually catches up,
  but not instantly.
- **iOS can still stop the app.** If iOS ends the app in the background, the
  connection closes and the real location comes back. Keep-alive modes lower
  the risk; nothing removes it.
- **The pairing file is powerful.** It gives full developer access to that
  iPhone, so it must never leave that iPhone.

## The missing proof

The brief's Phase 3 asks for a small prototype that sets a fixed location and
keeps it with the Mac gone. Today's build already does that. It needs a real
iPhone:

1. Set up the iPhone-only mode once ([PHONE-ONLY.md](../PHONE-ONLY.md), steps 1–5).
2. Unplug the iPhone and turn the Mac off.
3. In SpoofRemote, pick **This iPhone**, pick a place and tap **Start Here**.
4. Open Maps and Find My. Is the iPhone at the new place?
5. Lock the iPhone for 5 minutes. Turn Wi-Fi off so it's on cellular. Check
   Maps again.
6. Tap **Stop**. Does the real location come back right away?
7. Restart the iPhone. The real location must come back, and **Start Here**
   should then say Apple's developer support isn't loaded.

Write down what happens at each step, with any error text.

## What comes after (not started)

Only once that test passes, in this order:

1. Load Apple's developer image from the iPhone after a restart (idevice's
   `mount_personalized`), so the Mac is needed only once.
2. Reconnect by itself when the connection drops (a network change, LocalDevVPN
   restarting), and set the location again.
3. An optional silent-audio keep-alive, next to the background location one.
4. A killswitch timer, and a Live Activity for the Dynamic Island.
5. Routes on the iPhone, using SpooferCore's trip planner.
6. An easier install than Xcode: a paid account with TestFlight, or SideStore.

## Sources

- Vanish site and FAQ: <https://getvanish.app/> (read 2026-10-08), and screenshots of Vanish Mobile 3.3.0's settings on iOS 26.6
- pymobiledevice3: [DVT location simulation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/dvt/instruments/location_simulation.py), [lockdown location simulation](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/services/simulate_location.py), [CLI](https://github.com/doronz88/pymobiledevice3/blob/master/pymobiledevice3/cli/developer/dvt/simulate_location.py), [iOS 17 tunnels guide](https://doronz88.github.io/pymobiledevice3/guides/ios17-tunnels/)
- idevice: <https://github.com/jkcoxson/idevice> (README; `ffi/examples/location_simulation.c`, `mount_personalized.c`, `ipa_installer.c`)
- StikDebug: <https://github.com/StephenDev0/StikDebug>
- LocalDevVPN: <https://github.com/seomin0610/LocalDevVPN>
- SideStore: [prerequisites](https://docs.sidestore.io/docs/installation/prerequisites), [FAQ](https://docs.sidestore.io/docs/faq)
- Apple: [supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios), [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device), [CLBackgroundActivitySession](https://developer.apple.com/documentation/corelocation/clbackgroundactivitysession), [isSimulatedBySoftware](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware)
