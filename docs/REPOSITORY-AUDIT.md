# Repository sweep — October 13, 2026

Baseline: `db6e5f7931842ca7c2fa89fa724eed487ef5a021` (`main`). Scope is GPS control of the user's own iPhone, from that phone, with the computer off after setup. Target: iOS 17 and newer.

## Coverage and evidence

- Inventoried and hashed all 248 tracked files (233 classified as text), including source, tests, configuration, scripts, web documentation and image assets. Read all distinct reachable Git blobs with automated pattern checks; reviewed connection, pairing, process lifetime, remote authentication, import, update and release paths in detail. This is a repository sweep, not a claim that every historical line or binary was manually audited.
- Enumerated all 154 reachable commits, their changed-file statistics, ten remote branches and three tags. `staging` has five commits absent by SHA from main; their route/traffic changes have later equivalents on main. No hidden, working standalone implementation was found in those branch changes.
- Inspected both merged PRs and enumerated all 78 Actions runs: 61 success, 8 failure and 9 cancellation. Latest baseline CI succeeded. Earlier failures concern compiler/hang/redaction work, followed by passing runs. This does not establish device compatibility.
- Downloaded all seven assets from releases v2.2.0, v2.3.0 and v2.4.0; each SHA-256 matches GitHub's asset digest. Inspected all three IPA property lists. They require iOS 17.0, carry background location mode, and have iPhone app versions/builds 1.0/1, 1.1/3 and 1.1/4 respectively. Archives and checksums are not a real-device execution test.
- Mounted each downloaded DMG read-only without launching the app. All three apps pass deep/strict code-signature verification (ad-hoc signing, not notarization), require macOS 14.0, and carry source stamps matching their release tags: `9eb714b` (2.2.0), `1dece0f` (2.3.0), `77539c7` (2.4.0).
- Built and ran the baseline Swift test suites. Ran the Python helper/pairing suites; tests needing an installed pymobiledevice3 environment were skipped in the initial Python-only run. See the validation section for the final run.
- No GitHub token-shaped values were found by the narrow automated scan. Private-key text matches are redaction fixtures, not established leaked credentials. Force-try use is confined to fixed regular expressions and fixtures; the four fatalError sites are programmatic map-view coder initializers. These checks are not a guarantee that no secrets exist.

## Findings relevant to standalone use

1. **The phone already has a local tunnel and teleport backend.** `OnDeviceSimulator` uses idevice 0.1.68, Remote Pairing first, lockdown/CoreDeviceProxy second, then RSD/DVT. LocalDevVPN and a pairing file are setup dependencies; the Mac is not in this runtime command path.
2. **iOS 17.0–17.3 was blocked at the app layer.** The UI gates phone-only mode at 17.4. Remote Pairing is a different route from CoreDeviceProxy; merely removing the gate would not prove it works on those versions. Route eligibility must distinguish those protocols and remain explicitly unverified on devices.
3. **Reboot breaks computer independence.** There is no image import or image-mount call in the baseline phone backend. The instructions require a Mac to mount developer support after reboot.
4. **Phone joystick/routes/timer are Mac commands.** The new controls on main call ConnectionManager; baseline phone mode only teleports. They need a local execution backend, including stop, pause, deadline and abandoned-operation handling.
5. **Held-location liveness is incomplete.** The phone engine reconnects on a subsequent failed move but does not periodically verify an otherwise static hold. A connection can drop while the screen still says active.
6. **Stop can overlap preflight.** The phone's start path waits for the VPN probe before submitting a set. A stop during that wait needs a generation check before the new connection is submitted.
7. **Published iPhone builds lag main.** v2.4.0 predates the joystick/routes commits. Main added these without changing the iPhone build number (still 4), so version notices cannot distinguish the new binary. The next iPhone build needs a new number and the expected-version constant must agree.
8. **Release notes disagree on newer iOS.** v2.3.0 says Remote Pairing tries newer versions; v2.4.0 warns they may fail. Neither establishes a tested version matrix. Avoid universal support claims or blanket assertions that all newer versions are blocked.

## Other limitations retained

