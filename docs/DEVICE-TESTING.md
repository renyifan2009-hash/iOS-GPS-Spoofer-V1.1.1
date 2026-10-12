# Checking AnyWhere on a real iPhone

Everything below needs a real iPhone, a Mac and a few minutes. Nothing here can be proven in the
simulator or in CI, so it was not claimed to work. Tick each line and send back what happened,
working or not.

Use the **ready-made app** (the DMG from the
[Releases page](https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3/releases/latest))
for the first pass. It is the file CI builds and starts.

## A. The Mac app (USB, the supported path)

| # | Do this | You should see | OK? |
|---|---|---|---|
| A1 | Open AnyWhere from Applications (first time: System Settings ▸ Privacy & Security ▸ Open Anyway). | The window opens. No "quit unexpectedly". The icon is the globe. | |
| A2 | If the old "iOS GPS Spoofer" is still in Applications, wait 3 seconds after the window shows. | A prompt offers to move the old app to the Trash. Choose **Move to Trash**. Your favorites are still there. | |
| A3 | Plug the iPhone in, unlock it, tap **Trust**. Follow the checklist. | Each row turns green. An untrusted iPhone shows "tap Trust", not "iOS 0". | |
| A4 | Teleport somewhere, then press **Stop**. | The iPhone's blue dot moves, then returns to the real place. | |
| A5 | Start a route, then close the window with ⌘W. | The route keeps going (the app stays open). Click the Dock icon to bring the window back. | |
| A6 | ⌘Q during a route. | The iPhone goes back to its real location. | |
| A7 | On a fresh install (or after `defaults delete com.iosgpsspoofer.gui hasSeenWelcome`), press ⌘Q while the Welcome sheet is showing. | The app quits. (CI showed that `NSApp.terminate` is ignored in that state when called from a timer in an inactive app. Whether a real ⌘Q is affected is untested: please try it, and tell me if it doesn't quit.) | |

| A8 | Teleport somewhere and leave it held. Close the Mac's lid for a minute, then open it. | Within about 15 seconds the app says it woke and re-applies the location. The iPhone is still at the place. | |
| A9 | While held, unplug the cable and plug it back in. | The app notices and reconnects (a few seconds). It never says "iOS 0", and never loops forever. | |
| A10 | While held, force-quit the app (Activity Monitor ▸ Quit ▸ Force Quit), then open it again. | On launch it says it cleaned up and puts the real location back (or tells you to restart the iPhone if it couldn't). | |
| A11 | Location ▸ Stop Automatically After ▸ 15 minutes, then teleport somewhere and leave it. | A timer chip on the card counts down. At 0:00 the iPhone's blue dot goes back to the real place and a note says so. | |

## B. The pairing file (the tester's problem)

| # | Do this | You should see | OK? |
|---|---|---|---|
| B1 | With **no** iPhone plugged in: File ▸ **Pairing File for the iPhone App…** (⇧⌘K). | The window opens and says "No iPhone is connected" and what to do. The menu item is not greyed out. | |
| B2 | Plug the iPhone in. Click **Create Pairing File**. | "Pairing file created", with its name and the folder (your **Desktop**). **Show in Finder** selects it. | |
| B3 | Click **Send … with AirDrop**, accept on the iPhone. | The iPhone offers AnyWhere in the list. Tapping it opens AnyWhere's setup screen with "Pairing file added" ticked. | |
| B4 | Repeat B3 but choose **Save to Files** on the iPhone. In AnyWhere: This iPhone ▸ **Choose File**. | The file is in Downloads and imports. | |
| B5 | In the Mac window, click **Remove File from This Mac**. | The file leaves the Desktop. The iPhone keeps working. | |

## C. Installing the iPhone app

| # | Do this | You should see | OK? |
|---|---|---|---|
| C1 | File ▸ **Install AnyWhere on iPhone…** with the iPhone plugged in. | It says whether AnyWhere is on the iPhone and which version. | |
| C2 | Click **Get the iPhone app**. | "Got AnyWhere …", the checksum line, a file in Downloads. (Needs a release that has `AnyWhere.ipa` and `SHA256SUMS.txt`.) | |
| C3 | With Sideloadly or AltStore installed: click **Open in …**. | The tool opens with the file. It asks for your Apple ID itself. | |
| C4 | After installing: trust your Apple ID on the iPhone, turn on Developer Mode. | AnyWhere opens on the iPhone. | |

## D. Updating without breaking anything

| # | Do this | You should see | OK? |
|---|---|---|---|
| D1 | Run the one-line installer on a Mac that has a swift.org toolchain (swiftly). | A yellow warning about the non-Apple Swift. If the built app crashes, the installer says so, does **not** replace your copy, and points to the download. | |
| D2 | In AnyWhere, click **Update** when the banner shows. | It either finishes and reopens, or says why it stopped (in the banner), never "Updating…" for ever. | |

## E. The iPhone-only mode (beta, may not work on iOS 26.4 and later)

Apple tightened how developer services answer on the iPhone itself in iOS 26.4. The mode needs
a real-iPhone test and may not work on newer iOS versions. This project does not work around
Apple's change. If it fails, copy the small print under the error and send it.

| # | Do this | You should see | OK? |
|---|---|---|---|
| E1 | Do B first. Install LocalDevVPN, tap Connect. In AnyWhere on the iPhone: This iPhone ▸ Start Here. | Either the location changes, or a plain error with small print. | |
| E2 | Close AnyWhere on the iPhone. | Say what happens to the location. | |

## What to send back

- The iOS version of the iPhone and the macOS version of the Mac.
- For a crash: the newest file in `~/Library/Logs/DiagnosticReports` that starts with "AnyWhere",
  and `~/Library/Logs/AnyWhere/install.log`.
- For anything else: **Help ▸ Copy Diagnostics** in the Mac app.
