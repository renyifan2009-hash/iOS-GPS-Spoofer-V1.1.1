# iPhone-only GPS control (beta)

The iPhone app can execute teleport, joystick and routes locally with the Mac powered off after setup. This implementation targets iOS 17+, but **has not been verified across physical devices or all iOS versions**. iOS 17.0–17.3 only attempts Remote Pairing; its local tunnel is unverified. iOS 17.4+ also has a lockdown/CoreDeviceProxy fallback when that service is reachable.

Use **iPhone app 1.1, build 5** built from this branch. Published v2.4.0 carries build 4 and lacks these standalone additions. A compiled IPA still needs signing through your existing sideloading tool.

## Set up once

1. Install/sign the iPhone app, enable Developer Mode and allow Local Network access.
2. On the Mac, plug in and trust this iPhone. Choose **File ▸ Pairing File for the iPhone App…**. Import the file on that iPhone. Remote Pairing requires the file's Remote Pairing identity; a lockdown-only file cannot use that path. Export eligibility on iOS 17 does not guarantee that Remote Pairing export succeeds there.
3. Install [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044), open it and tap Connect. It routes the phone's developer traffic back to itself; no runtime Mac server is involved in **This iPhone** mode.
4. Allow location permission for AnyWhere's background activity session.
5. For use after a phone restart, copy a matching **extracted Apple developer-image folder** to Files on the iPhone. In **This iPhone ▸ Set Up ▸ Choose Developer Image Folder**, select the directory containing `BuildManifest.plist` and its payloads. See [the device test guide](PHONE-STANDALONE-TESTING.md) for personalized and Cryptex bundles.

Pairing material stays in the device-only Keychain. Developer images are retained locally and excluded from backup. The app validates payload digests, then uses idevice and Apple's signing service to personalize/mount support if Instruments is absent. Apple may reject an image that is wrong for the device/build. Internet may be needed for personalization. After mounting, a fresh tunnel refreshes the advertised developer services.

## Use it with the computer off

Select **This iPhone** in the bottom card:

- **Teleport:** choose a position, Start Here, Move Here or Stop.
- **Joystick:** choose a starting position, Start Joystick, select a pace and hold the pad. Releasing the pad, losing input for 1.5 seconds or leaving the active app stops movement. The location remains held until Stop.
- **Route:** add two or more stops, set speed/waits and choose once, loop or ping-pong. With Follow roads, this iPhone requests MapKit directions. A failed directions request reports an error; it does not silently substitute a straight line. Without Follow roads, travel is direct. This phone backend uses the selected speed; the Mac's realistic traffic-light/OSM engine is separate.
- **Pause/Resume:** pauses route time as well as movement.
- **Automatic stop:** the phone checks a deadline while executing. iOS suspension/termination can delay or prevent the timer; verify the actual position in Maps.

A static hold is re-applied every 15 seconds to detect/recover a lost connection. Motion uses monotonic time and caps a stalled update's advance instead of jumping to catch up. Stop cancels pending planning/motion. If restoring the real position is not confirmed, the app says so and recommends a phone restart.

Keep LocalDevVPN on. Local commands do not require Wi-Fi or a Mac; cellular behavior still needs a physical-device test. Directions and image personalization may require internet.

## When something fails

Copy the small print: it identifies pairing, reachability, tunnel, developer-image loading, Instruments, simulation, set or clear. Include the exact iOS version/build and app build. Do not share the pairing file or an unredacted device log publicly.

| Symptom | Next step |
|---|---|
| No developer port answers | Connect LocalDevVPN and allow Local Network access. |
| Pairing identity rejected/missing | Export a new file for this iPhone from the current Mac app. |
| Developer support cannot load | Import the matching extracted Apple DDI folder, enable Developer Mode and check internet for Apple's signing service. |
| Location service fails to open | Check the detailed service/protocol error; a different OS build may need a library update. |
| Stop is not confirmed | Check Maps; restart the phone if it still reports the simulated position. |
| App stops opening | Refresh its signing with your sideloading tool. GPS control does not renew signing. |

## Verification

[PHONE-STANDALONE-TESTING.md](PHONE-STANDALONE-TESTING.md) gives the full computer-off, reboot, cellular, background, stop-race and version-matrix checklist. Unit/simulator tests use fake device operations and do not prove RSD/DVT works on real hardware.

The source is in `Sources/PhoneOnlyCore` (protocol rules, image validation, route timeline), `iPhoneRemote/SpoofRemote/OnDevice` (tunnel, mounting, controller, local motion), and `iPhoneRemote/Tests` (hosted control tests). The library is [idevice 0.1.68](https://github.com/jkcoxson/idevice/tree/v0.1.68), pinned by checksum in `fetch-idevice.sh`.

Apple can change developer protocols or stop a background app. The project cannot promise every iOS 17+ minor/future build or perpetual operation after force quit/reboot. One-time installation/pairing and signing refresh remain separate prerequisites.
