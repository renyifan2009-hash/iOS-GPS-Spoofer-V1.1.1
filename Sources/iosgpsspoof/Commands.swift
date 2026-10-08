import ArgumentParser
import Foundation
import SpooferCore
#if canImport(CoreLocation)
import CoreLocation
#endif

// MARK: - spoof

struct Spoof: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Hold the device at a fixed location until stopped.",
        discussion: """
            Examples:
              iosgpsspoof spoof 48.8584 2.2945
              iosgpsspoof spoof "48°51'30\\"N 2°17'40\\"E"
              iosgpsspoof spoof "https://maps.apple.com/?ll=48.8584,2.2945"
              iosgpsspoof spoof @Home                 (a favorite saved in the app)
              iosgpsspoof spoof "Eiffel Tower, Paris" (looked up with Apple's geocoder)
            """
    )

    @OptionGroup var common: CommonOptions

    @Argument(parsing: .allUnrecognized,
              help: "Where to go: LAT LON, \"lat,lon\", DMS, a maps link, @Favorite, or a place name.")
    var location: [String] = []

    @Option(name: .customLong("retry-interval"), help: "Seconds to wait before re-establishing after a drop.")
    var retryInterval: Double = 5

    @Flag(name: .customLong("no-clear-on-exit"),
          help: "Leave the simulated location in place when the tool exits.")
    var noClearOnExit: Bool = false

    func run() throws {
        let (target, label) = try resolveLocation(location)
        let ctx = try common.makeContext()
        try Supervisor(
            ctx: ctx,
            childArgs: ctx.setArguments(target),
            describe: label,
            retryInterval: retryInterval,
            clearOnExit: !noClearOnExit,
            holdAfterSuccessfulExit: ctx.device.isLegacy
        ).run()
    }
}

// MARK: - route

struct Route: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Move the device along a route — a GPX/KML file, or a list of waypoints.",
        discussion: """
            Examples:
              iosgpsspoof route ./walk.gpx                       (keeps the file's own timing)
              iosgpsspoof route ./drive.kml --speed 50 --loop
              iosgpsspoof route 48.8584,2.2945 48.8606,2.3376 --speed 5
              iosgpsspoof route @Home @Work --duration 25m --ping-pong

            Without --speed/--duration, a timestamped GPX track replays at its recorded
            pace; anything else moves at 5 km/h. The device stays at the destination
            until you press Ctrl-C (unless --loop or --ping-pong).
            """
    )

    @OptionGroup var common: CommonOptions

    @Argument(parsing: .allUnrecognized,
              help: "A .gpx/.kml file, or two or more waypoints (each \"lat,lon\", a link, or @Favorite).")
    var inputs: [String] = []

    @Option(name: .customLong("speed"), help: "Speed in km/h.")
    var speed: Double?

    @Option(name: .customLong("duration"), help: "Time for one pass, e.g. 90, 1:30, 2h, 25m, 1h30m.")
    var duration: String?

    @Flag(name: .customLong("loop"), help: "Return to the start and go round again, forever.")
    var loop: Bool = false

    @Flag(name: .customLong("ping-pong"), help: "Turn around at each end and retrace the route, forever.")
    var pingPong: Bool = false

    @Option(name: .customLong("timing-randomness"), help: "Jitter (ms) added between points for realism.")
    var timingRandomness: Int = 0

    @Flag(name: .customLong("no-clear-on-exit"),
          help: "Leave the simulated location in place when the tool exits.")
    var noClearOnExit: Bool = false

    func validate() throws {
        if loop && pingPong { throw ValidationError("--loop and --ping-pong are mutually exclusive") }
        if speed != nil && duration != nil { throw ValidationError("give --speed or --duration, not both") }
        if let speed, !(0.01...2000).contains(speed) { throw ValidationError("--speed must be between 0.01 and 2000 km/h") }
        if inputs.isEmpty { throw ValidationError("give a GPX/KML file or at least two waypoints") }
    }

    func run() throws {
        let loopMode: LoopMode = pingPong ? .pingPong : (loop ? .loop : .once)
        var imported: ImportedRoute?
        var sourceFile: URL?
        let points: [GeoPoint]

        if inputs.count == 1, FileManager.default.fileExists(atPath: (inputs[0] as NSString).expandingTildeInPath) {
            let url = URL(fileURLWithPath: (inputs[0] as NSString).expandingTildeInPath)
            let route = try RouteImporter.load(contentsOf: url)
            guard route.points.count >= 2 else { throw SpoofError("the file has fewer than 2 points") }
            imported = route
            sourceFile = url
            points = route.points
        } else {
            guard inputs.count >= 2 else {
                throw SpoofError("no such file: \(inputs.first ?? "")  (or give at least two waypoints)")
            }
            points = try inputs.map { try resolveLocation([$0]).0 }
        }

        let path = RoutePath(points)
        let ctx = try common.makeContext()
        let gpxPath: String
        var temporary: URL?
        let summary: String

        if speed == nil, duration == nil, loopMode == .once, let imported, imported.duration != nil,
           let sourceFile, sourceFile.pathExtension.lowercased() == "gpx" {
            // Replay the recorded track as-is.
            gpxPath = sourceFile.path
            summary = "\(Format.distance(path.length)) at the recorded pace (\(Format.duration(imported.duration ?? 0)))"
        } else {
            let lapLength = RoutePlayback(path: path, loopMode: loopMode).cycleLength
            let oneWay = loopMode == .pingPong ? lapLength / 2 : lapLength
            let metresPerSecond: Double
            if let speed {
                metresPerSecond = speed / 3.6
            } else if let duration {
                guard let seconds = parseDuration(duration), seconds > 0, seconds < 1e9 else {
                    throw ValidationError("could not read --duration \"\(duration)\"")
                }
                metresPerSecond = max(0.01, oneWay / seconds)
            } else {
                metresPerSecond = imported?.averageSpeed ?? (5 / 3.6)
            }
            let track = try RouteBuilder.timedTrack(path: path, speed: metresPerSecond, loopMode: loopMode)
            let url = try RouteBuilder.writeGPX(track, name: imported?.name ?? "iosgpsspoof route")
            temporary = url
            gpxPath = url.path
            let pass = Format.duration(oneWay / metresPerSecond)
            summary = "\(Format.distance(oneWay)) at \(Format.speed(metresPerSecond)) (\(pass) per pass"
                + (loopMode == .once ? ")" : ", \(loopMode.label.lowercased()))")
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        log("route: \(summary)")
        try Supervisor(
            ctx: ctx,
            childArgs: ctx.playArguments(gpxPath, timingRandomness: timingRandomness),
            describe: "route — \(summary)",
            retryInterval: 3,
            clearOnExit: !noClearOnExit,
            holdAfterSuccessfulExit: true
        ).run()
    }
}

