import Foundation
import MapKit
import Observation
import PhoneOnlyCore
import RemoteAPI

/// All GPS commands go to OnDeviceController, never to ConnectionManager or a remote computer.
@MainActor
@Observable
final class PhoneMotionController: ControlTarget {
    let phone: OnDeviceController
    var executionName: String { "iPhone" }
    private(set) var activity = "hold"
    private(set) var progress = 0.0
    private(set) var paused = false
    private(set) var speed = 0.0
    private(set) var deadline: Date?
    private(set) var lastError: String?
    private(set) var planning = false
    private var heading = 0.0
    private var input = JoystickInput.idle
    private var inputAt = Date.distantPast
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var directions: MKDirections?
    @ObservationIgnored private let now: @Sendable () -> Date

    init(phone: OnDeviceController, now: @escaping @Sendable () -> Date = { Date() }) {
        self.phone = phone
        self.now = now
    }

    var isSpoofing: Bool { phone.isSpoofing }
    var isWorking: Bool { planning || phone.isWorking }
    var status: RemoteStatus? {
        RemoteStatus(connected: phone.isSetUp, spoofing: phone.isSpoofing,
                     latitude: phone.current?.latitude, longitude: phone.current?.longitude,
                     placeName: phone.currentName,
                     phase: phone.phase == .stopping ? .stopping : (isWorking ? .starting : (isSpoofing ? .active : .idle)),
                     serverName: "This iPhone", activity: planning ? "planning" : activity,
                     speed: speed, heading: heading, routeProgress: activity == "route" ? progress : nil,
                     routePaused: paused, autoStopAt: deadline?.timeIntervalSince1970)
    }

    @discardableResult
    func start(at coordinate: CLLocationCoordinate2D, name: String?, joystick: Bool = false) async -> Bool {
        guard !isWorking else { return false }
        cancelMotion()
        let token = generation
        guard await phone.stop() else { lastError = phone.lastError; return false }
        guard token == generation else { return false }
        guard await phone.set(coordinate, name: name), token == generation else { return false }
        activity = joystick ? "joystick" : "hold"
        lastError = nil
        if joystick { runJoystick(token: token) }
        return true
    }

    func steer(heading: Double, speed: Double) async -> String? {
        guard !isWorking else { return "Wait for this iPhone to finish starting or stopping." }
        guard phone.isSpoofing else { return "Start the location on this iPhone first." }
        guard heading.isFinite, speed.isFinite, (0...JoystickInput.maxSpeed).contains(speed) else {
            return "That direction or speed isn't valid."
        }
        if activity != "joystick" {
            cancelMotion()
            activity = "joystick"
            runJoystick(token: generation)
        }
        input = JoystickInput(heading: JoystickInput.wrap(heading), speed: speed)
        inputAt = Date()
        self.heading = input.heading
        return nil
    }

    /// Release the thumb immediately when the app becomes inactive. Held locations and routes
    /// retain their background session; joystick motion never continues after the UI disappears.
    func releaseJoystick() { input = .idle; speed = 0 }

