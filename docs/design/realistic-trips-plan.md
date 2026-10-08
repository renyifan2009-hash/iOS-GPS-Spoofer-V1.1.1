# Realistic trips: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Routes and the joystick move like a real person: random red lights,
stop signs, slowing for turns, gradual speed changes, road speed limits, waits
at chosen stops, breaks on long drives, and slowly drifting GPS.

**Architecture:** A pure planning layer in SpooferCore (trip planner, trip
controller, curve speeds, GPS drift, OpenStreetMap loader and matcher) with unit
tests and no UI. The Mac app's motion loop asks the controller how far to move
each tick; the classic engine and the CLI bake the same controller into a timed
GPX track. The UI adds a switch, per-stop waits, a status in the HUD and map
markers.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, SwiftUI + AppKit +
MapKit (macOS 14), XCTest, URLSession, the public Overpass API.

**Spec:** [realistic-trips.md](realistic-trips.md)

## Global Constraints

- macOS 14 / iOS 17 deployment targets (Package.swift `platforms`); must build
  with Xcode 16 (Swift 6.0), Xcode 26, and a swift.org toolchain on the macOS 15
  SDK (all in CI).
- SpooferCore stays UI-free and Foundation-only; every new type there is
  `Sendable`.
- No network in unit tests; Overpass is tested with a saved JSON answer.
- Overpass etiquette: one request at a time, at least 1 s apart, User-Agent
  `iOS-GPS-Spoofer/<version> (+https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1)`,
  cache answers 30 days.
- UI copy: plain, short sentences; no jargon. US wording ("Yield",
  "Crosswalk").
- Commits: no AI attribution lines (owner's rule). Push to `staging`, run CI,
  fast-forward `main` only when all jobs pass.

## File map

| File | Responsibility |
|---|---|
| `Sources/SpooferCore/TripTypes.swift` | RNG, motion profiles, odds, settings, stops, limits, status, road features |
| `Sources/SpooferCore/CurveSpeeds.swift` | speed limits from the route's shape |
| `Sources/SpooferCore/TripPlanner.swift` | per-lap plans (random choices), lap time estimate |
| `Sources/SpooferCore/TripTiming.swift` | time to the end of a lap from a plan |
| `Sources/SpooferCore/TripController.swift` | tick-by-tick speed and stops, breaks, ETA |
| `Sources/SpooferCore/GPSDrift.swift` | Gauss–Markov position error |
| `Sources/SpooferCore/RouteMatcher.swift` | where points near a route are met along it; waypoint distances |
| `Sources/SpooferCore/SpeedLimits.swift` | `maxspeed` parsing, defaults, speed zones from ways |
| `Sources/SpooferCore/OverpassLoader.swift` | query, fetch, cache, parse; features along a route |
| `Sources/SpooferCore/RouteBuilder.swift` | + realistic timed track |
| `Tests/SpooferCoreTests/TripTests.swift` | planner, controller, timing, curves, drift, track |
| `Tests/SpooferCoreTests/RoadDataTests.swift` | matcher, speed limits, Overpass parsing and pipeline |
| `Tests/SpooferCoreTests/Fixtures/overpass-sample.json` | a saved Overpass answer |
| `Sources/iosgpsspoofer-gui/AppModel+Trip.swift` | road data state, planner building, waits |
| `Sources/iosgpsspoofer-gui/AppModel+Motion.swift` | controller in the route tick; drift; joystick easing |
| `Sources/iosgpsspoofer-gui/AppModel.swift`, `AppModel+Route.swift`, `AppModel+Library.swift` | state, waits persistence, ETA, lap time |
| `Sources/iosgpsspoofer-gui/Preferences.swift`, `SettingsView.swift` | realism settings |
| `Sources/iosgpsspoofer-gui/InspectorView.swift` | realism card, stop waits |
| `Sources/iosgpsspoofer-gui/HUDView.swift` | stopped status in the speed tile |
| `Sources/iosgpsspoofer-gui/MapPicker.swift`, `MainView.swift` | traffic-light and stop-sign markers |
| `Sources/iosgpsspoofer/Commands.swift` | `route --realistic` |
| `Sources/SpooferCore/Library.swift` | saved routes keep waits |

---

### Task 1: Core trip types

**Files:**
- Create: `Sources/SpooferCore/TripTypes.swift`
- Test: `Tests/SpooferCoreTests/TripTests.swift`

**Interfaces:**
- Produces: `SplitMix64(seed:)`, `RandomNumberGenerator.gaussian()`, `.chance(_:)`;
  `MotionProfile` (`.walk/.run/.cycle/.drive`, `forSpeed(_:)`, `acceleration`,
  `braking`, `lateralAcceleration: Double?`, `minimumTurnSpeed`, `isOnFoot`);
  `TripOdds` (all odds/waits); `TripSettings`; `TripStop` (+`Reason`);
  `TripLimit`; `TripStatus`; `WaypointStop`; `RoadFeature` (+`Kind`);
  `SpeedZone`; `RoadFeatures`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import SpooferCore

final class TripTypesTests: XCTestCase {
    func testProfileFromSpeed() {
        XCTAssertEqual(MotionProfile.forSpeed(1.4).kind, .walk)
        XCTAssertEqual(MotionProfile.forSpeed(3).kind, .run)
        XCTAssertEqual(MotionProfile.forSpeed(6).kind, .cycle)
        XCTAssertEqual(MotionProfile.forSpeed(31).kind, .drive)
        XCTAssertTrue(MotionProfile.walk.isOnFoot)
        XCTAssertNil(MotionProfile.walk.lateralAcceleration)
    }

    func testSeededRandomIsRepeatable() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42)
        XCTAssertEqual((0..<5).map { _ in a.next() }, (0..<5).map { _ in b.next() })
    }

    func testGaussianHasUnitSpread() {
        var rng = SplitMix64(seed: 7)
        let samples = (0..<20_000).map { _ in rng.gaussian() }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let variance = samples.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(samples.count)
        XCTAssertEqual(mean, 0, accuracy: 0.03)
        XCTAssertEqual(variance, 1, accuracy: 0.05)
    }

    func testOddsStayInRange() {
        var rng = SplitMix64(seed: 3)
        for _ in 0..<500 {
            XCTAssertTrue((8...60).contains(TripOdds.redWait(&rng)))
            XCTAssertTrue((1.5...3.5).contains(TripOdds.stopSignWait(&rng)))
            XCTAssertTrue((600...1200).contains(TripOdds.breakLength(&rng)))
        }
    }

    func testUniqueFeaturePoints() {
        let p = GeoPoint(37, -122)
        let features = RoadFeatures(features: [
            RoadFeature(kind: .trafficSignal, distance: 10, point: p),
            RoadFeature(kind: .trafficSignal, distance: 900, point: p),   // the same light, passed twice
            RoadFeature(kind: .stopSign, distance: 50, point: GeoPoint(37.001, -122)),
        ])
        XCTAssertEqual(features.uniqueCount(of: .trafficSignal), 1)
        XCTAssertEqual(features.uniqueCount(of: .stopSign), 1)
    }
}
```

- [ ] **Step 2: Run to see it fail** — `swift build --build-tests 2>&1 | grep error: | head`
  Expected: errors for `MotionProfile`, `SplitMix64`, `TripOdds`, `RoadFeatures`.

- [ ] **Step 3: Implement `TripTypes.swift`**

```swift
import Foundation

/// A small seedable random number generator (SplitMix64), so a trip's random
/// choices can be repeated (tests, and the same lap after a replan).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension RandomNumberGenerator {
    /// A standard normal sample (Box–Muller).
    public mutating func gaussian() -> Double {
        let u1 = Double.random(in: Double.ulpOfOne..<1, using: &self)
        let u2 = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < p
    }
}

/// How a kind of traveller speeds up, slows down and takes corners.
public struct MotionProfile: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case walk, run, cycle, drive }

    public let kind: Kind
    /// Comfortable speeding up from a stop, m/s².
    public let acceleration: Double
    /// Comfortable braking, m/s².
    public let braking: Double
    /// Sideways acceleration accepted in curves, m/s²; nil: doesn't slow for curves.
    public let lateralAcceleration: Double?
    /// Slowest speed through the tightest turn, m/s.
    public let minimumTurnSpeed: Double

    public static let walk = MotionProfile(kind: .walk, acceleration: 0.5, braking: 0.8,
                                           lateralAcceleration: nil, minimumTurnSpeed: 0)
    public static let run = MotionProfile(kind: .run, acceleration: 1.0, braking: 1.5,
                                          lateralAcceleration: nil, minimumTurnSpeed: 0)
    public static let cycle = MotionProfile(kind: .cycle, acceleration: 1.0, braking: 2.0,
                                            lateralAcceleration: 2.5, minimumTurnSpeed: 3.0)
    public static let drive = MotionProfile(kind: .drive, acceleration: 1.8, braking: 2.7,
                                            lateralAcceleration: 2.7, minimumTurnSpeed: 3.5)

    /// The profile for a top speed (m/s).
    public static func forSpeed(_ speed: Double) -> MotionProfile {
        switch speed {
        case ..<2.2: return .walk
        case ..<4.5: return .run
        case ..<9: return .cycle
        default: return .drive
        }
    }

    public var isOnFoot: Bool { kind == .walk || kind == .run }
}

/// The odds and waits for lights, signs and breaks (see docs/design/realistic-trips.md).
public enum TripOdds {
    /// How far before a light's position the stop line is, metres.
    public static let stopLineOffset = 6.0

    /// Chance a light is red when you reach it.
    public static func redLight(_ profile: MotionProfile) -> Double { profile.isOnFoot ? 0.5 : 0.45 }

    /// Seconds waited at a red light (8–60, most often around half a minute).
    public static func redWait(_ rng: inout SplitMix64) -> TimeInterval {
        triangular(&rng, low: 8, mode: 30, high: 60)
    }

    /// A crossing light is red for someone on foot / for traffic passing it.
    public static let crossingRedOnFoot = 0.5
    public static let crossingRedForTraffic = 0.25

    public static func crossingWait(_ rng: inout SplitMix64) -> TimeInterval {
        triangular(&rng, low: 5, mode: 20, high: 45)
    }

    public static func stopSignWait(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 1.5...3.5, using: &rng)
    }

    /// Yield: usually slow to this speed (m/s); sometimes stop.
    public static let giveWaySpeed = 4.0
    public static let giveWayStop = 0.25

    public static func giveWayWait(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 1...3, using: &rng)
    }

    /// Drivers keep a little under or over the limit for the whole trip.
    public static let driverFactor = 0.95...1.05

    /// Driving time before a break, and the break itself.
    public static let meanBreakInterval: TimeInterval = 2 * 3600
    public static let meanBreakLength: TimeInterval = 15 * 60

    public static func breakInterval(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 1.75 * 3600...2.25 * 3600, using: &rng)
    }

    public static func breakLength(_ rng: inout SplitMix64) -> TimeInterval {
        Double.random(in: 600...1200, using: &rng)
    }

    static func triangular(_ rng: inout SplitMix64, low: Double, mode: Double, high: Double) -> Double {
        let u = Double.random(in: 0..<1, using: &rng)
        let cut = (mode - low) / (high - low)
        if u < cut { return low + ((high - low) * (mode - low) * u).squareRoot() }
        return high - ((high - low) * (high - mode) * (1 - u)).squareRoot()
    }
}

