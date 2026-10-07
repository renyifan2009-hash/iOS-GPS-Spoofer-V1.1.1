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
    var follow: Bool
    var contextActions: [MapContextAction]
    var onClick: (GeoPoint) -> Void
    var onDragPin: (UUID, GeoPoint) -> Void
    var onContextAction: (MapContextAction, GeoPoint) -> Void
    var onCameraChange: (_ center: GeoPoint, _ spanDegrees: Double, _ heading: Double) -> Void

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
        c.syncRoute(route, travelled: travelledFraction, playing: isPlaying)
        c.syncDevice(device)
        if let focus, c.lastFocusID != focus.id {
            c.lastFocusID = focus.id
            c.apply(focus)
        } else if follow, let device {
            c.keepVisible(device.point)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPicker
        weak var mapView: MKMapView?
        var lastFocusID: UUID?

        private var annotations: [UUID: PinAnnotation] = [:]
        private var dragging: Set<UUID> = []
        private var deviceAnnotation: DeviceAnnotation?
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

        /// Recentre when the device nears the edge of the view.
        func keepVisible(_ point: GeoPoint) {
            guard let map = mapView, point.isValid else { return }
            let visible = map.visibleMapRect
            let inner = visible.insetBy(dx: visible.size.width * 0.18, dy: visible.size.height * 0.2)
            if !inner.contains(MKMapPoint(point.cl)) {
                map.setCenter(point.cl, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = GeoPoint(mapView.region.center)
            let span = mapView.region.span.latitudeDelta
            let heading = mapView.camera.heading
            if let device = deviceAnnotation, let view = mapView.view(for: device) as? DeviceAnnotationView {
                view.update(heading: device.heading, mapHeading: heading, live: device.live)
            }
            // Deferred: this can fire inside a SwiftUI update.
            Task { @MainActor [weak self] in self?.parent.onCameraChange(center, span, heading) }
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
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: "Target")
            case .start:
                view.markerTintColor = .systemGreen
                view.glyphText = "1"
            case .end:
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "flag.checkered", accessibilityDescription: "Destination")
            case .waypoint(let n):
                view.markerTintColor = .systemBlue
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
                if let routeOverlay { map.removeOverlay(routeOverlay) }
                if let travelledOverlay { map.removeOverlay(travelledOverlay) }
                routeOverlay = nil
                travelledOverlay = nil
                if route.count >= 2 {
                    let coords = route.map(\.cl)
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
            if let travelledOverlay, let renderer = map.renderer(for: travelledOverlay) as? MKPolylineRenderer {
                let end = CGFloat(min(max(travelled, 0), 1))
                if abs(renderer.strokeEnd - end) > 0.0005 {
                    renderer.strokeEnd = end
                    renderer.setNeedsDisplay()
                }
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            r.lineWidth = 5
            r.lineCap = .round
            r.lineJoin = .round
            if line === travelledOverlay {
                r.strokeColor = .controlAccentColor
                r.strokeEnd = 0
            } else if routePlaying {
                r.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.35)
            } else {
                r.strokeColor = .controlAccentColor
            }
            return r
        }

        // MARK: Device

        func syncDevice(_ marker: DeviceMarker?) {
            guard let map = mapView else { return }
            guard let marker, marker.point.isValid else {
                if let deviceAnnotation { map.removeAnnotation(deviceAnnotation) }
                deviceAnnotation = nil
                return
            }
            if let ann = deviceAnnotation {
                if !GeoPoint(ann.coordinate).isClose(to: marker.point) {
                    ann.coordinate = marker.point.cl
                }
                ann.heading = marker.heading
                ann.live = marker.live
                if let view = map.view(for: ann) as? DeviceAnnotationView {
                    view.update(heading: marker.heading, mapHeading: map.camera.heading, live: marker.live)
                }
            } else {
                let ann = DeviceAnnotation(coordinate: marker.point.cl)
                ann.heading = marker.heading
                ann.live = marker.live
                deviceAnnotation = ann
                map.addAnnotation(ann)
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
        halo.fillColor = NSColor.systemBlue.withAlphaComponent(0.18).cgColor

        let conePath = CGMutablePath()
        conePath.move(to: CGPoint(x: center.x, y: center.y + 24))
        conePath.addLine(to: CGPoint(x: center.x - 9, y: center.y + 6))
        conePath.addLine(to: CGPoint(x: center.x + 9, y: center.y + 6))
        conePath.closeSubpath()
        cone.path = conePath
        cone.fillColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor

        dot.path = CGPath(ellipseIn: CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18), transform: nil)
        dot.fillColor = NSColor.systemBlue.cgColor
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
            let radians = (heading - mapHeading) * .pi / 180
            cone.setAffineTransform(CGAffineTransform(rotationAngle: -radians))
        } else {
            cone.isHidden = true
        }
        let colour = live ? NSColor.systemBlue : NSColor.systemGray
        dot.fillColor = colour.cgColor
        cone.fillColor = colour.withAlphaComponent(0.85).cgColor
        halo.fillColor = colour.withAlphaComponent(0.18).cgColor
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
        dot.fillColor = NSColor.systemBlue.cgColor
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

    @objc private func fire() { handler() }
}
