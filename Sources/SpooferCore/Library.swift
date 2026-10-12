import Foundation

/// A named place: a favorite, or an entry in the recent-locations history.
public struct SavedPlace: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var latitude: Double
    public var longitude: Double
    public var created: Date

    public init(id: UUID = UUID(), name: String, point: GeoPoint, created: Date = Date()) {
        self.id = id
        self.name = name
        self.latitude = point.latitude
        self.longitude = point.longitude
        self.created = created
    }

    public var point: GeoPoint {
        get { GeoPoint(latitude, longitude) }
        set { latitude = newValue.latitude; longitude = newValue.longitude }
    }
}

/// How a road-following route is computed.
public enum TravelMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case walking, driving

    public var id: String { rawValue }
    public var label: String { self == .walking ? "Walking" : "Driving" }
    public var symbolName: String { self == .walking ? "figure.walk" : "car.fill" }
}

/// A saved, re-playable route.
public struct SavedRoute: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var waypoints: [GeoPoint]
    public var followRoads: Bool
    public var travelMode: TravelMode
    public var loopMode: LoopMode
    /// Pace, in metres per second.
    public var speed: Double
    /// Seconds to wait at each waypoint (nil: no waits).
    public var waits: [Double]?
    public var created: Date

    public init(id: UUID = UUID(), name: String, waypoints: [GeoPoint], followRoads: Bool = false,
                travelMode: TravelMode = .walking, loopMode: LoopMode = .once, speed: Double = 1.4,
                waits: [Double]? = nil, created: Date = Date()) {
        self.id = id
        self.name = name
        self.waypoints = waypoints
        self.followRoads = followRoads
        self.travelMode = travelMode
        self.loopMode = loopMode
        self.speed = speed
        self.waits = waits
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, name, waypoints, followRoads, travelMode, loopMode, speed, waits, created
    }

    // Lenient decoding so files written by newer/older builds still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decode(String.self, forKey: .name)) ?? "Route"
        waypoints = (try? c.decode([GeoPoint].self, forKey: .waypoints)) ?? []
        followRoads = (try? c.decode(Bool.self, forKey: .followRoads)) ?? false
        travelMode = (try? c.decode(TravelMode.self, forKey: .travelMode)) ?? .walking
        loopMode = (try? c.decode(LoopMode.self, forKey: .loopMode)) ?? .once
        speed = (try? c.decode(Double.self, forKey: .speed)) ?? 1.4
        waits = try? c.decodeIfPresent([Double].self, forKey: .waits)
        created = (try? c.decode(Date.self, forKey: .created)) ?? Date()
    }
}

/// Everything the user has saved, persisted as one JSON file.
public struct LibraryData: Codable, Sendable, Equatable {
    public var version: Int = 1
    public var favorites: [SavedPlace] = []
    public var recents: [SavedPlace] = []
    public var routes: [SavedRoute] = []

    public init(favorites: [SavedPlace] = [], recents: [SavedPlace] = [], routes: [SavedRoute] = []) {
        self.favorites = favorites
        self.recents = recents
        self.routes = routes
    }

    enum CodingKeys: String, CodingKey { case version, favorites, recents, routes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        favorites = (try? c.decode([SavedPlace].self, forKey: .favorites)) ?? []
        recents = (try? c.decode([SavedPlace].self, forKey: .recents)) ?? []
        routes = (try? c.decode([SavedRoute].self, forKey: .routes)) ?? []
    }

    public static let maxRecents = 25

    /// Record a visit, de-duplicating anything within ~25 m and capping the list.
    public mutating func recordRecent(_ place: SavedPlace) {
        recents.removeAll { Geo.distance($0.point, place.point) < 25 }
        recents.insert(place, at: 0)
        if recents.count > Self.maxRecents { recents.removeLast(recents.count - Self.maxRecents) }
    }

    public func favorite(near point: GeoPoint, within metres: Double = 15) -> SavedPlace? {
        favorites.first { Geo.distance($0.point, point) < metres }
    }

    /// Case-insensitive lookup by name (exact match first, then prefix).
    public func favorite(named name: String) -> SavedPlace? {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return favorites.first { $0.name.lowercased() == key }
            ?? favorites.first { $0.name.lowercased().hasPrefix(key) }
    }
}

public enum LibraryFile {
    /// `~/Library/Application Support/AnyWhere/library.json`
    public static var defaultURL: URL {
        AppSupport.directory.appendingPathComponent("library.json")
    }

    /// Never throws: a missing file is an empty library, and an unreadable one
    /// is moved aside (so it isn't overwritten) and treated as empty.
    public static func load(from url: URL = defaultURL) -> LibraryData {
        guard let data = try? Data(contentsOf: url) else { return LibraryData() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LibraryData.self, from: data)
        } catch {
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return LibraryData()
        }
    }

    public static func save(_ library: LibraryData, to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(library).write(to: url, options: .atomic)
    }
}

public enum AppSupport {
    /// The folder inside Application Support, named after the product.
    public static let folderName = "AnyWhere"
    /// What the folder was called before the product became AnyWhere.
    public static let legacyFolderName = "iOS GPS Spoofer"

    private static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    }

    /// The app's support directory (created on demand by writers). The first time anything
    /// asks for it, saved places and routes from the old folder are copied in.
    public static var directory: URL {
        _ = migrationDone
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The old folder. Read-only from here: nothing is ever deleted from it.
    public static var legacyDirectory: URL {
        base.appendingPathComponent(legacyFolderName, isDirectory: true)
    }

    /// The Python environment holding pymobiledevice3, as installed by
    /// `setup.sh` (and by the app's own installer).
    public static var helperEnvironment: URL {
        directory.appendingPathComponent("venv", isDirectory: true)
    }

    /// The environment an earlier version installed under the old folder's name. Still
    /// usable (and tried after the new one), so updating the app never leaves it without
    /// its helper.
    public static var legacyHelperEnvironment: URL {
        legacyDirectory.appendingPathComponent("venv", isDirectory: true)
    }

    private static let migrationDone: Void = {
        _ = migrateLegacyData(from: legacyDirectory, to: base.appendingPathComponent(folderName, isDirectory: true))
    }()

    /// Items that are rebuilt rather than copied: a Python environment keeps absolute paths
    /// to where it was made, so a copied one would not work.
    static let notMigrated: Set<String> = ["venv", "helpers"]

    /// Copy what the old folder holds (saved places, routes, the remote's pairing) into the
    /// new one. Copies only what is missing, never overwrites, never deletes, and never
    /// throws: a file that can't be copied is skipped. Returns the names it copied.
    @discardableResult
    static func migrateLegacyData(from legacy: URL, to new: URL, fileManager fm: FileManager = .default) -> [String] {
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: legacy.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let names = try? fm.contentsOfDirectory(atPath: legacy.path) else { return [] }
        var copied: [String] = []
        for name in names.sorted() where !notMigrated.contains(name) {
            let source = legacy.appendingPathComponent(name)
            let destination = new.appendingPathComponent(name)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            do {
                try fm.createDirectory(at: new, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
                copied.append(name)
            } catch {
                continue
            }
        }
        return copied
    }
}