/// What a trip does, chosen in the app.
public struct TripSettings: Sendable, Equatable {
    /// The chosen speed, m/s: the cruise speed, and the cap when speed limits apply.
    public var topSpeed: Double
    public var profile: MotionProfile
    public var trafficLights: Bool
    public var stopSigns: Bool
    public var slowForTurns: Bool
    public var speedLimits: Bool
    public var breaks: Bool
    /// 0…0.3: slow random speed changes.
    public var speedVariation: Double
    /// Multiplies every cruise speed (pacing by duration fits the lap time with it).
    public var paceFactor: Double

    public init(topSpeed: Double, profile: MotionProfile? = nil, trafficLights: Bool = true,
                stopSigns: Bool = true, slowForTurns: Bool = true, speedLimits: Bool = true,
                breaks: Bool = true, speedVariation: Double = 0, paceFactor: Double = 1) {
        self.topSpeed = topSpeed
        self.profile = profile ?? .forSpeed(topSpeed)
        self.trafficLights = trafficLights
        self.stopSigns = stopSigns
        self.slowForTurns = slowForTurns
        self.speedLimits = speedLimits
        self.breaks = breaks
        self.speedVariation = speedVariation
        self.paceFactor = paceFactor
    }

    /// Changing these needs a new plan; the others are read every tick.
    func plansDiffer(from other: TripSettings) -> Bool {
        profile != other.profile || trafficLights != other.trafficLights || stopSigns != other.stopSigns
            || slowForTurns != other.slowForTurns || speedLimits != other.speedLimits
    }
}

/// A place in a lap where the trip comes to a halt.
public struct TripStop: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case redLight, stopSign, giveWay, crossing
        /// One of your stops (index into the waypoints).
        case waypoint(Int)
        case destination, turnaround
        /// A break on a long drive.
        case rest
    }

    /// Metres into the lap.
    public var distance: Double
    /// Seconds to wait there; `.infinity` at the destination.
    public var wait: TimeInterval
    public var reason: Reason

    public init(distance: Double, wait: TimeInterval, reason: Reason) {
        self.distance = distance
        self.wait = wait
        self.reason = reason
    }
}

/// The fastest speed at a point (a curve, a yield sign).
public struct TripLimit: Sendable, Equatable {
    public var distance: Double
    public var speed: Double

    public init(distance: Double, speed: Double) {
        self.distance = distance
        self.speed = speed
    }
}

public enum TripStatus: Sendable, Equatable {
    case moving
    /// Stopped for `reason`; `remaining` is nil when it waits until you stop it.
    case stopped(TripStop.Reason, remaining: TimeInterval?)
}

/// One of your stops, with how long to wait there.
public struct WaypointStop: Sendable, Equatable {
    /// Index into the route's waypoints.
    public var index: Int
    /// Metres from the start of the route.
    public var distance: Double
    public var wait: TimeInterval

    public init(index: Int, distance: Double, wait: TimeInterval) {
        self.index = index
        self.distance = distance
        self.wait = wait
    }
}

/// Something on the road that changes how a trip moves.
public struct RoadFeature: Sendable, Equatable, Codable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case trafficSignal, stopSign, giveWay, signalCrossing
    }

    public var kind: Kind
    /// Metres from the start of the route, one entry per time the route passes it.
    public var distance: Double
    public var point: GeoPoint

    public init(kind: Kind, distance: Double, point: GeoPoint) {
        self.kind = kind
        self.distance = distance
        self.point = point
    }
}

/// A stretch of road with a speed limit.
public struct SpeedZone: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    /// m/s.
    public var speed: Double

    public init(start: Double, end: Double, speed: Double) {
        self.start = start
        self.end = end
        self.speed = speed
    }
}

/// What OpenStreetMap knows about a route's roads, by distance along it.
public struct RoadFeatures: Sendable, Equatable, Codable {
    public var features: [RoadFeature]
    public var zones: [SpeedZone]
    /// False when some pieces of the route couldn't be loaded.
    public var complete: Bool

    public init(features: [RoadFeature] = [], zones: [SpeedZone] = [], complete: Bool = true) {
        self.features = features
        self.zones = zones
        self.complete = complete
    }

    public static let none = RoadFeatures()

    /// Different places of this kind (a light passed twice counts once).
    public func uniqueCount(of kind: RoadFeature.Kind) -> Int {
        Set(features.filter { $0.kind == kind }.map(\.point)).count
    }

    /// Fraction of `length` metres covered by a known speed limit.
    public func speedLimitCoverage(of length: Double) -> Double {
        guard length > 0 else { return 0 }
        return min(1, zones.reduce(0) { $0 + max(0, $1.end - $1.start) } / length)
    }
}
```

- [ ] **Step 4: Run the tests** — `swift build --build-tests && swift test --skip-build --filter TripTypesTests`
  Expected: 5 tests pass.

- [ ] **Step 5: Commit** — `git add Sources/SpooferCore/TripTypes.swift Tests/SpooferCoreTests/TripTests.swift && git commit -m "Trip types: profiles, odds, settings, stops, road features"`

### Task 2: Curve speeds

**Files:**
- Create: `Sources/SpooferCore/CurveSpeeds.swift`
- Test: `Tests/SpooferCoreTests/TripTests.swift` (append)

**Interfaces:**
- Consumes: `MotionProfile`, `TripLimit`, `RoutePath`.
- Produces: `CurveSpeeds.limits(along: RoutePath, profile: MotionProfile, span: Double = 12) -> [TripLimit]`,
  `CurveSpeeds.circumradius(_:_:_:) -> Double`.

- [ ] **Step 1: Failing tests**

```swift
final class CurveSpeedsTests: XCTestCase {
    /// 200 m north, then 200 m east: one right-angle corner.
    private func corner() -> RoutePath {
        let start = GeoPoint(37.0, -122.0)
        let bend = start.moved(by: 200, bearing: 0)
        return RoutePath([start, bend, bend.moved(by: 200, bearing: 90)])
    }

    func testRightAngleRadius() {
        let b = GeoPoint(37, -122)
        let r = CurveSpeeds.circumradius(b.moved(by: 12, bearing: 180), b, b.moved(by: 12, bearing: 90))
        XCTAssertEqual(r, 8.49, accuracy: 0.1)
        XCTAssertEqual(CurveSpeeds.circumradius(b.moved(by: 12, bearing: 180), b, b.moved(by: 12, bearing: 0)),
                       .infinity)
    }

    func testCarSlowsForACorner() {
        let limits = CurveSpeeds.limits(along: corner(), profile: .drive)
        XCTAssertEqual(limits.count, 1)
        XCTAssertEqual(limits[0].distance, 200, accuracy: 1)
        XCTAssertEqual(limits[0].speed, 4.8, accuracy: 0.5)   // √(2.7 × 8.5)
    }

    func testWalkersDontSlowAndStraightRoadsHaveNoLimits() {
        XCTAssertTrue(CurveSpeeds.limits(along: corner(), profile: .walk).isEmpty)
        let a = GeoPoint(37, -122)
        let straight = RoutePath([a, a.moved(by: 100, bearing: 0), a.moved(by: 200, bearing: 0)])
        XCTAssertTrue(CurveSpeeds.limits(along: straight, profile: .drive).isEmpty)
    }
}
```

- [ ] **Step 2: Run to see it fail** (undefined `CurveSpeeds`).

- [ ] **Step 3: Implement**

```swift
import Foundation

/// How fast a traveller can take the route's curves: v = √(lateral acceleration × radius),
/// with the radius of the circle through the points `span` metres before and after each corner.
public enum CurveSpeeds {
    /// Highest speed worth limiting; faster curves never constrain anyone.
    static let ceiling = 45.0

    public static func limits(along path: RoutePath, profile: MotionProfile, span: Double = 12) -> [TripLimit] {
        guard let lateral = profile.lateralAcceleration, path.points.count >= 3, path.length > 2 * span else {
            return []
        }
        var limits: [TripLimit] = []
        for i in 1..<(path.points.count - 1) {
            let s = path.cumulative[i]
            guard s >= span, s <= path.length - span else { continue }
            let radius = circumradius(path.sample(at: s - span).point, path.points[i],
                                      path.sample(at: s + span).point)
            guard radius.isFinite else { continue }
            let speed = max(profile.minimumTurnSpeed, (lateral * radius).squareRoot())
            guard speed < ceiling else { continue }
            // Points of one bend: keep the slowest.
            if let last = limits.last, s - last.distance < 15 {
                if speed < last.speed { limits[limits.count - 1] = TripLimit(distance: s, speed: speed) }
            } else {
                limits.append(TripLimit(distance: s, speed: speed))
            }
        }
        return limits
    }

    /// Radius (metres) of the circle through three nearby points; infinity when they're in a line.
    public static func circumradius(_ a: GeoPoint, _ b: GeoPoint, _ c: GeoPoint) -> Double {
        let k = Geo.earthRadius * .pi / 180
        let cosLat = cos(Geo.radians(b.latitude))
        func xy(_ p: GeoPoint) -> (x: Double, y: Double) {
            (Geo.normalizedLongitude(p.longitude - b.longitude) * k * cosLat, (p.latitude - b.latitude) * k)
        }
        let p = xy(a), q = xy(c)   // b is the origin
        let twiceArea = abs(p.x * q.y - p.y * q.x)
        guard twiceArea > 1e-6 else { return .infinity }
        return hypot(p.x, p.y) * hypot(q.x, q.y) * hypot(q.x - p.x, q.y - p.y) / (2 * twiceArea)
    }
}
```

- [ ] **Step 4: Tests pass** — `swift test --skip-build --filter CurveSpeedsTests` (after `swift build --build-tests`).
- [ ] **Step 5: Commit** — "Curve speeds from the route's shape"

### Task 3: Trip timing and the trip planner

**Files:**
- Create: `Sources/SpooferCore/TripTiming.swift`, `Sources/SpooferCore/TripPlanner.swift`
- Test: append to `Tests/SpooferCoreTests/TripTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `CurveSpeeds`, `RoutePath`, `LoopMode`.
- Produces:
  - `LapPlan` (`length`, `stops`, `limits`, `zones`, `driverFactor`,
    `cruise(at:settings:) -> Double`, `zoneIndex(at:) -> Int?`, `firstLimit(atOrAfter:) -> Int`).
  - `TripTiming.segmentTime(length:entry:exit:cruise:acceleration:braking:) -> TimeInterval`
  - `TripTiming.time(plan:from:speed:settings:firstStop:) -> TimeInterval`
  - `TripPlanner(path:loopMode:settings:features:waypointStops:)`, `cycleLength`,
    `update(settings:)`, `update(features:)`, `update(waypointStops:)`,
    `lapPlan(lap:seed:) -> LapPlan`, `expectedLapTime(seed:samples:) -> TimeInterval`,
    `fittedPaceFactor(for:) -> Double`.

- [ ] **Step 1: Failing tests**

