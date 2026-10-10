import Foundation

/// The wire protocol between the iPhone remote app and the Mac helper
/// (`iosgpsspoof serve`, or the Mac app with Settings ▸ Remote turned on).
///
/// JSON over plain HTTP/1.1 on the local network. The Mac only accepts
/// connections from private / link-local addresses, and every request except
/// `GET /info` and `POST /pair` must carry `Authorization: Bearer <token>`,
/// where the token comes from pairing with the 6-digit code the Mac shows.
///
///     GET  /info       → ServerInfo                       (no token needed)
///     POST /pair       PairRequest → PairResponse         (no token needed)
///     GET  /status     → RemoteStatus
///     POST /location   LocationRequest → RemoteStatus     (moves now if spoofing)
///     POST /start      LocationRequest? → RemoteStatus    (body optional)
///     POST /route      RouteRequest → RemoteStatus        (drives a route)
///     POST /stop       → RemoteStatus                     (restores the real GPS)
///     POST /unpair     → RemoteStatus                     (revokes this token)
///
/// Errors come back as a non-2xx status with an `APIError` body.
public enum RemoteAPI {
    public static let version = 1
    /// Bonjour service type the Mac advertises and the iPhone browses for.
    public static let serviceType = "_iosgpsspoof._tcp"
    public static let defaultPort: UInt16 = 47_653
    public static let pairingCodeLength = 6

    public enum Path {
        public static let info = "/info"
        public static let pair = "/pair"
        public static let unpair = "/unpair"
        public static let status = "/status"
        public static let location = "/location"
        public static let start = "/start"
        public static let route = "/route"
        public static let stop = "/stop"
    }

    /// Keys of the Bonjour TXT record.
    public enum TXTKey {
        public static let version = "v"
        public static let serverID = "id"
        public static let name = "name"
        /// Comma-separated IPv4 addresses, a fallback when resolving fails.
        public static let addresses = "ip"
        public static let port = "port"
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

/// Who is answering; safe to show before pairing.
public struct ServerInfo: Codable, Sendable, Equatable {
    /// Stable across restarts, so the iPhone can find its paired Mac again.
    public var serverID: String
    public var name: String
    public var version: Int

    public init(serverID: String, name: String, version: Int = RemoteAPI.version) {
        self.serverID = serverID
        self.name = name
        self.version = version
    }
}

public struct PairRequest: Codable, Sendable, Equatable {
    public var code: String
    public var clientName: String
    /// Stable per iPhone, so re-pairing replaces the old token instead of
    /// piling up entries.
    public var clientID: String

    public init(code: String, clientName: String, clientID: String) {
        self.code = code
        self.clientName = clientName
        self.clientID = clientID
    }
}

public struct PairResponse: Codable, Sendable, Equatable {
    public var token: String
    public var server: ServerInfo

    public init(token: String, server: ServerInfo) {
        self.token = token
        self.server = server
    }
}

public struct LocationRequest: Codable, Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Shown back in `RemoteStatus.placeName` (and on the Mac).
    public var name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }

    public var isValid: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

/// A route for the Mac to drive, sent by the iPhone. The Mac plans it (with the
/// realistic-trips engine when `realistic`) and moves the location along it; a
/// `POST /stop` ends it and restores the real GPS. Travel and loop modes are
/// strings so this library stays free of SpooferCore; they match the raw values
/// of SpooferCore's `TravelMode` and `LoopMode`.
public struct RouteRequest: Codable, Sendable, Equatable {
    /// A point on the route, with an optional wait there.
    public struct Waypoint: Codable, Sendable, Equatable {
        public var latitude: Double
        public var longitude: Double
        /// Seconds to wait at this point (nil or 0: don't wait).
        public var wait: Double?

        public init(latitude: Double, longitude: Double, wait: Double? = nil) {
            self.latitude = latitude
            self.longitude = longitude
            self.wait = wait
        }

        public var isValid: Bool {
            latitude.isFinite && longitude.isFinite
                && (-90...90).contains(latitude) && (-180...180).contains(longitude)
                && (wait.map { $0.isFinite && $0 >= 0 } ?? true)
        }
    }

