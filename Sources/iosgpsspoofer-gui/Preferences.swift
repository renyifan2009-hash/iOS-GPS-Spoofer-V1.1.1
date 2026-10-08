import Foundation
import Observation
import SpooferCore

enum MapStyle: String, CaseIterable, Identifiable {
    case standard, satellite, hybrid

    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }
    var symbolName: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "square.2.layers.3d"
        }
    }
}

/// User settings, persisted to `UserDefaults` as they change.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let units = "units"
        static let engine = "enginePreference"
        static let transport = "transport"
        static let toolPath = "pymobiledevice3Path"
        static let menuBar = "showMenuBarExtra"
        static let mapStyle = "mapStyle"
        static let follow = "followDevice"
        static let instant = "instantTeleport"
        static let interval = "updateInterval"
        static let variation = "speedVariation"
        static let jitter = "positionJitter"
        static let refresh = "autoRefreshInterval"
        static let joystickSpeed = "joystickSpeed"
        static let routeSpeed = "defaultRouteSpeed"
        static let debugLog = "showDebugLog"
        static let recents = "recordRecents"
    }

    var units: UnitSystem { didSet { store(units.rawValue, Key.units) } }
    var enginePreference: EnginePreference { didSet { store(enginePreference.rawValue, Key.engine) } }
    var transport: Transport { didSet { store(transport.rawValue, Key.transport) } }
    /// Explicit pymobiledevice3 executable; empty = find it automatically.
    var pymobiledevice3Path: String { didSet { store(pymobiledevice3Path, Key.toolPath) } }
    var showMenuBarExtra: Bool { didSet { store(showMenuBarExtra, Key.menuBar) } }
    var mapStyle: MapStyle { didSet { store(mapStyle.rawValue, Key.mapStyle) } }
    /// Keep the moving device on screen.
    var followDevice: Bool { didSet { store(followDevice, Key.follow) } }
    /// While spoofing (live engine), clicking the map in Teleport mode moves the device at once.
    var instantTeleport: Bool { didSet { store(instantTeleport, Key.instant) } }
    /// Seconds between position updates while moving.
    var updateInterval: Double { didSet { store(updateInterval, Key.interval) } }
    /// 0…0.3: random speed variation while following a route.
    var speedVariation: Double { didSet { store(speedVariation, Key.variation) } }
    /// Metres of random GPS-like noise added while moving (0 = off).
    var positionJitter: Double { didSet { store(positionJitter, Key.jitter) } }
    var autoRefreshInterval: Double { didSet { store(autoRefreshInterval, Key.refresh) } }
    /// m/s at full joystick deflection.
    var joystickSpeed: Double { didSet { store(joystickSpeed, Key.joystickSpeed) } }
    /// m/s for new routes.
    var defaultRouteSpeed: Double { didSet { store(defaultRouteSpeed, Key.routeSpeed) } }
    var showDebugLog: Bool { didSet { store(showDebugLog, Key.debugLog) } }
    var recordRecents: Bool { didSet { store(recordRecents, Key.recents) } }

    private init() {
        let d = UserDefaults.standard
        units = d.string(forKey: Key.units).flatMap(UnitSystem.init(rawValue:))
            ?? (Locale.current.measurementSystem == .us ? .imperial : .metric)
        enginePreference = d.string(forKey: Key.engine).flatMap(EnginePreference.init(rawValue:)) ?? .automatic
        transport = d.string(forKey: Key.transport).flatMap(Transport.init(rawValue:)) ?? .automatic
        pymobiledevice3Path = d.string(forKey: Key.toolPath) ?? ""
        showMenuBarExtra = d.object(forKey: Key.menuBar) as? Bool ?? true
        mapStyle = d.string(forKey: Key.mapStyle).flatMap(MapStyle.init(rawValue:)) ?? .standard
        followDevice = d.object(forKey: Key.follow) as? Bool ?? true
        instantTeleport = d.object(forKey: Key.instant) as? Bool ?? false
        updateInterval = Self.clamp(d.object(forKey: Key.interval) as? Double ?? 0.5, 0.2, 2)
        speedVariation = Self.clamp(d.object(forKey: Key.variation) as? Double ?? 0, 0, 0.3)
        positionJitter = Self.clamp(d.object(forKey: Key.jitter) as? Double ?? 0, 0, 15)
        autoRefreshInterval = Self.clamp(d.object(forKey: Key.refresh) as? Double ?? 3, 2, 30)
        joystickSpeed = Self.clamp(d.object(forKey: Key.joystickSpeed) as? Double ?? 1.4, 0.3, 70)
        defaultRouteSpeed = Self.clamp(d.object(forKey: Key.routeSpeed) as? Double ?? 1.4, 0.3, 70)
        showDebugLog = d.object(forKey: Key.debugLog) as? Bool ?? false
        recordRecents = d.object(forKey: Key.recents) as? Bool ?? true
    }

    private func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : lo
    }

    /// Restore every setting to its default.
    func resetAll() {
        for key in [Key.units, Key.engine, Key.transport, Key.toolPath, Key.menuBar, Key.mapStyle, Key.follow,
                    Key.instant, Key.interval, Key.variation, Key.jitter, Key.refresh, Key.joystickSpeed,
                    Key.routeSpeed, Key.debugLog, Key.recents] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        units = Locale.current.measurementSystem == .us ? .imperial : .metric
        enginePreference = .automatic
        transport = .automatic
        pymobiledevice3Path = ""
        showMenuBarExtra = true
        mapStyle = .standard
        followDevice = true
        instantTeleport = false
        updateInterval = 0.5
        speedVariation = 0
        positionJitter = 0
        autoRefreshInterval = 3
        joystickSpeed = 1.4
        defaultRouteSpeed = 1.4
        showDebugLog = false
        recordRecents = true
    }
}

/// Movement presets shown as quick picks (speeds in m/s).
struct SpeedPreset: Identifiable, Hashable {
    let name: String
    let symbolName: String
    let metresPerSecond: Double
    var id: String { name }

    static let all: [SpeedPreset] = [
        SpeedPreset(name: "Walk", symbolName: "figure.walk", metresPerSecond: 5 / 3.6),
        SpeedPreset(name: "Run", symbolName: "figure.run", metresPerSecond: 10 / 3.6),
        SpeedPreset(name: "Cycle", symbolName: "bicycle", metresPerSecond: 18 / 3.6),
        SpeedPreset(name: "Drive", symbolName: "car.fill", metresPerSecond: 50 / 3.6),
        SpeedPreset(name: "Highway", symbolName: "road.lanes", metresPerSecond: 110 / 3.6),
    ]
}