```swift
final class TripPlannerTests: XCTestCase {
    static func line(_ metres: Double) -> RoutePath {
        let a = GeoPoint(37, -122)
        return RoutePath([a, a.moved(by: metres, bearing: 0)])
    }

    func testSegmentTime() {
        // 1000 m from rest to rest, cruise 10 m/s, a = 1, b = 1: 10 s up (50 m), 900 m at 10, 10 s down.
        XCTAssertEqual(TripTiming.segmentTime(length: 1000, entry: 0, exit: 0, cruise: 10,
                                              acceleration: 1, braking: 1), 110, accuracy: 1e-6)
        // Too short to reach cruise: 100 m, peak √100 = 10 → 20 s.
        XCTAssertEqual(TripTiming.segmentTime(length: 100, entry: 0, exit: 0, cruise: 30,
                                              acceleration: 1, braking: 1), 20, accuracy: 1e-6)
        XCTAssertEqual(TripTiming.segmentTime(length: 100, entry: 10, exit: 10, cruise: 10,
                                              acceleration: 1, braking: 1), 10, accuracy: 1e-6)
    }

    func testOnceEndsWithADestinationStopAndWaypointWaits() {
        let path = Self.line(2000)
        let planner = TripPlanner(path: path, loopMode: .once,
                                  settings: TripSettings(topSpeed: 15),
                                  waypointStops: [WaypointStop(index: 1, distance: 1000, wait: 60)])
        let plan = planner.lapPlan(lap: 0, seed: 1)
        XCTAssertEqual(plan.stops.map(\.reason), [.waypoint(1), .destination])
        XCTAssertEqual(plan.stops.last?.wait, .infinity)
        XCTAssertEqual(plan.stops.first?.distance ?? 0, 1000, accuracy: 1e-9)
    }

    func testRedLightsAreRandomButRepeatable() {
        let path = Self.line(30_000)
        let lights = (1...100).map { RoadFeature(kind: .trafficSignal, distance: Double($0) * 290, point: GeoPoint(37, -122)) }
        let planner = TripPlanner(path: path, loopMode: .loop, settings: TripSettings(topSpeed: 15),
                                  features: RoadFeatures(features: lights))
        let a = planner.lapPlan(lap: 3, seed: 9), b = planner.lapPlan(lap: 3, seed: 9)
        XCTAssertEqual(a, b)
        let reds = a.stops.filter { $0.reason == .redLight }
        XCTAssertGreaterThan(reds.count, 30)
        XCTAssertLessThan(reds.count, 60)          // about 45 of 100
        XCTAssertNotEqual(planner.lapPlan(lap: 4, seed: 9), a)
        XCTAssertEqual(reds.first.map { $0.distance.truncatingRemainder(dividingBy: 290) } ?? 0,
                       290 - TripOdds.stopLineOffset, accuracy: 1e-6)
    }

    func testBackAndForthMirrorsFeatures() {
        let path = Self.line(1000)
        var settings = TripSettings(topSpeed: 15)
        settings.trafficLights = false
        let planner = TripPlanner(path: path, loopMode: .pingPong, settings: settings,
                                  features: RoadFeatures(features: [RoadFeature(kind: .stopSign, distance: 300, point: GeoPoint(37, -122))]))
        let plan = planner.lapPlan(lap: 0, seed: 1)
        XCTAssertEqual(plan.length, 2000, accuracy: 1e-9)
        let signs = plan.stops.filter { $0.reason == .stopSign }.map(\.distance)
        XCTAssertEqual(signs.count, 2)
        XCTAssertEqual(signs[0], 298, accuracy: 1e-9)          // 2 m before, on the way out
        XCTAssertEqual(signs[1], 1698, accuracy: 1e-9)         // 1700 − 2 on the way back
        XCTAssertTrue(plan.stops.contains { $0.reason == .turnaround && abs($0.distance - 1000) < 1e-9 })
    }

    func testSpeedZonesCapCruise() {
        let path = Self.line(1000)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 30),
                                  features: RoadFeatures(zones: [SpeedZone(start: 200, end: 600, speed: 10)]))
        let plan = planner.lapPlan(lap: 0, seed: 2)
        XCTAssertEqual(plan.cruise(at: 100, settings: planner.settings), 30, accuracy: 1e-9)
        XCTAssertEqual(plan.cruise(at: 400, settings: planner.settings), 10 * plan.driverFactor, accuracy: 1e-9)
    }

    func testExpectedLapTimeAndPaceFit() {
        let path = Self.line(3000)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 10))
        // 3000 m at 10 m/s from rest to rest with a = 1.8, b = 2.7: 300 s + 10/3.6 + 10/5.4 ≈ 304.6 s.
        XCTAssertEqual(planner.expectedLapTime(), 304.6, accuracy: 0.5)
        let factor = planner.fittedPaceFactor(for: 600)
        var slower = planner
        slower.update(settings: TripSettings(topSpeed: 10, paceFactor: factor))
        XCTAssertEqual(slower.expectedLapTime(), 600, accuracy: 3)
    }
}
```

- [ ] **Step 2: Run to see it fail.**

- [ ] **Step 3: Implement `TripTiming.swift`**

```swift
import Foundation

/// How long a planned lap takes: a backward pass (the speed each point allows,
/// given the braking ahead), a forward pass (the speed reachable, given the
/// acceleration), then the speed-up / cruise / slow-down time of each stretch.
enum TripTiming {
    /// Seconds to cover `length` metres from `entry` to `exit` speed, cruising at `cruise` when there's room.
    static func segmentTime(length d: Double, entry v0: Double, exit v1: Double, cruise: Double,
                            acceleration a: Double, braking b: Double) -> TimeInterval {
        guard d > 0 else { return 0 }
        let c = max(cruise, v0, v1, 0.05)
        let peakSquared = (2 * a * b * d + b * v0 * v0 + a * v1 * v1) / (a + b)
        let peak = peakSquared.squareRoot()
        if peak <= c { return max(0, (peak - v0) / a) + max(0, (peak - v1) / b) }
        let speedingUp = (c * c - v0 * v0) / (2 * a)
        let slowingDown = (c * c - v1 * v1) / (2 * b)
        return (c - v0) / a + (c - v1) / b + max(0, d - speedingUp - slowingDown) / c
    }

    /// Seconds from `s` (moving at `speed`) to the end of the lap, with the waits
    /// of the stops from index `firstStop` on (infinite waits don't count).
    static func time(plan: LapPlan, from s: Double, speed: Double, settings: TripSettings,
                     firstStop: Int) -> TimeInterval {
        let profile = settings.profile
        struct Node { var at: Double; var cap: Double }
        var nodes = [Node(at: s, cap: .infinity)]
        var waits = 0.0
        if firstStop < plan.stops.count {
            for stop in plan.stops[firstStop...] where stop.distance >= s {
                nodes.append(Node(at: stop.distance, cap: 0))
                if stop.wait.isFinite { waits += stop.wait }
            }
        }
        for limit in plan.limits where limit.distance > s {
            nodes.append(Node(at: limit.distance, cap: limit.speed))
        }
        for zone in plan.zones {
            for edge in [zone.start, zone.end] where edge > s && edge < plan.length {
                nodes.append(Node(at: edge, cap: min(plan.cruise(at: edge - 0.01, settings: settings),
                                                     plan.cruise(at: edge + 0.01, settings: settings))))
            }
        }
        nodes.append(Node(at: plan.length, cap: .infinity))
        nodes.sort { $0.at < $1.at }
        for i in nodes.indices { nodes[i].cap = min(nodes[i].cap, plan.cruise(at: nodes[i].at, settings: settings)) }

        let a = profile.acceleration, b = profile.braking
        var top = nodes.map(\.cap)
        if !nodes.isEmpty { top[0] = speed }
        for i in stride(from: nodes.count - 2, through: 0, by: -1) {
            let d = nodes[i + 1].at - nodes[i].at
            top[i] = min(top[i], (top[i + 1] * top[i + 1] + 2 * b * d).squareRoot())
        }
        var v = top
        v[0] = min(speed, top[0])
        var total = 0.0
        for i in 1..<max(1, nodes.count) {
            let d = nodes[i].at - nodes[i - 1].at
            v[i] = min(top[i], (v[i - 1] * v[i - 1] + 2 * a * d).squareRoot())
            let cruise = plan.cruise(at: (nodes[i].at + nodes[i - 1].at) / 2, settings: settings)
            total += segmentTime(length: d, entry: v[i - 1], exit: v[i], cruise: cruise, acceleration: a, braking: b)
        }
        return total + waits
    }
}
```

- [ ] **Step 4: Implement `TripPlanner.swift`**