    /// The route's points, in order (two or more).
    public var waypoints: [Waypoint]
    /// Follow real roads and paths between waypoints, instead of straight lines.
    public var followRoads: Bool
    /// "walking" or "driving".
    public var travelMode: String
    /// "once", "loop" or "pingPong".
    public var loopMode: String
    /// Top speed, metres per second.
    public var speed: Double
    /// Move like a real person (the realistic-trips engine).
    public var realistic: Bool
    /// With `realistic` and driving: slow down in rush hour (time-of-day traffic).
    public var timeOfDayTraffic: Bool
    /// Shown back in `RemoteStatus.placeName` and on the Mac.
    public var name: String?

    public static let travelModes = ["walking", "driving"]
    public static let loopModes = ["once", "loop", "pingPong"]

    public init(waypoints: [Waypoint], followRoads: Bool = false, travelMode: String = "walking",
                loopMode: String = "once", speed: Double = 1.4, realistic: Bool = true,
                timeOfDayTraffic: Bool = false, name: String? = nil) {
        self.waypoints = waypoints
        self.followRoads = followRoads
        self.travelMode = travelMode
        self.loopMode = loopMode
        self.speed = speed
        self.realistic = realistic
        self.timeOfDayTraffic = timeOfDayTraffic
        self.name = name
    }

    public var isValid: Bool {
        waypoints.count >= 2 && waypoints.allSatisfy(\.isValid)
            && speed.isFinite && speed > 0 && speed < 400
            && Self.travelModes.contains(travelMode) && Self.loopModes.contains(loopMode)
    }

    // Lenient decoding so a newer or older iPhone build still loads.
    enum CodingKeys: String, CodingKey {
        case waypoints, followRoads, travelMode, loopMode, speed, realistic, timeOfDayTraffic, name
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waypoints = (try? c.decode([Waypoint].self, forKey: .waypoints)) ?? []
        followRoads = (try? c.decode(Bool.self, forKey: .followRoads)) ?? false
        travelMode = (try? c.decode(String.self, forKey: .travelMode)) ?? "walking"
        loopMode = (try? c.decode(String.self, forKey: .loopMode)) ?? "once"
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.4
        realistic = (try? c.decode(Bool.self, forKey: .realistic)) ?? true
        timeOfDayTraffic = (try? c.decode(Bool.self, forKey: .timeOfDayTraffic)) ?? false
        name = try? c.decodeIfPresent(String.self, forKey: .name)
    }
}

public struct DeviceSummary: Codable, Sendable, Equatable {
    public var name: String
    public var model: String
    public var iosVersion: String
    /// "usb" or "network".
    public var connection: String

    public init(name: String, model: String, iosVersion: String, connection: String) {
        self.name = name
        self.model = model
        self.iosVersion = iosVersion
        self.connection = connection
    }
}

public enum SpoofPhase: String, Codable, Sendable, Equatable {
    case idle
    case starting
    case active
    case reconnecting
    case stopping
    case failed
}

public struct RemoteStatus: Codable, Sendable, Equatable {
    /// The Mac can see the iPhone it controls (over USB or the network).
    public var connected: Bool
    /// A simulated location is being held, or being re-established.
    public var spoofing: Bool
    public var latitude: Double?
    public var longitude: Double?
    public var placeName: String?
    public var phase: SpoofPhase
    /// Human-readable progress or error text for the current phase.
    public var detail: String?
    public var device: DeviceSummary?
    /// "Live" or "Classic".
    public var engine: String?
    public var serverName: String

    public init(connected: Bool, spoofing: Bool, latitude: Double? = nil, longitude: Double? = nil,
                placeName: String? = nil, phase: SpoofPhase, detail: String? = nil,
                device: DeviceSummary? = nil, engine: String? = nil, serverName: String) {
        self.connected = connected
        self.spoofing = spoofing
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.phase = phase
        self.detail = detail
        self.device = device
        self.engine = engine
        self.serverName = serverName
    }
}

public struct APIError: Codable, Sendable, Equatable, Error {
    public var error: String

    public init(_ error: String) {
        self.error = error
    }
}