// MARK: - list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List paired iOS devices.")

    @Option(name: .customLong("python-path"), help: "Path to the pymobiledevice3 executable.")
    var pythonPath: String?

    @Flag(name: .customLong("json"), help: "Print JSON (pymobiledevice3's field names).")
    var json: Bool = false

    func run() throws {
        let pmd = try Pymobiledevice3.resolve(explicit: pythonPath)
        let devices = try pmd.listDevices()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(devices), as: UTF8.self))
            return
        }
        if devices.isEmpty {
            print("No paired devices found. Connect an iPhone with a data cable, unlock it and tap Trust.")
            return
        }
        for d in devices {
            print("\(d.udid)  \(d.summary)")
        }
    }
}

// MARK: - clear

struct ClearCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear any simulated location and restore the device's real GPS."
    )

    @OptionGroup var common: CommonOptions

    func run() throws {
        let ctx = try common.makeContext()
        _ = try ctx.pmd.run(ctx.clearArguments, timeout: 90)
        log("real GPS restored on \(ctx.device.deviceName).")
    }
}

// MARK: - doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check pymobiledevice3, the live engine and connected devices."
    )

    @Option(name: .customLong("python-path"), help: "Path to the pymobiledevice3 executable.")
    var pythonPath: String?

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        var problems = 0
        func ok(_ s: String) { print("  ✓ \(s)") }
        func bad(_ s: String) { print("  ✗ \(s)"); problems += 1 }
        func note(_ s: String) { print("  • \(s)") }

        print("pymobiledevice3")
        let pmd: Pymobiledevice3
        do {
            pmd = try Pymobiledevice3.resolve(explicit: pythonPath)
        } catch {
            bad("not found — \(firstLine(error))")
            print("\nInstall it with ./setup.sh (or `pipx install pymobiledevice3`).")
            throw ExitCode.failure
        }
        ok("found: \(pmd.displayPath)")
        if let version = pmd.version() { ok("version \(version)") } else { bad("could not run `pymobiledevice3 version`") }

        print("\nLive engine (instant moves, smooth routes, joystick)")
        let python = pmd.pythonInterpreter
        if let python { ok("Python: \(python.path)") }
        switch LiveHelper.probe(python: python) {
        case .supported(let version):
            ok("supported (pymobiledevice3 \(version))")
        case .unsupported(let reason):
            note("unavailable — the GUI will use the classic engine (\(reason))")
        }

        print("\nDevices")
        let devices: [Device]
        do { devices = try pmd.listDevices() } catch {
            bad("could not list devices: \(firstLine(error))")
            throw ExitCode.failure
        }
        if devices.isEmpty {
            bad("no paired devices — connect with a data cable, unlock the phone and tap Trust")
        }
        for d in devices {
            print("  \(d.deviceName) — \(d.modelName), iOS \(d.productVersion), \(d.connectionLabel)")
            print("    UDID \(d.udid)")
            if d.isLegacy { note("iOS \(d.majorVersion): uses the lockdown location service (no tunnel needed)") }
            if let status = try? pmd.run(["amfi", "developer-mode-status", "--udid", d.udid], timeout: 30) {
                let enabled = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if enabled == "true" { ok("Developer Mode enabled") }
                else if enabled == "false" { bad("Developer Mode is OFF — Settings ▸ Privacy & Security ▸ Developer Mode") }
            }
        }
        print(problems == 0 ? "\nAll good." : "\n\(problems) problem(s) found. See IPHONE-SETUP.md.")
        if problems > 0 { throw ExitCode.failure }
    }
}