```swift
import Foundation

/// One lap's constraints, with its random choices made.
public struct LapPlan: Sendable, Equatable {
    public var length: Double
    /// Sorted by distance.
    public var stops: [TripStop]
    /// Sorted by distance.
    public var limits: [TripLimit]
    /// Sorted, in lap distances.
    public var zones: [SpeedZone]
    /// How this driver treats limits (0.95–1.05), fixed for the lap.
    public var driverFactor: Double

    /// Cruise speed at `s`: the road's limit (times the driver's habit) or the top speed, whichever is lower.
    public func cruise(at s: Double, settings: TripSettings) -> Double {
        let top = settings.topSpeed * settings.paceFactor
        guard let index = zoneIndex(at: s) else { return max(0.1, top) }
        return max(0.1, min(top, zones[index].speed * driverFactor * settings.paceFactor))
    }

    public func zoneIndex(at s: Double) -> Int? {
        var lo = 0, hi = zones.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if zones[mid].start <= s { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let found, s < zones[found].end else { return nil }
        return found
    }

    /// Index of the first limit at or after `s` (limits.count if none).
    public func firstLimit(atOrAfter s: Double) -> Int {
        var lo = 0, hi = limits.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if limits[mid].distance < s { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// Turns a route, its road features and your stops into lap plans.
public struct TripPlanner: Sendable, Equatable {
    /// The path as played (closed for loops).
    public let path: RoutePath
    public let loopMode: LoopMode
    public private(set) var settings: TripSettings
    public private(set) var features: RoadFeatures
    public private(set) var waypointStops: [WaypointStop]
    private var curveLimits: [TripLimit]

    public init(path: RoutePath, loopMode: LoopMode, settings: TripSettings,
                features: RoadFeatures = .none, waypointStops: [WaypointStop] = []) {
        self.path = path
        self.loopMode = loopMode
        self.settings = settings
        self.features = features
        self.waypointStops = waypointStops
        curveLimits = CurveSpeeds.limits(along: path, profile: settings.profile)
    }

    public var cycleLength: Double { loopMode == .pingPong ? path.length * 2 : path.length }

    public mutating func update(settings new: TripSettings) {
        if new.profile != settings.profile { curveLimits = CurveSpeeds.limits(along: path, profile: new.profile) }
        settings = new
    }

    public mutating func update(features new: RoadFeatures) { features = new }
    public mutating func update(waypointStops new: [WaypointStop]) { waypointStops = new }

    public func lapPlan(lap: Int, seed: UInt64) -> LapPlan {
        var rng = SplitMix64(seed: seed &+ UInt64(truncatingIfNeeded: lap &+ 1) &* 0x9E37_79B9_7F4A_7C15)
        let length = path.length
        let cycle = cycleLength
        let profile = settings.profile
        var stops: [TripStop] = []
        var limits: [TripLimit] = []

        /// Where something at `d` metres along the route is met in a lap: once, or out and back.
        func passes(_ d: Double) -> [Double] {
            guard loopMode == .pingPong else { return [d] }
            let back = 2 * length - d
            return abs(back - d) < 1 ? [d] : [d, back]
        }
        func stop(_ at: Double, _ wait: TimeInterval, _ reason: TripStop.Reason) {
            stops.append(TripStop(distance: min(max(at, 0), cycle), wait: wait, reason: reason))
        }

        for feature in features.features {
            for at in passes(feature.distance) {
                switch feature.kind {
                case .trafficSignal:
                    guard settings.trafficLights else { continue }
                    if rng.chance(TripOdds.redLight(profile)) {
                        stop(at - TripOdds.stopLineOffset, TripOdds.redWait(&rng), .redLight)
                    }
                case .signalCrossing:
                    guard settings.trafficLights else { continue }
                    if rng.chance(profile.isOnFoot ? TripOdds.crossingRedOnFoot : TripOdds.crossingRedForTraffic) {
                        stop(at - 2, TripOdds.crossingWait(&rng), .crossing)
                    }
                case .stopSign:
                    guard settings.stopSigns else { continue }
                    switch profile.kind {
                    case .drive: stop(at - 2, TripOdds.stopSignWait(&rng), .stopSign)
                    case .cycle: limits.append(TripLimit(distance: at, speed: 2))
                    case .walk, .run: break
                    }
                case .giveWay:
                    guard settings.stopSigns, !profile.isOnFoot else { continue }
                    if profile.kind == .drive, rng.chance(TripOdds.giveWayStop) {
                        stop(at - 2, TripOdds.giveWayWait(&rng), .giveWay)
                    } else {
                        limits.append(TripLimit(distance: at, speed: TripOdds.giveWaySpeed))
                    }
                }
            }
        }

        for waypoint in waypointStops where waypoint.wait > 0 {
            var places = passes(waypoint.distance)
            if waypoint.distance < 0.5 {
                // The start: you've just left; the wait happens when the route comes back to it.
                switch loopMode {
                case .once: places = []
                case .loop: places = [length]
                case .pingPong: places = [cycle]
                }
            } else if loopMode == .once, waypoint.distance >= length - 0.5 {
                places = []   // the destination: the trip stays there anyway
            }
            for at in places { stop(at, waypoint.wait, .waypoint(waypoint.index)) }
        }

        switch loopMode {
        case .once:
            stop(length, .infinity, .destination)
        case .pingPong:
            if !stops.contains(where: { abs($0.distance - length) < 1 }) { stop(length, 0, .turnaround) }
        case .loop:
            break
        }

        if settings.slowForTurns {
            for limit in curveLimits {
                for at in passes(limit.distance) { limits.append(TripLimit(distance: at, speed: limit.speed)) }
            }
        }

        var zones: [SpeedZone] = []
        if settings.speedLimits, profile.kind == .drive {
            for zone in features.zones {
                zones.append(zone)
                if loopMode == .pingPong {
                    zones.append(SpeedZone(start: 2 * length - zone.end, end: 2 * length - zone.start, speed: zone.speed))
                }
            }
            zones.sort { $0.start < $1.start }
        }

        let driver = profile.kind == .drive ? Double.random(in: TripOdds.driverFactor, using: &rng) : 1
        return LapPlan(length: cycle, stops: Self.merged(stops.sorted { $0.distance < $1.distance }),
                       limits: limits.sorted { $0.distance < $1.distance }, zones: zones, driverFactor: driver)
    }

    /// Stops a few metres apart are one stop: the first place, the longest wait.
    static func merged(_ stops: [TripStop]) -> [TripStop] {
        var result: [TripStop] = []
        for stop in stops {
            if let last = result.last, stop.distance - last.distance < 3 {
                if stop.wait > last.wait {
                    result[result.count - 1].wait = stop.wait
                    result[result.count - 1].reason = stop.reason
                }
            } else {
                result.append(stop)
            }
        }
        return result
    }

    /// Average lap time over a few sampled laps (their lights differ), from a standing start.
    public func expectedLapTime(seed: UInt64 = 0x5EED, samples: Int = 8) -> TimeInterval {
        guard samples > 0, path.length > 0 else { return 0 }
        var total = 0.0
        for lap in 0..<samples {
            total += TripTiming.time(plan: lapPlan(lap: lap, seed: seed), from: 0, speed: 0,
                                     settings: settings, firstStop: 0)
        }
        return total / Double(samples)
    }

    /// The pace factor that makes the expected lap take `duration` seconds.
    public func fittedPaceFactor(for duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        var low = 0.02, high = 50.0
        var probe = self
        for _ in 0..<40 {
            let mid = (low * high).squareRoot()
            var s = settings
            s.paceFactor = mid
            probe.update(settings: s)
            if probe.expectedLapTime() > duration { low = mid } else { high = mid }
        }
        return (low * high).squareRoot()
    }
}
```

- [ ] **Step 5: Tests pass**; **Step 6: Commit** — "Trip planner and lap timing"

### Task 4: Trip controller

**Files:**
- Create: `Sources/SpooferCore/TripController.swift`
- Test: append to `Tests/SpooferCoreTests/TripTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `TripController(planner:seed:lap:lapDistance:speed:)`; `speed`, `status`,
  `planner`, `plan`; `update(settings:)`, `update(features:)`,
  `update(waypointStops:)`, `halt()`; `step(dt:lapDistance:lap:) -> Double`;
  `timeToLapEnd(from:) -> TimeInterval`.

- [ ] **Step 1: Failing tests**

```swift
final class TripControllerTests: XCTestCase {
    /// Drive a playback with the controller; returns (time, samples of (t, s, v, status)).
    private func drive(_ planner: TripPlanner, seed: UInt64 = 1, dt: Double = 0.5, until limit: Double = 3600,
                       stopWhen: (RoutePlayback, TripController) -> Bool) -> [(t: Double, s: Double, v: Double, status: TripStatus)] {
        var pb = RoutePlayback(path: planner.path, loopMode: planner.loopMode)
        var trip = TripController(planner: planner, seed: seed)
        var t = 0.0
        var log: [(t: Double, s: Double, v: Double, status: TripStatus)] = []
        while t < limit && !stopWhen(pb, trip) {
            pb.advance(by: trip.step(dt: dt, lapDistance: pb.lapDistance, lap: pb.lap))
            t += dt
            log.append((t, pb.travelled, trip.speed, trip.status))
        }
        return log
    }

    func testStopsAtAStopAndWaitsAndRespectsPhysics() {
        let path = TripPlannerTests.line(1000)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 15),
                                  waypointStops: [WaypointStop(index: 1, distance: 500, wait: 10)])
        let log = drive(planner) { pb, _ in pb.isFinished }
        // Never faster than the top speed; speed changes within the profile (plus rounding).
        var last = 0.0
        for entry in log {
            XCTAssertLessThanOrEqual(entry.v, 15 + 1e-9)
            XCTAssertLessThanOrEqual(entry.v - last, MotionProfile.drive.acceleration * 0.5 + 1e-9)
            last = entry.v
        }
        // It waited at 500 m with speed 0 for about 10 s.
        let stopped = log.filter { abs($0.s - 500) < 0.01 && $0.v == 0 }
        XCTAssertEqual(Double(stopped.count) * 0.5, 10, accuracy: 1.01)
        XCTAssertEqual(log.last?.s ?? 0, 1000, accuracy: 1e-6)
    }

    func testPredictionMatchesTheDrive() {
        let path = TripPlannerTests.line(5000)
        let lights = (1...12).map { RoadFeature(kind: .trafficSignal, distance: Double($0) * 400, point: GeoPoint(37, -122)) }
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 20),
                                  features: RoadFeatures(features: lights, zones: [SpeedZone(start: 1000, end: 3000, speed: 12)]))
        let predicted = TripController(planner: planner, seed: 5).timeToLapEnd(from: 0)
        let log = drive(planner, seed: 5, dt: 0.25) { pb, _ in pb.isFinished }
        XCTAssertEqual(log.last?.t ?? 0, predicted, accuracy: predicted * 0.03)
    }

    func testSeekResyncsAndHaltStopsDead() {
        let path = TripPlannerTests.line(2000)
        var trip = TripController(planner: TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 15)), seed: 1)
        _ = trip.step(dt: 0.5, lapDistance: 0, lap: 0)
        _ = trip.step(dt: 0.5, lapDistance: 1500, lap: 0)   // jumped ahead
        XCTAssertEqual(trip.status, .moving)
        trip.halt()
        XCTAssertEqual(trip.speed, 0)
    }

    func testLongDrivesTakeABreak() {
        let path = TripPlannerTests.line(400_000)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 30))
        let log = drive(planner, dt: 2, until: 4 * 3600) { _, trip in
            if case .stopped(.rest, _) = trip.status { return true }
            return false
        }
        XCTAssertGreaterThan(log.last?.t ?? 0, 1.7 * 3600)
        XCTAssertLessThan(log.last?.t ?? .infinity, 2.4 * 3600)
    }
}
```

- [ ] **Step 2: Run to see it fail.**

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Moves a trip along tick by tick: speeds up and brakes like `settings.profile`,
/// slows for curves and slower roads, stops and waits, and takes breaks.
/// `RoutePlayback` owns the position; the controller only says how far to go.
public struct TripController: Sendable {
    public private(set) var planner: TripPlanner
    public private(set) var plan: LapPlan
    public private(set) var lap: Int
    /// Current speed, m/s.
    public private(set) var speed: Double
    public private(set) var status: TripStatus = .moving

    private struct Waiting: Sendable { var reason: TripStop.Reason; var remaining: TimeInterval; var at: Double }

    private let seed: UInt64
    private var nextStop = 0
    private var waiting: Waiting?
    /// Where the next tick should find the playback; a jump means a seek.
    private var expected: Double?
    private var drivenSinceBreak: TimeInterval = 0
    private var breakDue: TimeInterval
    private var variation = 0.0
    private var rng: SplitMix64

    public init(planner: TripPlanner, seed: UInt64 = .random(in: 0 ... .max), lap: Int = 0,
                lapDistance: Double = 0, speed: Double = 0) {
        self.planner = planner
        self.seed = seed
        self.lap = lap
        self.speed = speed
        plan = planner.lapPlan(lap: lap, seed: seed)
        var rng = SplitMix64(seed: seed ^ 0xB4EA_C0DE_0000_0001)
        breakDue = TripOdds.breakInterval(&rng)
        self.rng = rng
        resync(to: lapDistance)
    }

    private var profile: MotionProfile { planner.settings.profile }

    // MARK: Changes while playing

    public mutating func update(settings: TripSettings) {
        guard settings != planner.settings else { return }
        let replan = settings.plansDiffer(from: planner.settings)
        planner.update(settings: settings)
        if replan { rebuildPlan() }
    }

    public mutating func update(features: RoadFeatures) {
        planner.update(features: features)
        rebuildPlan()
    }

    public mutating func update(waypointStops: [WaypointStop]) {
        planner.update(waypointStops: waypointStops)
        rebuildPlan()
    }

    /// Paused: the device stands still, so the next move starts from rest.
    public mutating func halt() { speed = 0 }

    private mutating func rebuildPlan() {
        plan = planner.lapPlan(lap: lap, seed: seed)
        resync(to: waiting.map { $0.at + 0.5 } ?? expected ?? 0)
    }

    private mutating func resync(to s: Double) {
        nextStop = plan.stops.firstIndex { $0.distance >= s - 0.5 } ?? plan.stops.count
        expected = s
    }

    // MARK: Ticks

    /// How far to move in this tick (metres), given where the playback is.
    public mutating func step(dt: TimeInterval, lapDistance s: Double, lap current: Int) -> Double {
        guard dt > 0, dt.isFinite else { return 0 }
        if current != lap {
            lap = current
            plan = planner.lapPlan(lap: lap, seed: seed)
            waiting = nil
            resync(to: s)
        } else if let expected, abs(s - expected) > 5 {
            waiting = nil
            resync(to: s)
            speed = min(speed, target(at: s))
        }

        if var wait = waiting {
            guard wait.remaining.isFinite else {
                speed = 0
                status = .stopped(wait.reason, remaining: nil)
                expected = s
                return 0
            }
            wait.remaining -= dt
            if wait.remaining > 0 {
                waiting = wait
                speed = 0
                status = .stopped(wait.reason, remaining: wait.remaining)
                expected = s
                return 0
            }
            waiting = nil
            nextStop = plan.stops.firstIndex { $0.distance > wait.at + 0.5 } ?? plan.stops.count
        }
        status = .moving
        scheduleBreakIfDue(at: s, dt: dt)

        let goal = target(at: s)
        var v = speed < goal ? min(goal, speed + profile.acceleration * dt)
                             : max(goal, speed - 1.6 * profile.braking * dt)
        var moved = (speed + v) / 2 * dt
        if nextStop < plan.stops.count {
            let stop = plan.stops[nextStop]
            if s + moved >= stop.distance - 0.05 {
                moved = max(0, stop.distance - s)
                v = 0
                if stop.wait > 0 {
                    waiting = Waiting(reason: stop.reason, remaining: stop.wait, at: stop.distance)
                    status = .stopped(stop.reason, remaining: stop.wait.isFinite ? stop.wait : nil)
                } else {
                    nextStop += 1
                }
            }
        }
        speed = v
        expected = s + moved
        return moved
    }

    /// The fastest speed now: the cruise speed, and still able to slow down in
    /// time for every stop, curve and slower road ahead.
    private mutating func target(at s: Double) -> Double {
        let settings = planner.settings
        let b = profile.braking
        if settings.speedVariation > 0 {
            variation = min(1, max(-1, variation * 0.92 + Double.random(in: -0.25...0.25, using: &rng)))
        }
        let cruise = plan.cruise(at: s, settings: settings)
        var goal = cruise * (1 + settings.speedVariation * variation)
        let fastest = max(goal, speed)
        let horizon = fastest * fastest / (2 * b) + 30

        var i = nextStop
        while i < plan.stops.count, plan.stops[i].distance - s <= horizon {
            goal = min(goal, (2 * b * max(0, plan.stops[i].distance - s)).squareRoot())
            i += 1
        }
        var j = plan.firstLimit(atOrAfter: s)
        while j < plan.limits.count, plan.limits[j].distance - s <= horizon {
            let limit = plan.limits[j]
            goal = min(goal, (limit.speed * limit.speed + 2 * b * (limit.distance - s)).squareRoot())
            j += 1
        }
        for zone in plan.zones where zone.start > s && zone.start - s <= horizon {
            let ahead = plan.cruise(at: zone.start + 0.01, settings: settings)
            if ahead < cruise { goal = min(goal, (ahead * ahead + 2 * b * (zone.start - s)).squareRoot()) }
        }
        return max(0, goal)
    }

    /// About every two hours of driving, a 10–20 minute break: at the next stop
    /// within 5 km if there is one, else by pulling over.
    private mutating func scheduleBreakIfDue(at s: Double, dt: TimeInterval) {
        guard planner.settings.breaks, profile.kind == .drive, speed > 0.5 else { return }
        drivenSinceBreak += dt
        guard drivenSinceBreak >= breakDue else { return }
        drivenSinceBreak = 0
        breakDue = TripOdds.breakInterval(&rng)
        let rest = TripOdds.breakLength(&rng)
        if nextStop < plan.stops.count, plan.stops[nextStop].distance - s <= 5000 {
            guard plan.stops[nextStop].wait.isFinite else { return }   // nearly there: no break
            plan.stops[nextStop].wait += rest
            plan.stops[nextStop].reason = .rest
        } else {
            let at = min(plan.length, s + speed * speed / (2 * profile.braking) + 25)
            plan.stops.insert(TripStop(distance: at, wait: rest, reason: .rest), at: nextStop)
        }
    }

    // MARK: Arrival time

    /// Seconds until the end of this lap (the destination, for a one-way route).
    public func timeToLapEnd(from s: Double) -> TimeInterval {
        var first = nextStop
        var extra = 0.0
        if let waiting {
            first = plan.stops.firstIndex { $0.distance > waiting.at + 0.5 } ?? plan.stops.count
            if waiting.remaining.isFinite { extra = waiting.remaining }
        }
        var total = TripTiming.time(plan: plan, from: s, speed: waiting == nil ? speed : 0,
                                    settings: planner.settings, firstStop: first) + extra
        if planner.settings.breaks, profile.kind == .drive {
            let upcoming = Int((drivenSinceBreak + total) / TripOdds.meanBreakInterval)
            total += Double(upcoming) * TripOdds.meanBreakLength
        }
        return total
    }
}
```

