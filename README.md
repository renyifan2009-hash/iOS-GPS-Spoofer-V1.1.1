# iOS GPS Spoofer

Change your iPhone's GPS location from your Mac. Jump anywhere in the world,
drive a route on real roads, or steer with a joystick. Nothing gets installed
on the iPhone, and your real location comes back when you press **Stop**.

| Apple Park | North Atlantic | Eiffel Tower |
|:---:|:---:|:---:|
| ![The iPhone showing a simulated location at Apple Park](img/IMG_0111.PNG) | ![The iPhone showing a simulated location in the North Atlantic](img/IMG_0112.PNG) | ![The iPhone showing a simulated location at the Eiffel Tower](img/IMG_0113.PNG) |

## What you need

- A Mac with **macOS 14 Sonoma** or newer.
- An **iPhone or iPad**. iOS 17 or newer works best.
- A **USB cable that carries data**. The cable that came with your iPhone works.
  Some cheap cables only charge.

## Install

It takes about 5 minutes.

1. Open **Terminal**. Press **⌘ Space**, type `Terminal`, then press **Return**.
2. Copy this line. Paste it into Terminal with **⌘ V**, then press **Return**:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1/main/install.sh | bash
   ```

3. **A window may ask to install the "command line developer tools".** Click
   **Install**. These are Apple's free tools for building apps. They take 5 to
   15 minutes to install. When they're done, paste the same line into Terminal
   again.
4. Wait while it works. It downloads the app, builds it on your Mac and puts it
   in your **Applications** folder. When you see **Done!**, the app opens by
   itself.

Next time, open **iOS GPS Spoofer** from Launchpad, or search for it with
Spotlight (**⌘ Space**).

<details>
<summary>Already downloaded the project as a ZIP?</summary>

1. Open Terminal and type `cd ` (with a space after it). Don't press Return yet.
2. Drag the project folder from Finder onto the Terminal window, then press
   **Return**.
3. Type `./setup.sh` and press **Return**.

If macOS asks whether Terminal can use your Downloads folder, click **Allow**.

</details>

## Set up your iPhone (one time)

1. **Plug the iPhone into your Mac** and unlock it.
2. **Tap Trust.** If the iPhone asks "Trust This Computer?", tap **Trust** and
   enter your passcode.
3. **Turn on Developer Mode.** On the iPhone, open **Settings ▸ Privacy &
   Security ▸ Developer Mode** and switch it on. The iPhone restarts. When it's
   back, unlock it and tap **Turn On**.
   - Can't find Developer Mode? It stays hidden until a Mac asks for it. In the
     app, click **Show on iPhone**, then look in Settings again.
4. **Keep the iPhone unlocked the first time.** The app loads Apple's developer
   support onto the iPhone. This needs the internet and takes about a minute.

The app shows a checklist. Each step gets a green tick when it's done.

## Use it

- **Teleport:** click a place on the map, or search for one. Then click
  **Teleport**.
- **Route:** click **Route** at the top. Click the map to drop a start, an end
  and any stops. Pick a speed, then click **Start Route**. Turn on **Follow
  roads & paths** to stay on real streets.
- **Joystick:** click **Joystick**, then **Start Joystick**. Steer with
  **W A S D** or the arrow keys. Hold **Shift** to go faster.
- **Stop:** click **Stop** to get your real location back. Quitting the app does
  it too.

The map follows your iPhone's blue dot. Drag the map to look around. Click
**Re-center** to go back to the dot.

To check it worked, open **Maps** on the iPhone. The blue dot should be at the
place you picked.

## Update

When a new version is out, the app shows a banner. Click **Update**. It
downloads and builds the new version (a few minutes), then restarts by itself.
You can also choose **iOS GPS Spoofer ▸ Check for Updates…**, or run the
install line again. Your favorites and saved routes are kept.

## Something not working?

**The install stopped with an error.**
Run the install line again. If it fails the same way, send the developer the
file `~/Library/Logs/iOS GPS Spoofer/install.log`. To find it, open Finder,
press **⌘ ⇧ G**, and paste that path.

**Terminal says "xcrun: error: invalid active developer path".**
Apple's developer tools are missing. Run `xcode-select --install`, click
**Install**, wait for it to finish, then run the install line again.

**An old copy of the project fails to build with an error about `glassEffect`.**
That copy is out of date. Use the install line above. It always gets the
newest version.

**The app says "Connect your iPhone", but it's plugged in.**
- Unlock the iPhone. Tap **Trust** if it asks.
- Try another cable. Some cables only charge.
- Plug straight into the Mac, not into a hub or a monitor.
- Unplug the iPhone, wait 5 seconds, and plug it back in.
- Still nothing? Restart the iPhone and the Mac.

**There's no Developer Mode in the iPhone's Settings.**
Keep the iPhone plugged in and unlocked. In the app, click **Show on iPhone**
in the checklist (or in the orange banner), then look in Settings ▸ Privacy &
Security again.

**The app says Developer Mode is off.**
Turn it on in **Settings ▸ Privacy & Security ▸ Developer Mode**. The iPhone
restarts. Unlock it and tap **Turn On**. The app notices by itself.

**The app asks to install a helper tool.**
Click **Install**. It takes about a minute and needs the internet.

**It says "Couldn't load Apple's developer support".**
Make sure the Mac is online and the iPhone is unlocked. The app keeps trying.

**The status says "Reconnecting".**
The connection dropped for a moment. Keep the cable in and the iPhone unlocked.
The app keeps trying for about two minutes, then carries on from the same
spot. If it gives up, click **Try Again**.

**The location didn't change on the iPhone.**
- Wait until the status at the bottom of the map says **Live** or **Moving**.
- Open **Maps** on the iPhone to check.
- Some apps remember your old location. Close the app fully, then open it again.

**The iPhone is stuck at the fake location.**
Open the app and click **Stop**. Or restart the iPhone. Restarting always
brings back the real location.

**Something else?**
In the app, choose **Help ▸ Copy Diagnostics**. Paste that into a message to
the developer.

## Uninstall

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1/main/install.sh | bash -s -- --uninstall
```

It removes the app and its helper tool. Your favorites and routes stay in
`~/Library/Application Support/iOS GPS Spoofer`. Delete that folder too if you
don't need them.

## Good to know

- It uses the same feature as Apple's Xcode "Simulate Location". There's no
  jailbreak, and nothing is installed on the iPhone.
- The fake location lasts while the app runs. Stop, quit or restart the iPhone
  to end it.
- Wi-Fi can work after the first USB setup. In Finder, select your iPhone and
  turn on "Show this iPhone when on Wi-Fi". USB is more reliable.
- Some apps and games can tell when a location is fake, and may block or ban
  accounts. Use it at your own risk.
- It's meant for testing location-based apps on devices you own.

## For developers

How it works, the command-line tool, building from source, tests and
packaging: [docs/DEVELOPERS.md](docs/DEVELOPERS.md). The iPhone remote app:
[docs/IPHONE-REMOTE.md](docs/IPHONE-REMOTE.md). The plan for spoofing from the
iPhone alone, on cellular: [docs/PHONE-ONLY.md](docs/PHONE-ONLY.md).
