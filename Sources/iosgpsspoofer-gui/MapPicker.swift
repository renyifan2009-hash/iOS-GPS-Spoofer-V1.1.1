import AppKit
import MapKit
import SpooferCore
import SwiftUI

extension GeoPoint {
    init(_ c: CLLocationCoordinate2D) { self.init(latitude: c.latitude, longitude: c.longitude) }
    var cl: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// One pin on the map.
struct MapPin: Identifiable, Equatable {
    enum Role: Equatable {
        case target
        case start
        case end
        case waypoint(Int)
        /// Small dot, for routes with many points.
        case compact
    }
    let id: UUID
    var point: GeoPoint
    var role: Role
}

/// The simulated device position.
struct DeviceMarker: Equatable {
    var point: GeoPoint
    var heading: Double?
    var live: Bool
    /// Travelling along a route or steered by the joystick: the dot glides
    /// from one position update to the next instead of jumping.
    var moving = false
}

enum MapContextAction {
    case teleportHere, setTarget, addWaypoint, joystickHere, addFavorite, copyCoordinates
}

/// An `MKMapView` wrapper (SwiftUI's `Map` on macOS doesn't reliably deliver
/// clicks or drags).
struct MapPicker: NSViewRepresentable {
    var pins: [MapPin]
    var route: [GeoPoint]
    /// 0…1 of `route` already covered; drawn on top in the accent colour.
    var travelledFraction: Double
    var isPlaying: Bool
    var device: DeviceMarker?
    var style: MapStyle
    var focus: MapFocusRequest?
    /// Keep the device centred, like Maps' tracking mode.
    var follow: Bool
    var contextActions: [MapContextAction]
    var onClick: (GeoPoint) -> Void
    var onDragPin: (UUID, GeoPoint) -> Void
    var onContextAction: (MapContextAction, GeoPoint) -> Void
    var onCameraChange: (_ center: GeoPoint, _ spanDegrees: Double, _ heading: Double) -> Void
    /// The user dragged or scrolled the map (or asked it to show something
    /// else) while it was following the device.
    var onStopFollowing: () -> Void = {}

    func makeNSView(context: Context) -> SpoofMapView {
        let map = SpoofMapView()
        map.delegate = context.coordinator
        map.showsZoomControls = true
        map.showsCompass = true
        map.showsScale = true
        map.showsPitchControl = true
        let click = NSClickGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handleClick(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)
        map.contextMenuProvider = { [weak coordinator = context.coordinator] coordinate in
            coordinator?.menu(at: coordinate)
        }
        context.coordinator.mapView = map
        context.coordinator.installEventMonitor()
        if let first = pins.first?.point ?? device?.point {
            map.setRegion(MKCoordinateRegion(center: first.cl, span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)),
                          animated: false)
        }
        return map
    }

    func updateNSView(_ map: SpoofMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.applyStyle(style)
        c.sync(pins: pins)
        // The dot first: the route's travelled line glides along with it.
        c.syncDevice(device)
        c.syncRoute(route, travelled: travelledFraction, playing: isPlaying)
        let wantsFollow = follow && device != nil
        if !follow { c.awaitingFollowStop = false }
        if let focus, c.lastFocusID != focus.id {
            c.lastFocusID = focus.id
            if wantsFollow, !Self.focus(focus, isOn: device) {
                // Showing something else: stop pulling the camera back to the
                // dot. The model hears about it after this update (it can't
                // change during one), so ignore `follow` until it has.
                c.awaitingFollowStop = true
                let stop = onStopFollowing
                Task { @MainActor in stop() }
                c.setFollowing(false)
            }
            c.apply(focus)
        }
        c.setFollowing(wantsFollow && !c.awaitingFollowStop)
    }

    /// The focus request shows the device itself (a teleport or a search to
    /// where the phone is), so following can carry on.
    static func focus(_ focus: MapFocusRequest, isOn device: DeviceMarker?) -> Bool {
        guard let device, case let .point(point, _) = focus.kind else { return false }
        return Geo.distance(point, device.point) < 50
    }