- [ ] **Step 4: Tests pass**; **Step 5: Commit** — "Trip controller: speeds, stops, breaks, arrival time"

### Task 5: GPS drift and the realistic timed track

**Files:**
- Create: `Sources/SpooferCore/GPSDrift.swift`
- Modify: `Sources/SpooferCore/RouteBuilder.swift` (add `timedTrack(path:loopMode:trip:drift:step:maxDuration:maxPoints:)`)
- Test: append to `Tests/SpooferCoreTests/TripTests.swift`

**Interfaces:**
- Produces: `GPSDrift(size:timeConstant:seed:)`, `step(dt:) -> (east: Double, north: Double)`,
  `apply(to:dt:) -> GeoPoint`; `RouteBuilder.timedTrack(path:loopMode:trip:drift:step:maxDuration:maxPoints:) throws -> [RoutePoint]`.

- [ ] **Step 1: Failing tests**

```swift
final class DriftAndTrackTests: XCTestCase {
    func testDriftSizeAndSlowChange() {
        var drift = GPSDrift(size: 5, timeConstant: 30, seed: 11)
        var radial: [Double] = []
        var previous = (east: 0.0, north: 0.0)
        var jumps: [Double] = []
        for i in 0..<40_000 {
            let now = drift.step(dt: 1)
            if i > 300 { radial.append(now.east * now.east + now.north * now.north) }
            jumps.append(hypot(now.east - previous.east, now.north - previous.north))
            previous = now
        }
        let rms = (radial.reduce(0, +) / Double(radial.count)).squareRoot()
        XCTAssertEqual(rms, 5, accuracy: 0.6)
        // One second moves it far less than its size: it wanders, it doesn't jump.
        XCTAssertLessThan(jumps.reduce(0, +) / Double(jumps.count), 1.5)
    }

    func testRealisticTrackHoldsAtStopsAndEnds() throws {
        let path = TripPlannerTests.line(800)
        let planner = TripPlanner(path: path, loopMode: .once, settings: TripSettings(topSpeed: 12),
                                  waypointStops: [WaypointStop(index: 1, distance: 400, wait: 30)])
        let track = try RouteBuilder.timedTrack(path: path, loopMode: .once,
                                                trip: TripController(planner: planner, seed: 1))
        XCTAssertGreaterThan(track.count, 10)
        XCTAssertEqual(zip(track, track.dropFirst()).allSatisfy { $0.offset < $1.offset }, true)
        // A gap of about 30 s at the same place, mid-route.
        let holds = zip(track, track.dropFirst()).filter {
            $0.latitude == $1.latitude && $0.longitude == $1.longitude && $1.offset - $0.offset >= 29
        }
        XCTAssertEqual(holds.count, 1)
        let end = path.end!
        XCTAssertEqual(GeoPoint(track.last!.latitude, track.last!.longitude).distance(to: end), 0, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run to see it fail.**

- [ ] **Step 3: Implement `GPSDrift.swift`**

```swift
import Foundation

/// Slowly wandering GPS error (a first-order Gauss–Markov process): each update
/// moves the error a little toward a new random value, so it drifts over tens of
/// seconds like a real receiver's instead of jumping every fix.
public struct GPSDrift: Sendable {
    /// Typical distance from the true position, metres (RMS).
    public var size: Double
    /// Seconds for the error to forget where it was.
    public var timeConstant: TimeInterval
    private var east = 0.0
    private var north = 0.0
    private var rng: SplitMix64

    public init(size: Double, timeConstant: TimeInterval = 30, seed: UInt64 = .random(in: 0 ... .max)) {
        self.size = size
        self.timeConstant = timeConstant
        rng = SplitMix64(seed: seed)
    }

    public mutating func step(dt: TimeInterval) -> (east: Double, north: Double) {
        guard size > 0, dt > 0, timeConstant > 0 else {
            east = 0
            north = 0
            return (0, 0)
        }
        let keep = exp(-dt / timeConstant)
        let fresh = size / 2.squareRoot() * (1 - keep * keep).squareRoot()
        east = keep * east + fresh * rng.gaussian()
        north = keep * north + fresh * rng.gaussian()
        return (east, north)
    }

    public mutating func apply(to point: GeoPoint, dt: TimeInterval) -> GeoPoint {
        let offset = step(dt: dt)
        let distance = hypot(offset.east, offset.north)
        guard distance > 0 else { return point }
        return point.moved(by: distance, bearing: atan2(offset.east, offset.north) * 180 / .pi)
    }
}
```

- [ ] **Step 4: Add to `RouteBuilder.swift`** (after `timedTrack(path:speed:...)`)

```swift
    /// A timed track that moves like `trip`: speeding up, braking and waiting at
    /// stops (a stop is the same point repeated over time, which pymobiledevice3 holds).
    public static func timedTrack(path: RoutePath, loopMode: LoopMode, trip: TripController,
                                  drift: GPSDrift? = nil, step: TimeInterval = 1,
                                  maxDuration: TimeInterval = 8 * 3600, maxPoints: Int = 40_000) throws -> [RoutePoint] {
        guard path.points.count >= 2 else { throw SpoofError("a route needs at least 2 points") }
        var playback = RoutePlayback(path: path, loopMode: loopMode)
        var trip = trip
        var drift = drift
        var points: [RoutePoint] = []
        var t = 0.0
        func point(_ dt: TimeInterval) -> GeoPoint {
            let p = playback.current.point
            return drift?.apply(to: p, dt: dt) ?? p
        }
        let first = point(step)
        points.append(RoutePoint(latitude: first.latitude, longitude: first.longitude, offset: 0))
        var holding = false
        while t < maxDuration && points.count < maxPoints {
            let moved = trip.step(dt: step, lapDistance: playback.lapDistance, lap: playback.lap)
            t += step
            playback.advance(by: moved)
            let p = point(step)
            let still = moved == 0 && drift == nil
            if still {
                holding = true
            } else {
                if holding, let last = points.last {
                    // End of a wait: the same place until a moment ago.
                    points.append(RoutePoint(latitude: last.latitude, longitude: last.longitude, offset: t - step))
                }
                holding = false
                points.append(RoutePoint(latitude: p.latitude, longitude: p.longitude, offset: t))
            }
            if case .stopped(.destination, _) = trip.status { break }
        }
        if holding, let last = points.last, last.offset < t {
            points.append(RoutePoint(latitude: last.latitude, longitude: last.longitude, offset: t))
        }
        return points
    }