- The Mac remote protocol is HTTP with bearer tokens on a local network. Token hashing at rest and pairing rate limits do not encrypt the network. Use trusted networks; transport encryption is separate work.
- Free-account sideloading expires; installing with SideStore or a developer account remains separate from GPS control. The app does not renew its signing itself.
- Background location authorization does not guarantee perpetual execution. iOS may suspend/terminate an app; a user force-quit or phone reboot cannot be promised to preserve a session.
- Apple's developer protocols and images vary by OS/build. A framework build, simulator run or unit test cannot certify all iOS 17+ versions, future versions, cellular behavior or location seen in Maps.
- The supplied device log has 308 location commands plus one stop with matching replies. It is evidence about that captured session, not this repository's newly built IPA. No pairing credentials are committed or included in this report.

## Implementation and validation

Implemented on `codex/phone-standalone-ios17`:

- A shared control interface backed by either the existing Mac connection or a new local PhoneMotionController. Phone mode now provides joystick, MapKit/direct routes, waits, closed loops, ping-pong, pause/resume and a local automatic-stop timer. Its route backend uses selected speed; it does not claim the Mac's traffic-light/OSM realism.
- Imported Apple DDI folders are bounded, reject unsafe/symlink paths and verify payload checksums. Combined manifests are handled by complete payload sets, not by the mere presence of a manifest entry. Both personalized and Cryptex FFI mount paths exist; RSD advertisements determine whether the Cryptex path is available. After mounting, the tunnel reconnects to refresh Instruments services.
- Remote Pairing eligibility extends to iOS 17.0 with explicit experimental wording. Lockdown/CoreDeviceProxy remains restricted to 17.4+. The Mac pairing export assistant now permits an attempt for a trusted iOS 17 device. None of this proves Apple exposes the required local services on 17.0–17.3.
- A 15-second hold heartbeat, bounded move waits, generation checks after preflight, an explicit stopping state with coalesced clears, and an unconfirmed-Stop message prevent misleading active states and motion restarting while Stop is still pending.
- iPhone build number 5, matching Mac expected-version constant, hosted iOS tests and a CI test action.

Validation completed locally:

| Check | Result |
|---|---|
| Baseline Swift suites | 627 tests passed |
| Final Swift suites | 643 tests passed (61 + 425 + 157), zero failures |
| Hosted iOS 27 simulator tests | 8 passed, zero failures/skips: preflight Stop, input during a slow Stop, invalid coordinates, unconfirmed clear, joystick release, route pause/stop, heartbeat failure, local deadline |
| Python helper suite, pymobiledevice3 11.29.0 | 17 passed, zero skips |
| Python Remote Pairing suite, same dependency | 14 passed, zero skips |
| Physical-device Release build | Succeeded, unsigned; iOS deployment target 17.0 |
| Supplied DDI through the actual Swift validator | Build 27A5228h, complete personalized payloads; Cryptex files are absent |
| Diff whitespace check | Passed |

The unsigned simulator test-host run stalled during preparation; an ad-hoc-signed host with parallel testing disabled passed. CI uses that successful configuration.

The first PR CI run exposed a Swift 6.1.2 compiler crash when lowering actor-isolated constructor default arguments in the App's State initializer (local Xcode 27 uses Swift 6.4). The controller now has a production convenience initializer that constructs those dependencies explicitly, and a separate initializer for tests. This keeps the older toolchain build check rather than bypassing it by selecting a newer compiler.

Once that crash was fixed, Xcode 16's older MapKit SDK rejected its non-Sendable directions response crossing into the main actor. The directions completion callback now converts the response into Sendable route points before resuming the actor. The dependency remains on Apple's SDK; no unchecked Sendable annotation was added to MapKit objects.

Still unverified: actual developer-image mounting, real RSD/DVT GPS commands from this binary, iOS 17.0–17.3, cellular, reboot with Mac off and background/force-quit behavior. The supplied DDI's matching hashes do not establish compatibility with any particular phone. See [PHONE-STANDALONE-TESTING.md](PHONE-STANDALONE-TESTING.md). No release is published by this audit.