    static func dismantleNSView(_ map: SpoofMapView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPicker
        weak var mapView: MKMapView?
        var lastFocusID: UUID?
        /// Asked the model to stop following; waiting for it to say so.
        var awaitingFollowStop = false

        private var annotations: [UUID: PinAnnotation] = [:]
        private var dragging: Set<UUID> = []
        private var deviceAnnotation: DeviceAnnotation?
        private var casingOverlay: MKPolyline?
        private var routeOverlay: MKPolyline?
        private var travelledOverlay: MKPolyline?
        private var routeKey = ""
        private var routePlaying = false
        private var appliedStyle: MapStyle?
        private var pendingClick: Task<Void, Never>?
        private var lastClickTime: TimeInterval?

        init(parent: MapPicker) {
            self.parent = parent
        }

        // MARK: Input

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = mapView, gesture.state == .ended else { return }
            let point = gesture.location(in: map)
            // Clicks on a pin select/drag it — never drop a new one there.
            if let superview = map.superview {
                var hit = map.hitTest(map.convert(point, to: superview))
                while let view = hit {
                    if view is MKAnnotationView { return }
                    if view === map { break }
                    hit = view.superview
                }
            }
            let coordinate = GeoPoint(map.convert(point, toCoordinateFrom: map))

            // The second click of a double-click zooms the map; don't treat the
            // pair as a click.
            let now = ProcessInfo.processInfo.systemUptime
            let interval = min(NSEvent.doubleClickInterval, 0.35)
            if let last = lastClickTime, now - last < interval {
                pendingClick?.cancel()
                pendingClick = nil
                lastClickTime = nil
                return
            }
            lastClickTime = now
            pendingClick = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard !Task.isCancelled, let self else { return }
                self.pendingClick = nil
                self.parent.onClick(coordinate)
            }
        }

        func menu(at coordinate: CLLocationCoordinate2D) -> NSMenu? {
            let point = GeoPoint(coordinate)
            guard point.isValid else { return nil }
            let menu = NSMenu()
            let header = NSMenuItem(title: Coordinate.format(point, precision: 5), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            menu.addItem(.separator())
            for action in parent.contextActions {
                let (title, symbol) = Self.describe(action)
                menu.addItem(ClosureMenuItem(title, symbol: symbol) { [weak self] in
                    self?.parent.onContextAction(action, point)
                })
            }
            return menu
        }

        private static func describe(_ action: MapContextAction) -> (String, String) {
            switch action {
            case .teleportHere: return ("Teleport Here", "location.fill")
            case .setTarget: return ("Set as Teleport Target", "mappin")
            case .addWaypoint: return ("Add Waypoint Here", "plus.circle")
            case .joystickHere: return ("Start Joystick Here", "gamecontroller")
            case .addFavorite: return ("Add to Favorites…", "star")
            case .copyCoordinates: return ("Copy Coordinates", "doc.on.doc")
            }
        }

        // MARK: Style & camera

        func applyStyle(_ style: MapStyle) {
            guard let map = mapView, appliedStyle != style else { return }
            appliedStyle = style
            switch style {
            case .standard:
                map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic, emphasisStyle: .default)
            case .satellite:
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
            case .hybrid:
                map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
            }
        }

        func apply(_ focus: MapFocusRequest) {
            guard let map = mapView else { return }
            cameraBusyUntil = CACurrentMediaTime() + 0.6
            switch focus.kind {
            case let .point(p, zoomIn):
                guard p.isValid else { return }
                let span = map.region.span.latitudeDelta
                if zoomIn || span > 1.5 || span < 0.0005 {
                    map.setRegion(MKCoordinateRegion(center: p.cl, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)),
                                  animated: true)
                } else {
                    map.setCenter(p.cl, animated: true)
                }
            case let .fit(points):
                let valid = points.filter(\.isValid)
                guard !valid.isEmpty else { return }
                let rect = valid.reduce(MKMapRect.null) { acc, p in
                    acc.union(MKMapRect(origin: MKMapPoint(p.cl), size: MKMapSize(width: 1, height: 1)))
                }
                let minimum = 2_000.0   // map points ≈ metres at mid latitudes; avoid zooming in absurdly
                let padded = rect.size.width < minimum && rect.size.height < minimum
                    ? rect.insetBy(dx: -minimum / 2, dy: -minimum / 2) : rect
                map.setVisibleMapRect(padded, edgePadding: NSEdgeInsets(top: 90, left: 60, bottom: 150, right: 60),
                                      animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if let device = deviceAnnotation, let view = mapView.view(for: device) as? DeviceAnnotationView {
                view.update(heading: displayedHeading ?? device.heading, mapHeading: mapView.camera.heading,
                            live: device.live)
            }
            reportCamera()
        }

        /// Tell the model where the camera is, at most a few times a second:
        /// while following a moving device the region changes every frame.
        /// Deferred either way, since this can fire inside a SwiftUI update.
        private func reportCamera() {
            guard !cameraReportPending else { return }
            cameraReportPending = true
            let delay = following && deviceGlide != nil ? 0.3 : 0
            Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard let self, let map = self.mapView else { return }
                self.cameraReportPending = false
                self.parent.onCameraChange(GeoPoint(map.region.center), map.region.span.latitudeDelta,
                                           map.camera.heading)
            }
        }

        // MARK: Following the device

        private var following = false
        private var cameraReportPending = false
        /// A camera glide onto the dot: where it started, and when.
        private var cameraGlide: (from: CLLocationCoordinate2D, start: CFTimeInterval)?
        /// While MapKit animates a zoom for a recentre, don't steer the camera.
        private var cameraBusyUntil: CFTimeInterval = 0

        func setFollowing(_ on: Bool) {
            guard on != following else { return }
            following = on
            if on {
                recenter()
            } else {
                cameraGlide = nil
            }
        }

        /// Bring the camera back to the dot: a short glide at the current zoom,
        /// a cut when the dot is far off screen (after a teleport), or a zoom
        /// to street level when the map is far out or in.
        private func recenter() {
            guard let map = mapView, let device = displayedDevice else { return }
            let span = map.region.span.latitudeDelta
            let visible = map.visibleMapRect
            let nearby = visible.insetBy(dx: -visible.size.width, dy: -visible.size.height)
            if span > 1.5 || span < 0.0005 {
                cameraGlide = nil
                cameraBusyUntil = CACurrentMediaTime() + 0.6
                map.setRegion(MKCoordinateRegion(center: device, span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)),
                              animated: true)
            } else if !nearby.contains(MKMapPoint(device)) {
                cameraGlide = nil
                map.setCenter(device, animated: false)
            } else {
                cameraGlide = (map.centerCoordinate, CACurrentMediaTime())
            }
            startTicking()
        }

        private func centerCamera(on coordinate: CLLocationCoordinate2D) {
            guard let map = mapView else { return }
            // Skip sub-pixel moves: they cost a redraw and show nothing.
            let point = map.convert(coordinate, toPointTo: map)
            guard hypot(point.x - map.bounds.midX, point.y - map.bounds.midY) > 0.25 else { return }
            map.setCenter(coordinate, animated: false)
        }

        // MARK: Frame clock

        private var displayLink: CADisplayLink?

        private func startTicking() {
            guard displayLink == nil, let map = mapView else { return }
            let link = map.displayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopTicking() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// One display frame: move the dot along its glide, and keep the camera
        /// on it while following. Stops itself once nothing is moving.
        @objc private func tick(_ link: CADisplayLink) {
            #if DEBUG
            DebugSnapshot.frameTicks += 1
            if let map = mapView, let device = displayedDevice {
                DebugSnapshot.cameraOffset = Geo.distance(GeoPoint(map.centerCoordinate), GeoPoint(device))
                DebugSnapshot.following = following
                DebugSnapshot.gliding = deviceGlide != nil
            }
            #endif
            let now = CACurrentMediaTime()
            var busy = false
            if let glide = deviceGlide {
                let t = min(1, (now - glide.start) / glide.duration)
                let coordinate = Self.lerp(glide.from, glide.to, t)
                deviceAnnotation?.coordinate = coordinate
                displayedDevice = coordinate
                if let to = glide.headingTo {
                    let heading = glide.headingFrom.map { Self.lerpAngle($0, to, t) } ?? to
                    displayedHeading = heading
                    if let map = mapView, let ann = deviceAnnotation, let view = map.view(for: ann) as? DeviceAnnotationView {
                        view.update(heading: heading, mapHeading: map.camera.heading, live: ann.live)
                    }
                }
                if t >= 1 { deviceGlide = nil } else { busy = true }
            }
            if let glide = travelledGlide {
                let t = min(1, (now - glide.start) / glide.duration)
                // Redrawing a long route is the costly part, so ~12 times a second.
                if t >= 1 || now - lastTravelledDraw >= 1.0 / 12 {
                    setTravelled(glide.from + (glide.to - glide.from) * t)
                }
                if t >= 1 { travelledGlide = nil } else { busy = true }
            }
            if following, let device = displayedDevice, now >= cameraBusyUntil {
                if let glide = cameraGlide {
                    let t = min(1, (now - glide.start) / 0.55)
                    centerCamera(on: Self.lerp(glide.from, device, t * t * (3 - 2 * t)))
                    if t >= 1 { cameraGlide = nil } else { busy = true }
                } else {
                    centerCamera(on: device)
                }
            }
            if now < cameraBusyUntil { busy = true }
            // Linger a moment so the next position update continues smoothly.
            if !busy && now - lastDeviceUpdate > 1.5 { stopTicking() }
        }

        static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, _ t: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                   longitude: a.longitude + (b.longitude - a.longitude) * t)
        }

        /// Interpolate compass headings the short way round.
        static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
            let delta = (b - a + 540).truncatingRemainder(dividingBy: 360) - 180
            return Geo.normalizedBearing(a + delta * t)
        }

        // MARK: Noticing the user move the map

        private var eventMonitor: Any?
        /// Where the current mouse drag started, if on the map itself (not on
        /// a pin, and not on a panel floating over the map).
        private var dragStart: NSPoint?

        func installEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .scrollWheel]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.observe(event) }
                return event
            }
        }

        func tearDown() {
            stopTicking()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
        }

        private func observe(_ event: NSEvent) {
            guard let map = mapView, let window = map.window, event.window === window else { return }
            switch event.type {
            case .leftMouseDown:
                dragStart = isBareMap(at: event.locationInWindow, in: window) ? event.locationInWindow : nil
            case .leftMouseDragged:
                // A few points of travel: a click that wobbles isn't a pan.
                if following, let start = dragStart,
                   hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 {
                    stopFollowingForUser()
                }
            case .scrollWheel:
                // A trackpad's two-finger scroll pans the map; a mouse wheel
                // (or ⌘-scroll) zooms, which keeps following.
                if following, event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command),
                   abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) > 0.5,
                   isBareMap(at: event.locationInWindow, in: window) {
                    stopFollowingForUser()
                }
            default:
                break
            }
        }

        /// The map is what's under `location`, not a pin or a SwiftUI panel.
        private func isBareMap(at location: NSPoint, in window: NSWindow) -> Bool {
            guard let map = mapView, let hit = window.contentView?.hitTest(location),
                  hit === map || hit.isDescendant(of: map) else { return false }
            var view: NSView? = hit
            while let current = view, current !== map {
                if current is MKAnnotationView { return false }
                view = current.superview
            }
            return true
        }

        private func stopFollowingForUser() {
            following = false
            cameraGlide = nil
            parent.onStopFollowing()
        }

        // MARK: Pins

        func sync(pins: [MapPin]) {
            guard let map = mapView else { return }
            let wanted = Dictionary(pins.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, ann) in annotations where wanted[id] == nil || (wanted[id]?.role == .compact) != (ann.role == .compact) {
                map.removeAnnotation(ann)
                annotations[id] = nil
            }
            for pin in pins {
                if let ann = annotations[pin.id] {
                    if !dragging.contains(pin.id), !GeoPoint(ann.coordinate).isClose(to: pin.point) {
                        ann.coordinate = pin.point.cl
                    }
                    if ann.role != pin.role {
                        ann.role = pin.role
                        if let view = map.view(for: ann) as? MKMarkerAnnotationView { Self.style(view, for: pin.role) }
                    }
                } else {
                    let ann = PinAnnotation(id: pin.id, coordinate: pin.point.cl, role: pin.role)
                    annotations[pin.id] = ann
                    map.addAnnotation(ann)
                }
            }
        }

        private static func style(_ view: MKMarkerAnnotationView, for role: MapPin.Role) {
            view.glyphImage = nil
            view.glyphText = nil
            switch role {
            case .target:
                view.markerTintColor = Brand.nsIndigo
                view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Target")
            case .start:
                view.markerTintColor = Brand.nsLive
                view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "Start")
            case .end:
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "flag.checkered", accessibilityDescription: "Destination")
            case .waypoint(let n):
                view.markerTintColor = Brand.nsSky
                view.glyphText = "\(n)"
            case .compact:
                break
            }
        }

        // MARK: Route

        func syncRoute(_ route: [GeoPoint], travelled: Double, playing: Bool) {
            guard let map = mapView else { return }
            let key = route.count < 2 ? "" : "\(route.count)|\(route.first!.latitude),\(route.first!.longitude)|\(route.last!.latitude),\(route.last!.longitude)|\(Int(Geo.length(of: route)))"
            if key != routeKey || playing != routePlaying {
                routeKey = key
                routePlaying = playing
                for overlay in [casingOverlay, routeOverlay, travelledOverlay].compactMap({ $0 }) {
                    map.removeOverlay(overlay)
                }
                casingOverlay = nil
                routeOverlay = nil
                travelledOverlay = nil
                travelledGlide = nil
                shownTravelled = nil
                if route.count >= 2 {
                    let coords = route.map(\.cl)
                    // A wide pale casing under the line keeps it readable on any map style.
                    let casing = MKPolyline(coordinates: coords, count: coords.count)
                    casingOverlay = casing
                    map.addOverlay(casing, level: .aboveRoads)
                    let base = MKPolyline(coordinates: coords, count: coords.count)
                    routeOverlay = base
                    map.addOverlay(base, level: .aboveRoads)
                    if playing {
                        let done = MKPolyline(coordinates: coords, count: coords.count)
                        travelledOverlay = done
                        map.addOverlay(done, level: .aboveRoads)
                    }
                }
            }
            guard let travelledOverlay, map.renderer(for: travelledOverlay) is MKPolylineRenderer else { return }
            let end = min(max(travelled, 0), 1)
            guard end != travelledTarget || shownTravelled == nil else { return }
            travelledTarget = end
            if let shown = shownTravelled, deviceGlide != nil, abs(end - shown) < 0.05 {
                // Advance the line's tip together with the gliding dot.
                travelledGlide = (shown, end, CACurrentMediaTime(), max(0.05, updateInterval * 1.1))
                startTicking()
            } else {
                // A new route, a seek or a new lap: jump.
                travelledGlide = nil
                setTravelled(end)
            }
        }

        /// The "travelled" line's tip, as a fraction of the route.
        private var shownTravelled: Double?
        private var travelledTarget: Double = 0
        private var travelledGlide: (from: Double, to: Double, start: CFTimeInterval, duration: CFTimeInterval)?
        private var lastTravelledDraw: CFTimeInterval = 0

        private func setTravelled(_ fraction: Double) {
            guard let map = mapView, let travelledOverlay,
                  let renderer = map.renderer(for: travelledOverlay) as? MKPolylineRenderer else { return }
            shownTravelled = fraction
            lastTravelledDraw = CACurrentMediaTime()
            if abs(Double(renderer.strokeEnd) - fraction) > 1e-6 {
                renderer.strokeEnd = CGFloat(fraction)
                renderer.setNeedsDisplay()
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            if line === casingOverlay {
                let casing = MKPolylineRenderer(polyline: line)
                casing.lineWidth = 10
                casing.lineCap = .round
                casing.lineJoin = .round
                casing.strokeColor = NSColor.white.withAlphaComponent(routePlaying ? 0.55 : 0.85)
                return casing
            }
            // Start (green) → brand indigo → destination (sky), like a progress ribbon.
            let r = MKGradientPolylineRenderer(polyline: line)
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            let dim: CGFloat = (routePlaying && line !== travelledOverlay) ? 0.35 : 1
            r.setColors([Brand.nsLive.withAlphaComponent(dim), Brand.nsIndigo.withAlphaComponent(dim),
                         Brand.nsSky.withAlphaComponent(dim)],
                        locations: [0, 0.55, 1])
            if line === travelledOverlay { r.strokeEnd = 0 }
            return r
        }

        // MARK: Device

        /// The dot's journey from where it's drawn to the newest position.
        private struct Glide {
            var from: CLLocationCoordinate2D
            var to: CLLocationCoordinate2D
            var start: CFTimeInterval
            var duration: CFTimeInterval
            var headingFrom: Double?
            var headingTo: Double?
        }

        private var deviceGlide: Glide?
        /// Where the dot is drawn right now (mid-glide, it trails the device).
        private var displayedDevice: CLLocationCoordinate2D?
        private var displayedHeading: Double?
        /// The latest position the dot was told about.
        private var deviceTarget: CLLocationCoordinate2D?
        private var lastDeviceUpdate: CFTimeInterval = 0
        /// Smoothed time between position updates: how long each glide lasts.
        private var updateInterval: CFTimeInterval = 0.5

        func syncDevice(_ marker: DeviceMarker?) {
            guard let map = mapView else { return }
            guard let marker, marker.point.isValid else {
                if let deviceAnnotation { map.removeAnnotation(deviceAnnotation) }
                deviceAnnotation = nil
                deviceGlide = nil
                displayedDevice = nil
                displayedHeading = nil
                deviceTarget = nil
                return
            }
            let target = marker.point.cl
            let now = CACurrentMediaTime()

            guard let ann = deviceAnnotation else {
                let ann = DeviceAnnotation(coordinate: target)
                ann.heading = marker.heading
                ann.live = marker.live
                deviceAnnotation = ann
                displayedDevice = target
                displayedHeading = marker.heading
                deviceTarget = target
                lastDeviceUpdate = now
                map.addAnnotation(ann)
                if following { recenter() }
                return
            }

            ann.live = marker.live
            ann.heading = marker.heading
            if let last = deviceTarget, GeoPoint(last).isClose(to: marker.point) {
                // Same position (another part of the window changed): just
                // refresh the look, unless a glide is drawing the heading.
                if deviceGlide == nil, let view = map.view(for: ann) as? DeviceAnnotationView {
                    view.update(heading: marker.heading, mapHeading: map.camera.heading, live: marker.live)
                }
                return
            }

            let gap = now - lastDeviceUpdate
            if gap < 3 { updateInterval = updateInterval * 0.7 + min(max(gap, 0.05), 1.5) * 0.3 }
            lastDeviceUpdate = now
            deviceTarget = target

            let from = displayedDevice ?? ann.coordinate
            let jump = Geo.distance(GeoPoint(from), marker.point)
            if marker.moving, jump < 2_000, abs(target.longitude - from.longitude) < 180 {
                // Slightly longer than the update interval, so the dot never
                // stops between updates; each glide starts from where it is.
                deviceGlide = Glide(from: from, to: target, start: now, duration: max(0.05, updateInterval * 1.1),
                                    headingFrom: displayedHeading ?? marker.heading, headingTo: marker.heading)
                if marker.heading == nil, displayedHeading != nil {
                    // Stopped turning into motion: hide the heading cone now.
                    displayedHeading = nil
                    if let view = map.view(for: ann) as? DeviceAnnotationView {
                        view.update(heading: nil, mapHeading: map.camera.heading, live: marker.live)
                    }
                }
                startTicking()
            } else {
                // A teleport, or a step while paused: jump straight there.
                deviceGlide = nil
                ann.coordinate = target
                displayedDevice = target
                displayedHeading = marker.heading
                if let view = map.view(for: ann) as? DeviceAnnotationView {
                    view.update(heading: marker.heading, mapHeading: map.camera.heading, live: marker.live)
                }
                if following { recenter() }
            }
        }

        // MARK: Annotation views

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let device = annotation as? DeviceAnnotation {
                let id = "device"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DeviceAnnotationView)
                    ?? DeviceAnnotationView(annotation: device, reuseIdentifier: id)
                view.annotation = device
                view.update(heading: device.heading, mapHeading: mapView.camera.heading, live: device.live)
                return view
            }
            guard let pin = annotation as? PinAnnotation else { return nil }
            if pin.role == .compact {
                let id = "dot"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? DotAnnotationView)
                    ?? DotAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                view.isDraggable = true
                return view
            }
            let id = "pin"
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
            view.annotation = pin
            Self.style(view, for: pin.role)
            view.isDraggable = true
            view.animatesWhenAdded = false
            view.displayPriority = .required
            view.titleVisibility = .hidden
            return view
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard let pin = view.annotation as? PinAnnotation else { return }
            switch newState {
            case .starting:
                dragging.insert(pin.id)
            case .ending, .canceling:
                view.dragState = .none
                dragging.remove(pin.id)
                parent.onDragPin(pin.id, GeoPoint(pin.coordinate))
            default:
                break
            }
        }
    }
}