```

- [ ] **Step 5: Tests pass**; **Step 6: Commit** — "GPS drift and a realistic timed track"

### Task 6: Matching map data to the route, and speed limits

**Files:**
- Create: `Sources/SpooferCore/RouteMatcher.swift`, `Sources/SpooferCore/SpeedLimits.swift`
- Test: `Tests/SpooferCoreTests/RoadDataTests.swift`

**Interfaces:**
- Produces: `RouteMatcher(path:)`, `passes(near:radius:) -> [(distance: Double, offset: Double)]`,
  `distances(ofWaypoints:) -> [Double]`; `OSMWay(id:points:tags:)`;
  `SpeedLimits.parse(maxspeed:) -> Double?`, `SpeedLimits.speed(tags:) -> Double?`,
  `SpeedLimits.zones(along:ways:spacing:) -> [SpeedZone]`.

- [ ] **Step 1: Failing tests**

```swift
import XCTest
@testable import SpooferCore

final class RoadDataTests: XCTestCase {
    let a = GeoPoint(37, -122)

    func testPassesFindsEachPassAndItsDistance() {
        // Out 1 km north and back: a point 3 m east of the 400 m mark is passed twice.
        let top = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, top, a])
        let matcher = RouteMatcher(path: path)
        let near = a.moved(by: 400, bearing: 0).moved(by: 3, bearing: 90)
        let passes = matcher.passes(near: near, radius: 10)
        XCTAssertEqual(passes.count, 2)
        XCTAssertEqual(passes[0].distance, 400, accuracy: 0.5)
        XCTAssertEqual(passes[1].distance, 1600, accuracy: 0.5)
        XCTAssertEqual(passes[0].offset, 3, accuracy: 0.2)
        XCTAssertTrue(matcher.passes(near: near.moved(by: 30, bearing: 90), radius: 10).isEmpty)
    }

    func testWaypointDistances() {
        let b = a.moved(by: 300, bearing: 0), c = b.moved(by: 500, bearing: 90)
        let path = RoutePath([a, a.moved(by: 150, bearing: 0), b, b.moved(by: 250, bearing: 90), c])
        XCTAssertEqual(RouteMatcher(path: path).distances(ofWaypoints: [a, b, c]).map { $0.rounded() }, [0, 300, 800])
    }

    func testMaxspeedParsing() {
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "50") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "30 mph") ?? 0, 30 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "DE:urban") ?? 0, 50 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "GB:nsl_dual") ?? 0, 70 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(SpeedLimits.parse(maxspeed: "none") ?? 0, 130 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.parse(maxspeed: "signals"))
        XCTAssertEqual(SpeedLimits.speed(tags: ["highway": "residential"]) ?? 0, 40 / 3.6, accuracy: 1e-9)
        XCTAssertNil(SpeedLimits.speed(tags: ["highway": "footway"]))
    }

    func testZonesFollowTheRoadsUnderTheRoute() {
        let mid = a.moved(by: 500, bearing: 0), end = a.moved(by: 1000, bearing: 0)
        let path = RoutePath([a, end])
        let ways = [
            OSMWay(id: 1, points: [a, mid], tags: ["highway": "primary", "maxspeed": "45 mph"]),
            OSMWay(id: 2, points: [mid, end], tags: ["highway": "residential"]),
            // A cross street at 500 m must not win.
            OSMWay(id: 3, points: [mid.moved(by: 100, bearing: 270), mid.moved(by: 100, bearing: 90)],
                   tags: ["highway": "motorway"]),
        ]
        let zones = SpeedLimits.zones(along: path, ways: ways)
        XCTAssertEqual(zones.count, 2)
        XCTAssertEqual(zones[0].speed, 45 * 0.44704, accuracy: 1e-9)
        XCTAssertEqual(zones[1].speed, 40 / 3.6, accuracy: 1e-9)
        XCTAssertEqual(zones[0].end, zones[1].start, accuracy: 1e-9)
        XCTAssertEqual(zones[1].start, 500, accuracy: 25)
    }
}
```

- [ ] **Step 2: Run to see it fail.**

- [ ] **Step 3: Implement `RouteMatcher.swift`**

```swift
import Foundation

/// Finds where points near a route are met along it, using a grid of the
/// route's segments so long routes stay fast.
public struct RouteMatcher: Sendable {
    public let path: RoutePath
    private let cell: Double
    private let grid: [Key: [Int]]

    private struct Key: Hashable, Sendable { let x: Int; let y: Int }

