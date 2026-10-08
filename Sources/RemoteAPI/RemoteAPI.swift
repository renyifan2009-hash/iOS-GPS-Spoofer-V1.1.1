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