// MARK: - Map view & annotations

/// MKMapView with a right-click menu.
final class SpoofMapView: MKMapView {
    var contextMenuProvider: (@MainActor (CLLocationCoordinate2D) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let coordinate = convert(point, toCoordinateFrom: self)
        return contextMenuProvider?(coordinate) ?? super.menu(for: event)
    }
}

final class PinAnnotation: NSObject, MKAnnotation {
    let id: UUID
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var role: MapPin.Role

    init(id: UUID, coordinate: CLLocationCoordinate2D, role: MapPin.Role) {
        self.id = id
        self.coordinate = coordinate
        self.role = role
    }
}

final class DeviceAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var heading: Double?
    var live = true

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// The simulated position: a blue dot with a heading cone and a soft pulse.
final class DeviceAnnotationView: MKAnnotationView {
    private let halo = CAShapeLayer()
    private let cone = CAShapeLayer()
    private let dot = CAShapeLayer()
    private var pulsing = false

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 56, height: 56)
        wantsLayer = true
        canShowCallout = false
        isDraggable = false
        displayPriority = .required
        collisionMode = .circle
        zPriority = .max

        let bounds = CGRect(x: 0, y: 0, width: 56, height: 56)
        let center = CGPoint(x: 28, y: 28)
        for layer in [halo, cone, dot] {
            layer.frame = bounds
            self.layer?.addSublayer(layer)
        }
        halo.path = CGPath(ellipseIn: CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40), transform: nil)
        halo.fillColor = Brand.nsSky.withAlphaComponent(0.22).cgColor

        // Point the cone at screen-up (north on an unrotated map). The view's
        // layers are flipped (y down), so "up" is -y here; `up` keeps it right
        // either way.
        let up: CGFloat = isFlipped ? -1 : 1
        let conePath = CGMutablePath()
        conePath.move(to: CGPoint(x: center.x, y: center.y + 24 * up))
        conePath.addLine(to: CGPoint(x: center.x - 9, y: center.y + 6 * up))
        conePath.addLine(to: CGPoint(x: center.x + 9, y: center.y + 6 * up))
        conePath.closeSubpath()
        cone.path = conePath
        cone.fillColor = Brand.nsSky.withAlphaComponent(0.85).cgColor

        dot.path = CGPath(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18), transform: nil)
        dot.fillColor = Brand.nsIndigo.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 3
        dot.shadowColor = NSColor.black.cgColor
        dot.shadowOpacity = 0.3
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(heading: Double?, mapHeading: Double, live: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let heading {
            cone.isHidden = false
            // Compass headings turn clockwise. In flipped (y-down) layers a
            // positive angle turns clockwise on screen; in y-up ones, negative.
            let radians = (heading - mapHeading) * .pi / 180
            cone.setAffineTransform(CGAffineTransform(rotationAngle: isFlipped ? radians : -radians))
        } else {
            cone.isHidden = true
        }
        let colour = live ? Brand.nsIndigo : NSColor.systemGray
        let glow = live ? Brand.nsSky : NSColor.systemGray
        dot.fillColor = colour.cgColor
        cone.fillColor = glow.withAlphaComponent(0.85).cgColor
        halo.fillColor = glow.withAlphaComponent(0.22).cgColor
        CATransaction.commit()

        if live != pulsing {
            pulsing = live
            if live {
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.55
                scale.toValue = 1.25
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0.9
                fade.toValue = 0
                let group = CAAnimationGroup()
                group.animations = [scale, fade]
                group.duration = 1.8
                group.repeatCount = .infinity
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                halo.add(group, forKey: "pulse")
            } else {
                halo.removeAnimation(forKey: "pulse")
            }
        }
    }
}

/// A small draggable dot for the middle points of long routes.
final class DotAnnotationView: MKAnnotationView {
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = NSRect(x: 0, y: 0, width: 14, height: 14)
        wantsLayer = true
        let dot = CAShapeLayer()
        dot.frame = CGRect(x: 0, y: 0, width: 14, height: 14)
        dot.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 10, height: 10), transform: nil)
        dot.fillColor = Brand.nsSky.cgColor
        dot.strokeColor = NSColor.white.cgColor
        dot.lineWidth = 2
        layer?.addSublayer(dot)
        displayPriority = .defaultHigh
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // Menu actions arrive on the main thread.
    @MainActor @objc private func fire() { handler() }
}