    public init(path: RoutePath, cellSize: Double = 0.001) {
        self.path = path
        cell = cellSize
        var grid: [Key: [Int]] = [:]
        let points = path.points
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                // Walk the segment in half-cell steps; long straight legs touch only their own cells.
                let a = points[i], b = points[i + 1]
                let steps = max(1, Int((max(abs(b.latitude - a.latitude), abs(b.longitude - a.longitude)) / (cellSize / 2)).rounded(.up)))
                var seen = Set<Key>()
                for k in 0...steps {
                    let t = Double(k) / Double(steps)
                    let key = Key(x: Int(floor((a.longitude + (b.longitude - a.longitude) * t) / cellSize)),
                                  y: Int(floor((a.latitude + (b.latitude - a.latitude) * t) / cellSize)))
                    if seen.insert(key).inserted { grid[key, default: []].append(i) }
                }
            }
        }
        self.grid = grid
    }

    /// Each pass of the route within `radius` metres of `point`: the distance along
    /// the route, and how far from it the point is.
    public func passes(near point: GeoPoint, radius: Double) -> [(distance: Double, offset: Double)] {
        let points = path.points
        guard points.count >= 2 else { return [] }
        let latSpan = radius / 111_000 + cell
        let lonSpan = radius / (111_000 * max(0.05, cos(Geo.radians(point.latitude)))) + cell
        var candidates = Set<Int>()
        for x in Int(floor((point.longitude - lonSpan) / cell))...Int(floor((point.longitude + lonSpan) / cell)) {
            for y in Int(floor((point.latitude - latSpan) / cell))...Int(floor((point.latitude + latSpan) / cell)) {
                candidates.formUnion(grid[Key(x: x, y: y)] ?? [])
            }
        }
        let k = Geo.earthRadius * .pi / 180
        let cosLat = cos(Geo.radians(point.latitude))
        func xy(_ p: GeoPoint) -> (x: Double, y: Double) {
            (Geo.normalizedLongitude(p.longitude - point.longitude) * k * cosLat, (p.latitude - point.latitude) * k)
        }
        var hits: [(distance: Double, offset: Double)] = []
        for i in candidates {
            let a = xy(points[i]), b = xy(points[i + 1])
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? max(0, min(1, -(a.x * dx + a.y * dy) / lengthSquared)) : 0
            let offset = hypot(a.x + t * dx, a.y + t * dy)
            guard offset <= radius else { continue }
            hits.append((path.cumulative[i] + t * (path.cumulative[i + 1] - path.cumulative[i]), offset))
        }
        hits.sort { $0.distance < $1.distance }
        // Neighbouring segments of one pass: keep the closest.
        var passes: [(distance: Double, offset: Double)] = []
        for hit in hits {
            if let last = passes.last, hit.distance - last.distance < 40 {
                if hit.offset < last.offset { passes[passes.count - 1] = hit }
            } else {
                passes.append(hit)
            }
        }
        return passes
    }

    /// How far along the route each waypoint is. The route runs through them in order.
    public func distances(ofWaypoints waypoints: [GeoPoint]) -> [Double] {
        var result: [Double] = []
        var from = 0
        for waypoint in waypoints {
            var found: Int?
            var i = from
            while i < path.points.count {
                if Geo.distance(path.points[i], waypoint) < 2 { found = i; break }
                i += 1
            }
            if let found {
                result.append(path.cumulative[found])
                from = found
            } else {
                let previous = result.last ?? 0
                let pass = passes(near: waypoint, radius: 200).first { $0.distance >= previous - 1 }
                result.append(pass?.distance ?? previous)
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Implement `SpeedLimits.swift`**

```swift
import Foundation

/// A road from OpenStreetMap: its shape and tags.
public struct OSMWay: Sendable, Equatable {
    public var id: Int64
    public var points: [GeoPoint]
    public var tags: [String: String]

    public init(id: Int64, points: [GeoPoint], tags: [String: String]) {
        self.id = id
        self.points = points
        self.tags = tags
    }
}

/// Road speed limits from OpenStreetMap tags.
public enum SpeedLimits {
    static let kmh = 1 / 3.6
    static let mph = 0.44704

    /// Usual limits by road type, km/h, when a road has no `maxspeed`.
    static let defaults: [String: Double] = [
        "motorway": 110, "motorway_link": 60, "trunk": 90, "trunk_link": 50,
        "primary": 70, "primary_link": 50, "secondary": 60, "secondary_link": 40,
        "tertiary": 50, "tertiary_link": 40, "unclassified": 50, "residential": 40,
        "living_street": 15, "service": 20, "road": 50,
    ]

    /// Zone codes (`DE:urban`, `GB:nsl_dual`…), m/s.
    static let zoneCodes: [String: Double] = [
        "urban": 50 * kmh, "rural": 90 * kmh, "motorway": 120 * kmh, "trunk": 100 * kmh,
        "living_street": 20 * kmh, "bicycle_road": 30 * kmh, "school": 30 * kmh, "zone30": 30 * kmh,
        "nsl_single": 60 * mph, "nsl_dual": 70 * mph, "nsl_restricted": 30 * mph,
    ]

    /// `maxspeed` in m/s: "50", "30 mph", "DE:urban", "none"; nil for "signals", "variable" or nonsense.
    public static func parse(maxspeed raw: String) -> Double? {
        let value = raw.split(separator: ";").first.map { String($0) }?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        switch value {
        case "none": return 130 * kmh
        case "walk": return 7 * kmh
        case "", "signals", "variable", "unknown": return nil
        default: break
        }
        if let colon = value.firstIndex(of: ":") {
            let code = String(value[value.index(after: colon)...])
            return zoneCodes[code] ?? (code.hasPrefix("zone") ? Double(code.dropFirst(4)).map { $0 * kmh } : nil)
        }
        let parts = value.split(separator: " ")
        guard let number = parts.first.flatMap({ Double($0) }), number > 0, number < 300 else { return nil }
        if parts.count > 1, parts[1].hasPrefix("mph") { return number * mph }
        if parts.count > 1, parts[1].hasPrefix("knots") { return number * 0.514444 }
        return number * kmh
    }

    /// A road's limit in m/s, or nil if it isn't a road for cars.
    public static func speed(tags: [String: String]) -> Double? {
        guard let highway = tags["highway"], let fallback = defaults[highway] else { return nil }
        return tags["maxspeed"].flatMap(parse(maxspeed:)) ?? fallback * kmh
    }

    /// Speed zones along `path`: every `spacing` metres, the limit of the road
    /// under the route (running the same way), merged into stretches.
    public static func zones(along path: RoutePath, ways: [OSMWay], spacing: Double = 20) -> [SpeedZone] {
        guard path.length > 0, !ways.isEmpty else { return [] }
        // Each road segment, as a tiny route of its own, indexed by a matcher.
        var segments: [(a: GeoPoint, b: GeoPoint, speed: Double)] = []
        for way in ways {
            guard let speed = speed(tags: way.tags), way.points.count >= 2 else { continue }
            for i in 0..<(way.points.count - 1) { segments.append((way.points[i], way.points[i + 1], speed)) }
        }
        guard !segments.isEmpty else { return [] }
        var grid: [Int64: [Int]] = [:]
        let cell = 0.0005
        func key(_ x: Int, _ y: Int) -> Int64 { Int64(x) << 32 | Int64(UInt32(bitPattern: Int32(truncatingIfNeeded: y))) }
        for (index, segment) in segments.enumerated() {
            let steps = max(1, Int((max(abs(segment.b.latitude - segment.a.latitude),
                                        abs(segment.b.longitude - segment.a.longitude)) / (cell / 2)).rounded(.up)))
            for k in 0...steps {
                let t = Double(k) / Double(steps)
                let lon = segment.a.longitude + (segment.b.longitude - segment.a.longitude) * t
                let lat = segment.a.latitude + (segment.b.latitude - segment.a.latitude) * t
                let id = key(Int(floor(lon / cell)), Int(floor(lat / cell)))
                if grid[id]?.last != index { grid[id, default: []].append(index) }
            }
        }

        let count = Int(path.length / spacing) + 1
        var speeds = [Double?](repeating: nil, count: count)
        let k = Geo.earthRadius * .pi / 180
        for n in 0..<count {
            let s = min(path.length, Double(n) * spacing)
            let sample = path.sample(at: s)
            let p = sample.point
            let cosLat = cos(Geo.radians(p.latitude))
            var best: (offset: Double, speed: Double)?
            var candidates = Set<Int>()
            let x = Int(floor(p.longitude / cell)), y = Int(floor(p.latitude / cell))
            for dx in -1...1 { for dy in -1...1 { candidates.formUnion(grid[key(x + dx, y + dy)] ?? []) } }
            for index in candidates {
                let segment = segments[index]
                let heading = Geo.bearing(from: segment.a, to: segment.b)
                let turn = abs(Geo.bearingDelta(from: sample.bearing, to: heading))
                guard turn < 35 || turn > 145 else { continue }   // same road, either direction
                func xy(_ q: GeoPoint) -> (x: Double, y: Double) {
                    (Geo.normalizedLongitude(q.longitude - p.longitude) * k * cosLat, (q.latitude - p.latitude) * k)
                }
                let a = xy(segment.a), b = xy(segment.b)
                let ex = b.x - a.x, ey = b.y - a.y
                let lengthSquared = ex * ex + ey * ey
                let t = lengthSquared > 0 ? max(0, min(1, -(a.x * ex + a.y * ey) / lengthSquared)) : 0
                let offset = hypot(a.x + t * ex, a.y + t * ey)
                guard offset <= 12 else { continue }
                if best == nil || offset < best!.offset { best = (offset, segment.speed) }
            }
            speeds[n] = best?.speed
        }
        // Short gaps (intersections, small mapping gaps) take the speed before them.
        var last: Double?
        var gap = 0
        for n in 0..<count {
            if let speed = speeds[n] { last = speed; gap = 0 } else if let last, gap < 10 { speeds[n] = last; gap += 1 }
        }
        var zones: [SpeedZone] = []
        for n in 0..<count {
            guard let speed = speeds[n] else { continue }
            let start = Double(n) * spacing, end = min(path.length, start + spacing)
            if let previous = zones.last, previous.speed == speed, abs(previous.end - start) < 1e-6 {
                zones[zones.count - 1].end = end
            } else {
                zones.append(SpeedZone(start: start, end: end, speed: speed))
            }
        }
        // Drop slivers shorter than 60 m into the zone before them.
        var merged: [SpeedZone] = []
        for zone in zones {
            if zone.end - zone.start < 60, let previous = merged.last, abs(previous.end - zone.start) < 1e-6 {
                merged[merged.count - 1].end = zone.end
            } else {
                merged.append(zone)
            }
        }
        return merged
    }
}
```

- [ ] **Step 5: Tests pass**; **Step 6: Commit** — "Match map data to routes; speed limits from OSM tags"

### Task 7: Overpass loader

**Files:**
- Create: `Sources/SpooferCore/OverpassLoader.swift`, `Tests/SpooferCoreTests/Fixtures/overpass-sample.json`
- Modify: `Package.swift` (test resources: `resources: [.copy("Fixtures")]` on SpooferCoreTests)
- Test: append to `RoadDataTests.swift`

**Interfaces:**
- Consumes: `RouteMatcher`, `SpeedLimits`, `OSMWay`, `RouteSimplifier`, `RoadFeatures`.
- Produces: `OSMNode`, `OverpassAnswer`, `OverpassLoader(userAgent:cacheDirectory:transport:)`,
  `OverpassLoader.query(for:padding:roads:) -> String`, `OverpassLoader.parse(_:) throws -> OverpassAnswer`,
  `features(along:roads:progress:) async throws -> RoadFeatures`,
  `static func features(from:along:) -> RoadFeatures`.

- [ ] **Step 1: Save the fixture** (`overpass-sample.json`): a JSON answer with one
  `highway=traffic_signals` node on the route, one 3 m off it, a `highway=stop`
  node 4 m off, a `highway=stop` 20 m off (must be ignored), a crossing with
  `crossing=traffic_signals`, and two ways (primary with `maxspeed=35 mph`,
  residential) along a 1 km north-going path starting at 37.0, -122.0. Coordinates
  are computed with `GeoPoint.moved` in the test, so the fixture only holds
  offsets; see Step 2's test, which builds the JSON itself to stay exact.

- [ ] **Step 2: Failing tests**

```swift
extension RoadDataTests {
    private func answerJSON(path: RoutePath) -> Data {
        let at = { (d: Double, east: Double) -> GeoPoint in path.sample(at: d).point.moved(by: east, bearing: 90) }
        func node(_ id: Int, _ p: GeoPoint, _ tags: [String: String]) -> [String: Any] {
            ["type": "node", "id": id, "lat": p.latitude, "lon": p.longitude, "tags": tags]
        }
        func way(_ id: Int, _ points: [GeoPoint], _ tags: [String: String]) -> [String: Any] {
            ["type": "way", "id": id, "tags": tags, "geometry": points.map { ["lat": $0.latitude, "lon": $0.longitude] }]
        }
        let elements: [[String: Any]] = [
            node(1, at(200, 0), ["highway": "traffic_signals"]),
            node(2, at(215, 3), ["highway": "traffic_signals"]),            // same junction: merged
            node(3, at(500, 4), ["highway": "stop"]),
            node(4, at(700, 20), ["highway": "stop"]),                       // on a side street: ignored
            node(5, at(850, 2), ["highway": "crossing", "crossing": "traffic_signals"]),
            node(6, at(950, 0), ["highway": "traffic_signals", "traffic_signals": "emergency"]),  // not for us
            way(10, [at(0, 0), at(600, 0)], ["highway": "primary", "maxspeed": "35 mph"]),
            way(11, [at(600, 0), at(1000, 0)], ["highway": "residential"]),
        ]
        return try! JSONSerialization.data(withJSONObject: ["version": 0.6, "elements": elements])
    }

    func testParseAndMatchAnOverpassAnswer() throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let answer = try OverpassLoader.parse(answerJSON(path: path))
        XCTAssertEqual(answer.nodes.count, 6)
        XCTAssertEqual(answer.ways.count, 2)
        let features = OverpassLoader.features(from: answer, along: path)
        XCTAssertEqual(features.features.filter { $0.kind == .trafficSignal }.map { $0.distance.rounded() }, [200])
        XCTAssertEqual(features.features.filter { $0.kind == .stopSign }.count, 1)
        XCTAssertEqual(features.features.filter { $0.kind == .signalCrossing }.count, 1)
        XCTAssertEqual(features.zones.first?.speed ?? 0, 35 * 0.44704, accuracy: 1e-9)
        XCTAssertGreaterThan(features.speedLimitCoverage(of: path.length), 0.9)
    }

    func testQueryLooksRight() {
        let q = OverpassLoader.query(for: [a, a.moved(by: 100, bearing: 0)], padding: 3, roads: true)
        XCTAssertTrue(q.hasPrefix("[out:json][timeout:25];"))
        XCTAssertTrue(q.contains("node(around:21,37.000000,-122.000000,"))
        XCTAssertTrue(q.contains("[highway=traffic_signals]"))
        XCTAssertTrue(q.contains("way(around:9,"))
        XCTAssertTrue(q.hasSuffix("out geom;"))
        XCTAssertFalse(OverpassLoader.query(for: [a, a.moved(by: 100, bearing: 0)], padding: 3, roads: false).contains("way("))
    }

    func testLoaderFetchesCachesAndFallsBack() async throws {
        let path = RoutePath([a, a.moved(by: 1000, bearing: 0)])
        let body = answerJSON(path: path)
        let calls = Counter()
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: cache) { request in
            let n = await calls.increment()
            let status = n == 1 ? 504 : 200        // the first server is busy
            return (status == 200 ? body : Data(), HTTPURLResponse(url: request.url!, statusCode: status,
                                                                   httpVersion: nil, headerFields: nil)!)
        }
        let first = try await loader.features(along: path, roads: true)
        XCTAssertEqual(first.uniqueCount(of: .trafficSignal), 1)
        let callsBefore = await calls.value
        _ = try await loader.features(along: path, roads: true)       // from the cache
        let callsAfter = await calls.value
        XCTAssertEqual(callsBefore, callsAfter)
    }
}

actor Counter {
    private(set) var value = 0
    func increment() -> Int { value += 1; return value }
}
```

- [ ] **Step 3: Run to see it fail.**

- [ ] **Step 4: Implement `OverpassLoader.swift`**

```swift
import Foundation

/// A point from OpenStreetMap with its tags.
public struct OSMNode: Sendable, Equatable {
    public var id: Int64
    public var point: GeoPoint
    public var tags: [String: String]
}

public struct OverpassAnswer: Sendable, Equatable {
    public var nodes: [OSMNode]
    public var ways: [OSMWay]
}

/// Loads traffic lights, stop and yield signs, signal crossings and speed limits
/// near a route from OpenStreetMap's public Overpass API: in pieces of about
/// 15 km, one request at a time, cached on disk for 30 days.
public struct OverpassLoader: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let endpoints = [
        URL(string: "https://overpass-api.de/api/interpreter")!,
        URL(string: "https://overpass.private.coffee/api/interpreter")!,
    ]

    let userAgent: String
    let cacheDirectory: URL?
    let transport: Transport

    public init(userAgent: String, cacheDirectory: URL?,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.userAgent = userAgent
        self.cacheDirectory = cacheDirectory
        self.transport = transport
    }

    /// Search radii in metres around the route.
    static let signalRadius = 18.0, signRadius = 6.0, crossingRadius = 12.0, roadRadius = 6.0

    public func features(along path: RoutePath, roads: Bool,
                         progress: (@Sendable (Double) -> Void)? = nil) async throws -> RoadFeatures {
        let chunks = Self.chunks(of: path)
        var nodes: [Int64: OSMNode] = [:]
        var ways: [Int64: OSMWay] = [:]
        var failures = 0
        var lastError: Error?
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            do {
                let answer = try await fetch(Self.query(for: chunk.points, padding: chunk.padding, roads: roads))
                for node in answer.nodes { nodes[node.id] = node }
                for way in answer.ways { ways[way.id] = way }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                lastError = error
            }
            progress?(Double(index + 1) / Double(chunks.count))
        }
        if failures == chunks.count, let lastError { throw lastError }
        var features = Self.features(from: OverpassAnswer(nodes: Array(nodes.values), ways: Array(ways.values)), along: path)
        features.complete = failures == 0
        return features
    }

    // MARK: Building and reading queries

    /// Pieces of at most 15 km, simplified to ≤ 150 points; `padding` covers the simplification.
    static func chunks(of path: RoutePath) -> [(points: [GeoPoint], padding: Double)] {
        guard path.points.count >= 2 else { return [] }
        var chunks: [(points: [GeoPoint], padding: Double)] = []
        var start = 0
        while start < path.points.count - 1 {
            var end = start + 1
            while end < path.points.count - 1, path.cumulative[end] - path.cumulative[start] < 15_000 { end += 1 }
            let piece = Array(path.points[start...end])
            var tolerance = 2.0
            var simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            while simple.count > 150 && tolerance < 200 {
                tolerance *= 1.6
                simple = RouteSimplifier.simplify(piece, tolerance: tolerance)
            }
            chunks.append((simple, tolerance))
            start = end
        }
        return chunks
    }

    static func query(for points: [GeoPoint], padding: Double, roads: Bool) -> String {
        let line = points.map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ",")
        func r(_ base: Double) -> Int { Int((base + padding).rounded(.up)) }
        var parts = [
            "node(around:\(r(signalRadius)),\(line))[highway=traffic_signals];",
            "node(around:\(r(signRadius)),\(line))[highway~\"^(stop|give_way)$\"];",
            "node(around:\(r(crossingRadius)),\(line))[highway=crossing][crossing=traffic_signals];",
        ]
        if roads {
            parts.append("way(around:\(r(roadRadius)),\(line))[highway~\"^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|service|road)(_link)?$\"];")
        }
        return "[out:json][timeout:25];(" + parts.joined() + ");out geom;"
    }

    public static func parse(_ data: Data) throws -> OverpassAnswer {
        struct Element: Decodable {
            struct LatLon: Decodable { let lat: Double; let lon: Double }
            let type: String
            let id: Int64
            let lat: Double?
            let lon: Double?
            let tags: [String: String]?
            let geometry: [LatLon?]?
        }
        struct Answer: Decodable { let elements: [Element]; let remark: String? }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        if let remark = answer.remark, remark.lowercased().contains("error") {
            throw SpoofError("OpenStreetMap couldn't answer: \(remark)")
        }
        var nodes: [OSMNode] = []
        var ways: [OSMWay] = []
        for element in answer.elements {
            switch element.type {
            case "node":
                guard let lat = element.lat, let lon = element.lon else { continue }
                nodes.append(OSMNode(id: element.id, point: GeoPoint(lat, lon), tags: element.tags ?? [:]))
            case "way":
                let points = (element.geometry ?? []).compactMap { $0.map { GeoPoint($0.lat, $0.lon) } }
                guard points.count >= 2 else { continue }
                ways.append(OSMWay(id: element.id, points: points, tags: element.tags ?? [:]))
            default:
                continue
            }
        }
        return OverpassAnswer(nodes: nodes, ways: ways)
    }

    /// Places the answer's nodes along `path` and turns its roads into speed zones.
    public static func features(from answer: OverpassAnswer, along path: RoutePath) -> RoadFeatures {
        let matcher = RouteMatcher(path: path)
        var features: [RoadFeature] = []
        for node in answer.nodes.sorted(by: { $0.id < $1.id }) {
            let highway = node.tags["highway"]
            let kind: RoadFeature.Kind
            let radius: Double
            switch highway {
            case "traffic_signals":
                guard !["emergency", "blinker", "ramp_meter"].contains(node.tags["traffic_signals"] ?? "") else { continue }
                (kind, radius) = (.trafficSignal, signalRadius)
            case "stop": (kind, radius) = (.stopSign, signRadius)
            case "give_way": (kind, radius) = (.giveWay, signRadius)
            case "crossing": (kind, radius) = (.signalCrossing, crossingRadius)
            default: continue
            }
            for pass in matcher.passes(near: node.point, radius: radius) {
                features.append(RoadFeature(kind: kind, distance: pass.distance, point: node.point))
            }
        }
        // One junction often has a light on each approach: keep one per 30 m (signs: 15 m).
        features.sort { $0.distance < $1.distance }
        var kept: [RoadFeature] = []
        for feature in features {
            let gap: Double = feature.kind == .trafficSignal || feature.kind == .signalCrossing ? 30 : 15
            if let previous = kept.last(where: { $0.kind == feature.kind }), feature.distance - previous.distance < gap { continue }
            kept.append(feature)
        }
        return RoadFeatures(features: kept, zones: SpeedLimits.zones(along: path, ways: answer.ways))
    }

    // MARK: Fetching

    private func fetch(_ query: String) async throws -> OverpassAnswer {
        let cacheFile = cacheDirectory?.appendingPathComponent(Self.cacheName(for: query))
        if let cacheFile, let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attributes[.modificationDate] as? Date, Date().timeIntervalSince(modified) < 30 * 86_400,
           let data = try? Data(contentsOf: cacheFile), let answer = try? Self.parse(data) {
            return answer
        }
        var lastError: Error = SpoofError("couldn't reach OpenStreetMap")
        for (index, endpoint) in Self.endpoints.enumerated() {
            if index > 0 { try await Task.sleep(for: .seconds(1)) }
            var request = URLRequest(url: endpoint, timeoutInterval: 40)
            request.httpMethod = "POST"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
            request.httpBody = Data("data=\(encoded)".utf8)
            do {
                let (data, response) = try await transport(request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    lastError = SpoofError("OpenStreetMap answered \(status)")
                    continue
                }
                let answer = try Self.parse(data)
                if let cacheFile {
                    try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(),
                                                             withIntermediateDirectories: true)
                    try? data.write(to: cacheFile)
                }
                return answer
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// FNV-1a: a stable file name for a query.
    static func cacheName(for query: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in query.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0100_0000_01B3 }
        return String(format: "%016llx.json", hash)
    }
}
```

- [ ] **Step 5: Tests pass**; **Step 6: Commit** — "Load traffic lights, signs and speed limits from OpenStreetMap"

### Task 8: App state, settings and saved waits

**Files:**
- Modify: `Sources/iosgpsspoofer-gui/Preferences.swift` — keys and properties
  `realisticTrips`, `tripTrafficLights`, `tripStopSigns`, `tripSlowForTurns`,
  `tripSpeedLimits`, `tripBreaks` (all default true; reset in `resetAll`).
- Modify: `Sources/iosgpsspoofer-gui/AppModel.swift` — `Waypoint.wait`
  (Codable-compatible), `RouteDraft.waits: [Double]?`, restore/save waits;
  stored state: `roadFeatures`, `roadDataState`, `roadDataPathKey`,
  `roadDataTask`, `trip`, `tripStatus`, `drift`, `joystickSpeedNow`,
  `joystickHeadingNow`, `lapTimeCache`.
- Modify: `Sources/SpooferCore/Library.swift` — `SavedRoute.waits: [Double]?` (lenient decode).
- Modify: `Sources/iosgpsspoofer-gui/AppModel+Library.swift` — save/load waits.
- Create: `Sources/iosgpsspoofer-gui/AppModel+Trip.swift`:

```swift
import Foundation
import SpooferCore

/// Realistic trips: the map data along the route, the trip planner, and your stop waits.
extension AppModel {
    enum RoadDataState: Equatable {
        case off, needsRoads, loading(Double), ready, failed(String)
    }

    static let roadDataLoader = OverpassLoader(
        userAgent: "iOS-GPS-Spoofer/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (+https://github.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1)",
        cacheDirectory: AppSupport.directory.appendingPathComponent("osm-cache", isDirectory: true))

    /// The path a route plays, as the planner sees it (closed for loops).
    var playPath: RoutePath { RoutePlayback(path: routePath, loopMode: loopMode).path }

    var tripSettings: TripSettings { ... builds from prefs + routeSpeed / pacing ... }

    func makeTripPlanner(path: RoutePath, loopMode: LoopMode) -> TripPlanner { ... }

    func waypointStops(along path: RoutePath) -> [WaypointStop] { ... RouteMatcher distances + waits ... }

    func refreshRoadData() { ... cancel, decide state, debounce 600 ms, load, update trip ... }

    func setWait(_ seconds: TimeInterval, forWaypoint id: UUID) { ... }

    var expectedLapTime: TimeInterval? { ... cached by key ... }
}
```

(Full code in the commit; the shape above is the contract the UI uses.)

- [ ] Steps: build; `swift test` (all pass); restore a draft saved by the previous
  build (no `waits` key) and check it loads; commit "App state for realistic trips".

### Task 9: Motion loop

**Files:** `Sources/iosgpsspoofer-gui/AppModel+Motion.swift`, `AppModel+Route.swift`

- `routeTick`: when `prefs.realisticTrips` and `trip != nil`: `trip.update(settings:)`,
  `distance = trip.step(dt:lapDistance:lap:)`, `deviceSpeed = trip.speed`,
  `tripStatus = trip.status` (only on change); otherwise the old constant speed.
  Position: `drift.apply(to:dt:)` when `positionJitter > 0` (replaces `jittered`).
- Pause: `trip?.halt()`.
- `startRoute` (live): `trip = prefs.realisticTrips ? TripController(planner: makeTripPlanner(...)) : nil`;
  classic engine: `RouteBuilder.timedTrack(path:loopMode:trip:drift:)` when realistic.
- `applyRouteChanges`: a new controller at the playback's lap and distance, keeping the speed.
- `routeProgress.eta`: `trip?.timeToLapEnd(from: pb.lapDistance)` when realistic.
- `routePassDuration`: `expectedLapTime` when realistic.
- Joystick: ease `joystickSpeedNow` toward the target with the profile's
  acceleration/braking; keep moving along the last heading while slowing.
- Verify with the debug snapshot (`SPOOFER_DEMO=route-roads`): `SNAPSHOT-STATS`
  shows speeds that rise and fall and a `trip=` status; commit "Realistic trips
  in the motion loop".

### Task 10: UI

**Files:** `InspectorView.swift`, `SettingsView.swift`, `HUDView.swift`,
`MapPicker.swift`, `MainView.swift`, `DebugSnapshot.swift`

- Inspector: a "Drive like a real person" card under Follow roads, with the
  data status line (counts / loading / failed + Try Again / needs Follow roads).
- Stop rows: a wait menu (No wait, 30 s, 1, 2, 5, 10, 30 min) and a "Waits 5 min" line.
- Settings ▸ Movement: "Realistic trips" switches.
- HUD: while stopped, the Speed tile shows the reason and time left.
- Map: traffic-light, stop-sign, yield and crosswalk markers (custom-drawn
  traffic light; red octagon; triangle) with low display priority.
- Snapshot stats include `trip=<status> speed=<m/s> lights=<n>`.
- Verify: screenshots at 1040×692 and 1440×900 of a red-light stop and of the
  markers; commit "Realistic trips: route card, stop waits, HUD status, map markers".

### Task 11: Command line

**Files:** `Sources/iosgpsspoof/Commands.swift`

- `--realistic`: build a `TripController` (no map data for straight waypoint
  legs; map data for a GPX/KML track via `OverpassLoader`, blocking with a
  semaphore) and `RouteBuilder.timedTrack(path:loopMode:trip:)`.
- Verify `iosgpsspoof route 37.3349,-122.009 37.3318,-122.0312 --speed 50 --realistic`
  with the pretend iPhone; commit "route --realistic".

### Task 12: Docs, CI, release

- README "Use it": one paragraph on realistic trips and stop waits.
- DEVELOPERS.md: the trip planner, OpenStreetMap use (and its etiquette), snapshot keys.
- CI screenshot of a red-light stop.
- Push to `staging`, CI green, fast-forward `main`.