// MARK: - dump-helper (used by CI to test the embedded live helper)

struct DumpHelper: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dump-helper",
        abstract: "Print the embedded live-location helper script.",
        shouldDisplay: false
    )

    func run() throws {
        FileHandle.standardOutput.write(Data(LiveHelper.script.utf8))
    }
}

// MARK: - helpers

/// Turn CLI tokens into a coordinate: numbers, any `Coordinate.parsePoint`
/// format, `@Favorite`, or (as a last resort) a geocoded place name.
func resolveLocation(_ tokens: [String]) throws -> (GeoPoint, String) {
    let text = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { throw ValidationError("give a location, e.g. `48.8584 2.2945`") }

    if text.hasPrefix("@") {
        let name = String(text.dropFirst())
        let library = LibraryFile.load()
        guard let place = library.favorite(named: name) else {
            let known = library.favorites.map(\.name).joined(separator: ", ")
            throw SpoofError("no favorite named \"\(name)\"" + (known.isEmpty ? " (none saved yet)" : ". Saved: \(known)"))
        }
        return (place.point, "\(place.name) (\(Format.coordinate(place.point)))")
    }

    if let point = Coordinate.parsePoint(text) {
        try Coordinate.validate(point)
        return (point, Format.coordinate(point, precision: 6))
    }

    #if canImport(CoreLocation)
    let (point, name) = try geocode(text)
    log("\"\(text)\" → \(name) (\(Format.coordinate(point)))")
    return (point, "\(name) (\(Format.coordinate(point)))")
    #else
    throw SpoofError("could not parse a coordinate from: \(text)")
    #endif
}

#if canImport(CoreLocation)
/// Forward-geocode with Apple's geocoder, spinning the run loop until it answers.
func geocode(_ query: String) throws -> (GeoPoint, String) {
    final class Box: @unchecked Sendable {
        var point: GeoPoint?
        var name = ""
        var error: String?
        var done = false
    }
    let box = Box()
    let geocoder = CLGeocoder()
    geocoder.geocodeAddressString(query) { placemarks, error in
        if let placemark = placemarks?.first, let location = placemark.location {
            box.point = GeoPoint(location.coordinate.latitude, location.coordinate.longitude)
            let parts = [placemark.name, placemark.locality, placemark.country].compactMap { $0 }
            var seen = Set<String>()
            box.name = parts.filter { seen.insert($0).inserted }.joined(separator: ", ")
        } else {
            box.error = error?.localizedDescription ?? "no match"
        }
        box.done = true
    }
    let deadline = Date().addingTimeInterval(20)
    while !box.done && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }
    guard box.done else {
        geocoder.cancelGeocode()
        throw SpoofError("timed out looking up \"\(query)\" (needs internet)")
    }
    guard let point = box.point else {
        throw SpoofError("could not find \"\(query)\": \(box.error ?? "no match"). Try coordinates instead.")
    }
    return (point, box.name.isEmpty ? query : box.name)
}
#endif

/// `90` (seconds), `1:30` (m:s), `1:02:03` (h:m:s), `2h`, `25m`, `1h30m`, `45s`.
func parseDuration(_ text: String) -> TimeInterval? {
    let t = text.trimmingCharacters(in: .whitespaces).lowercased()
    if let seconds = Double(t) { return seconds }
    if t.contains(":") {
        let parts = t.split(separator: ":").map { Double($0) }
        guard parts.allSatisfy({ $0 != nil }), (2...3).contains(parts.count) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
    var total = 0.0
    var number = ""
    var matchedUnit = false
    for c in t {
        if c.isNumber || c == "." {
            number.append(c)
        } else if let unit = ["h": 3600.0, "m": 60, "s": 1][String(c)], let value = Double(number) {
            total += value * unit
            number = ""
            matchedUnit = true
        } else if c != " " {
            return nil
        }
    }
    guard number.isEmpty, matchedUnit else { return nil }
    return total
}