    private func runJoystick(token: Int) {
        runner = Task { [weak self] in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, token == self.generation, self.phone.isSpoofing else { return }
                let now = ContinuousClock.now
                let dt = min(0.5, max(0, previous.duration(to: now).seconds))
                previous = now
                guard !self.phone.isUpdatingLocation else { continue }
                let speed = Date().timeIntervalSince(self.inputAt) <= RemoteAPI.joystickTimeout ? self.input.speed : 0
                self.speed = speed
                guard speed > 0, let current = self.phone.current else { continue }
                let moved = PhoneGeo.moved(latitude: current.latitude, longitude: current.longitude,
                                           meters: speed * dt, bearing: self.input.heading)
                guard await self.phone.set(CLLocationCoordinate2D(latitude: moved.latitude, longitude: moved.longitude),
                                          name: "Joystick"), token == self.generation else {
                    if token == self.generation { self.lastError = self.phone.lastError; self.speed = 0 }
                    return
                }
            }
        }
    }

    @discardableResult
    func driveRoute(_ request: RouteRequest) async -> Bool {
        guard !isWorking, request.isValid, request.waypoints.count <= SavedRoute.maxStops else { return false }
        cancelMotion()
        let token = generation
        planning = true
        defer { if token == generation { planning = false } }
        guard await phone.stop() else { lastError = phone.lastError; return false }
        guard token == generation else { return false }
        do {
            var waypoints = request.waypoints
            if request.loopMode == "loop", let first = waypoints.first, let last = waypoints.last,
               first.latitude != last.latitude || first.longitude != last.longitude {
                waypoints.append(.init(latitude: first.latitude, longitude: first.longitude))
            }
            var legs: [[StandaloneRoute.Point]] = []
            for index in 1..<waypoints.count {
                guard token == generation else { return false }
                let a = StandaloneRoute.Point(waypoints[index - 1].latitude, waypoints[index - 1].longitude)
                let b = StandaloneRoute.Point(waypoints[index].latitude, waypoints[index].longitude)
                if request.followRoads, StandaloneRoute.distance(a, b) > 0.01 {
                    let leg = try await roadLeg(from: a, to: b, driving: request.travelMode == "driving")
                    guard token == generation else { return false }
                    legs.append(leg)
                } else { legs.append([a, b]) }
            }
            let route = try StandaloneRoute(legs: legs, waits: waypoints.map { $0.wait ?? 0 },
                                            speed: request.speed, repeatMode: request.loopMode)
            guard token == generation else { return false }
            let first = route.start
            guard await phone.set(.init(latitude: first.latitude, longitude: first.longitude), name: request.name),
                  token == generation else { return false }
            activity = "route"; progress = 0; paused = false; lastError = nil
            runRoute(route, token: token)
            return true
        } catch {
            if token == generation { lastError = "Couldn't plan this route on the iPhone: \(error.localizedDescription)" }
            return false
        }
    }

    private func roadLeg(from a: StandaloneRoute.Point, to b: StandaloneRoute.Point, driving: Bool) async throws -> [StandaloneRoute.Point] {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = driving ? .automobile : .walking
        let directions = MKDirections(request: request)
        self.directions = directions
        defer { self.directions = nil }
        let response = try await directions.calculate()
        guard let polyline = response.routes.first?.polyline, polyline.pointCount >= 2,
              polyline.pointCount <= 100_000 else { throw StandaloneRoute.Problem.invalid }
        var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: polyline.pointCount)
        polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        // Explicit endpoints preserve the chosen stops and continuity between legs.
        return [a] + coordinates.map { StandaloneRoute.Point($0.latitude, $0.longitude) } + [b]
    }

    private func runRoute(_ route: StandaloneRoute, token: Int) {
        runner = Task { [weak self] in
            var elapsed = 0.0
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, token == self.generation, self.phone.isSpoofing else { return }
                let now = ContinuousClock.now
                let dt = min(0.5, max(0, previous.duration(to: now).seconds))
                previous = now
                guard !self.paused, !self.phone.isUpdatingLocation else { self.speed = 0; continue }
                let next = elapsed + dt
                let sample = route.sample(at: next)
                guard await self.phone.set(.init(latitude: sample.point.latitude, longitude: sample.point.longitude),
                                          name: self.phone.currentName), token == self.generation else {
                    if token == self.generation { self.lastError = self.phone.lastError; self.speed = 0 }
                    return
                }
                elapsed = next; self.progress = sample.progress
                self.speed = sample.moving ? route.speed : 0
                if sample.finished { self.activity = "hold"; self.speed = 0; return }
            }
        }
    }

    @discardableResult
    func setPaused(_ paused: Bool) async -> Bool {
        guard activity == "route", phone.isSpoofing else { return false }
        self.paused = paused
        if paused { speed = 0 }
        return true
    }

    @discardableResult
    func setAutoStop(minutes: Int) async -> Bool {
        timer?.cancel(); timer = nil
        deadline = Killswitch.deadline(from: now(), minutes: minutes)
        guard let deadline else { return true }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.deadline == deadline else { return }
                if !self.phone.isSpoofing, !self.phone.isWorking, !self.planning {
                    self.deadline = nil
                    return
                }
                if self.now() >= deadline { _ = await self.stop(); return }
            }
        }
        return true
    }

    @discardableResult
    func stop() async -> Bool {
        cancelMotion()
        timer?.cancel(); timer = nil; deadline = nil
        planning = false; activity = "hold"
        return await phone.stop()
    }

    private func cancelMotion() {
        generation += 1
        runner?.cancel(); runner = nil
        directions?.cancel(); directions = nil
        input = .idle; inputAt = .distantPast; speed = 0; paused = false
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
