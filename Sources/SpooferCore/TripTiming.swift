import Foundation

/// How long a planned lap takes: a backward pass (the speed each point allows,
/// given the braking ahead), a forward pass (the speed reachable, given the
/// acceleration), then the speed-up / cruise / slow-down time of each stretch.
enum TripTiming {
    /// Seconds to cover `length` metres from `entry` to `exit` speed, cruising at
    /// `cruise` when there's room.
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
        top[0] = max(top[0], speed)
        if nodes.count > 1 {
            for i in stride(from: nodes.count - 2, through: 0, by: -1) {
                let d = nodes[i + 1].at - nodes[i].at
                top[i] = min(top[i], (top[i + 1] * top[i + 1] + 2 * b * d).squareRoot())
            }
        }
        var v = top
        v[0] = min(speed, top[0])
        var total = 0.0
        for i in nodes.indices.dropFirst() {
            let d = nodes[i].at - nodes[i - 1].at
            v[i] = min(top[i], (v[i - 1] * v[i - 1] + 2 * a * d).squareRoot())
            let cruise = plan.cruise(at: (nodes[i].at + nodes[i - 1].at) / 2, settings: settings)
            total += segmentTime(length: d, entry: v[i - 1], exit: v[i], cruise: cruise, acceleration: a, braking: b)
        }
        return total + waits
    }
}
