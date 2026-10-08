import Foundation

/// Moves a trip along tick by tick: speeds up and brakes like the profile,
/// slows for curves and slower roads, stops and waits, and takes breaks.
/// `RoutePlayback` owns the position; the controller only says how far to go.
public struct TripController: Sendable {
    public private(set) var planner: TripPlanner
    public private(set) var plan: LapPlan
    public private(set) var lap: Int
    /// Current speed, m/s.
    public private(set) var speed: Double
    public private(set) var status: TripStatus = .moving

    private struct Waiting: Sendable {
        var reason: TripStop.Reason
        var remaining: TimeInterval
        var at: Double
    }

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
        breakDue = planner.settings.profile.isOnFoot ? TripOdds.pauseInterval(&rng) : TripOdds.breakInterval(&rng)
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
        if waiting != nil { expected = waiting?.at }
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
            // A seek, or the route changed underneath.
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

    /// The fastest speed now: the cruise speed, while still able to slow down in
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
    /// within 5 km if there is one, else by pulling over. On foot, a short pause
    /// every few minutes.
    private mutating func scheduleBreakIfDue(at s: Double, dt: TimeInterval) {
        guard planner.settings.breaks, profile.kind != .cycle, speed > 0.3 else { return }
        drivenSinceBreak += dt
        guard drivenSinceBreak >= breakDue else { return }
        if profile.isOnFoot {
            drivenSinceBreak = 0
            breakDue = TripOdds.pauseInterval(&rng)
            let at = min(plan.length - 1, s + speed * speed / (2 * profile.braking) + 1)
            guard at > s, nextStop >= plan.stops.count || plan.stops[nextStop].distance > at + 3 else { return }
            plan.stops.insert(TripStop(distance: at, wait: TripOdds.pauseLength(&rng), reason: .pause), at: nextStop)
            return
        }
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
        } else if planner.settings.breaks, profile.isOnFoot {
            let upcoming = Int((drivenSinceBreak + total) / TripOdds.meanPauseInterval)
            total += Double(upcoming) * TripOdds.meanPauseLength
        }
        return total
    }
}
