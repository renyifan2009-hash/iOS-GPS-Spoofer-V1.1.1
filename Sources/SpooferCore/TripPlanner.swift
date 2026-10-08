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

    /// Cruise speed at `s`: the road's limit (times the driver's habit) or the
    /// top speed, whichever is lower.
    public func cruise(at s: Double, settings: TripSettings) -> Double {
        let top = settings.topSpeed * settings.paceFactor
        guard let index = zoneIndex(at: s) else { return max(0.1, top) }
        return max(0.1, min(top, zones[index].speed * driverFactor * settings.paceFactor))
    }

    public func zoneIndex(at s: Double) -> Int? {
        var lo = 0, hi = zones.count - 1
        var found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if zones[mid].start <= s { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard let found, s < zones[found].end else { return nil }
        return found
    }

    /// Index of the first limit at or after `s` (`limits.count` if none).
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

    /// Length of one lap: the route, or out and back.
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
        let pingPong = loopMode == .pingPong
        var stops: [TripStop] = []
        var limits: [TripLimit] = []

        /// Where something `d` metres along the route is met in a lap: once, or
        /// out and back. A sign for one direction only counts on that leg.
        func passes(_ d: Double, facing: RoadFeature.Facing = .both) -> [Double] {
            var places: [Double] = []
            if facing != .backward { places.append(d) }
            let back = 2 * length - d
            if pingPong, facing != .forward, abs(back - d) >= 1 || places.isEmpty { places.append(back) }
            return places
        }
        // A stop exactly at the end of a lap would be skipped: the playback
        // starts the next lap as it gets there. Keep them just before it.
        let lastSpot = loopMode == .once ? cycle : max(0, cycle - 0.5)
        func clamp(_ at: Double) -> Double { min(max(at, 0), lastSpot) }

        /// A traffic light whose stop line is `line` metres into the lap.
        func light(at line: Double) {
            switch TripOdds.light(profile, &rng) {
            case .green:
                break
            case .turnsGreen(let speed):
                limits.append(TripLimit(distance: clamp(line), speed: speed))
            case .red(let wait, let queue):
                stops.append(TripStop(distance: clamp(line - Double(queue) * TripOdds.queueSpacing),
                                      wait: wait, reason: .redLight))
            }
        }

        for feature in features.features {
            for at in passes(feature.distance, facing: feature.facing) {
                switch feature.kind {
                case .trafficSignal:
                    guard settings.trafficLights else { continue }
                    light(at: at - TripOdds.stopLineOffset)
                case .signalCrossing:
                    guard settings.trafficLights else { continue }
                    if profile.isOnFoot {
                        light(at: at - 2)
                    } else if rng.chance(TripOdds.crossingRedForTraffic) {
                        stops.append(TripStop(distance: clamp(at - 2), wait: TripOdds.crossingWait(&rng),
                                              reason: .crossing))
                    }
                case .stopSign:
                    guard settings.stopSigns else { continue }
                    switch profile.kind {
                    case .drive where rng.chance(TripOdds.fullStopAtSign):
                        stops.append(TripStop(distance: clamp(at - 2), wait: TripOdds.stopSignWait(&rng),
                                              reason: .stopSign))
                    case .drive:
                        limits.append(TripLimit(distance: clamp(at - 2), speed: TripOdds.rollingStopSpeed(&rng)))
                    case .cycle:
                        limits.append(TripLimit(distance: at, speed: 2))
                    case .walk, .run:
                        break
                    }
                case .giveWay:
                    guard settings.stopSigns, !profile.isOnFoot else { continue }
                    if profile.kind == .drive, rng.chance(TripOdds.giveWayStop) {
                        stops.append(TripStop(distance: clamp(at - 2), wait: TripOdds.giveWayWait(&rng),
                                              reason: .giveWay))
                    } else {
                        limits.append(TripLimit(distance: at, speed: TripOdds.giveWaySpeed))
                    }
                case .trafficCalming:
                    guard settings.slowForTurns, profile.kind == .drive, let speed = feature.speed else { continue }
                    limits.append(TripLimit(distance: at, speed: speed))
                }
            }
        }

        // No map data: sharp turns on a road route are nearly always junctions.
        if settings.guessJunctions, features.features.isEmpty, settings.trafficLights, profile.kind == .drive {
            for turn in curveLimits where turn.speed < TripOdds.junctionTurnSpeed {
                for at in passes(turn.distance) where rng.chance(TripOdds.junctionHasLight) {
                    light(at: at - 12)
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
            for at in places {
                stops.append(TripStop(distance: clamp(at), wait: waypoint.wait, reason: .waypoint(waypoint.index)))
            }
        }

        switch loopMode {
        case .once:
            stops.append(TripStop(distance: length, wait: .infinity, reason: .destination))
        case .pingPong:
            // A U-turn at each end: out at the far end, and back at the start.
            for end in [length, lastSpot] where !stops.contains(where: { abs($0.distance - end) < 1 }) {
                stops.append(TripStop(distance: end, wait: 0, reason: .turnaround))
            }
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
                if pingPong {
                    zones.append(SpeedZone(start: 2 * length - zone.end, end: 2 * length - zone.start,
                                           speed: zone.speed))
                }
            }
            zones.sort { $0.start < $1.start }
        }

        let driver = profile.kind == .drive ? Double.random(in: TripOdds.driverFactor, using: &rng) : 1
        return LapPlan(length: cycle, stops: Self.merged(stops.sorted { $0.distance < $1.distance }),
                       limits: limits.sorted { $0.distance < $1.distance }, zones: zones, driverFactor: driver)
    }

    /// Stops a few metres apart are one stop: the first place, the longest wait.
    /// The destination and a turnaround keep their own place, so a sign just
    /// before the end can't leave the trip waiting short of it.
    static func merged(_ stops: [TripStop]) -> [TripStop] {
        func isEnd(_ stop: TripStop) -> Bool { stop.reason == .destination || stop.reason == .turnaround }
        var result: [TripStop] = []
        for stop in stops {
            guard let last = result.last, stop.distance - last.distance < 3 else {
                result.append(stop)
                continue
            }
            let wait = max(last.wait, stop.wait)
            if isEnd(stop) {
                result[result.count - 1] = TripStop(distance: stop.distance, wait: wait, reason: stop.reason)
            } else if isEnd(last) {
                result[result.count - 1].wait = wait
            } else if stop.wait > last.wait {
                result[result.count - 1].wait = stop.wait
                result[result.count - 1].reason = stop.reason
            }
        }
        return result
    }

    /// Average lap time over a few sampled laps (their lights differ), from a
    /// standing start, with the breaks or pauses expected along the way.
    public func expectedLapTime(seed: UInt64 = 0x5EED, samples: Int = 8) -> TimeInterval {
        guard samples > 0, path.length > 0 else { return 0 }
        var total = 0.0
        for lap in 0..<samples {
            total += TripTiming.time(plan: lapPlan(lap: lap, seed: seed), from: 0, speed: 0,
                                     settings: settings, firstStop: 0)
        }
        return Self.withBreaks(total / Double(samples), settings: settings)
    }

    /// `time` plus the breaks (driving) or pauses (on foot) expected in it.
    static func withBreaks(_ time: TimeInterval, settings: TripSettings, alreadyMoving: TimeInterval = 0) -> TimeInterval {
        guard settings.breaks else { return time }
        let profile = settings.profile
        if profile.kind == .drive {
            return time + Double(Int((alreadyMoving + time) / TripOdds.meanBreakInterval)) * TripOdds.meanBreakLength
        }
        if profile.isOnFoot {
            return time + Double(Int((alreadyMoving + time) / TripOdds.meanPauseInterval)) * TripOdds.meanPauseLength
        }
        return time
    }

    /// The pace factor (0.05–4) that makes the expected lap take `duration`
    /// seconds, or as close as that range gets (waits can't be hurried).
    public func fittedPaceFactor(for duration: TimeInterval) -> Double {
        guard duration > 0, path.length > 0 else { return 1 }
        var low = 0.05, high = 4.0
        var probe = self
        func time(_ factor: Double) -> TimeInterval {
            var trial = settings
            trial.paceFactor = factor
            probe.update(settings: trial)
            return probe.expectedLapTime(samples: 4)
        }
        if time(high) > duration { return high }
        if time(low) < duration { return low }
        for _ in 0..<26 {
            let mid = (low * high).squareRoot()
            if time(mid) > duration { low = mid } else { high = mid }
        }
        return (low * high).squareRoot()
    }
}
