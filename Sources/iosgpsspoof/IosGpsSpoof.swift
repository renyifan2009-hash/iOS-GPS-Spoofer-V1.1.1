import ArgumentParser
import Foundation
import SpooferCore

extension ConnectionFilter: ExpressibleByArgument {}
extension Transport: ExpressibleByArgument {}

@main
struct IosGpsSpoof: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iosgpsspoof",
        abstract: "Spoof the GPS location of a connected iPhone for as long as the tool runs.",
        discussion: """
            Uses Apple's developer location-simulation service (the same one Xcode's
            "Simulate Location" uses), reached via pymobiledevice3 — over the CoreDevice
            tunnel on iOS 17+, or the lockdown service on iOS 16 and older. The fake
            location holds while this process runs and is cleared on exit. If the device
            disconnects and reconnects, the spoof is automatically re-established.

            Locations can be given as "lat,lon", degrees/minutes/seconds, a Google or
            Apple Maps link, "@Favorite" (saved in the app), or a place name.

            Requirements: the iPhone must be paired/trusted and have Developer Mode
            enabled (Settings > Privacy & Security > Developer Mode).
            Run `iosgpsspoof doctor` to check your setup.
            """,
        version: "2.0.0",
        subcommands: [Spoof.self, Route.self, List.self, ClearCmd.self, Doctor.self, DumpHelper.self],
        defaultSubcommand: Spoof.self
    )
}

/// Options shared by every subcommand that talks to a device.
struct CommonOptions: ParsableArguments {
    @Option(name: .customLong("udid"), help: "Target device UDID. Defaults to the first connected device.")
    var udid: String?

    @Option(name: .customLong("connection"), help: "Which link to use: any | usb | network.")
    var connection: ConnectionFilter = .any

    @Option(name: .customLong("transport"), help: "Tunnel transport (iOS 17+): native | tunneld | userspace. 'native' needs no root (macOS).")
    var transport: Transport = .native

    @Option(name: .customLong("python-path"), help: "Path to the pymobiledevice3 executable.")
    var pythonPath: String?
}

extension CommonOptions {
    func makeContext() throws -> Context {
        signal(SIGPIPE, SIG_IGN)
        let pmd = try Pymobiledevice3.resolve(explicit: pythonPath)
        let device = try pmd.selectDevice(udid: udid, connection: connection)
        return Context(pmd: pmd, device: device, transport: transport, connection: connection)
    }
}

struct Context {
    let pmd: Pymobiledevice3
    let device: Device
    let transport: Transport
    let connection: ConnectionFilter

    /// iOS 16 and older go through the lockdown service: no tunnel flags.
    private var simulateLocation: [String] {
        device.isLegacy ? ["developer", "simulate-location"] : ["developer", "dvt", "simulate-location"]
    }
    private var transportFlags: [String] {
        device.isLegacy ? [] : transport.flags(udid: device.udid)
    }

    func setArguments(_ p: GeoPoint) -> [String] {
        simulateLocation + ["set"] + transportFlags
            + ["--udid", device.udid, "--", String(p.latitude), String(p.longitude)]
    }

    var clearArguments: [String] {
        simulateLocation + ["clear"] + transportFlags + ["--udid", device.udid]
    }

    func playArguments(_ path: String, timingRandomness: Int) -> [String] {
        if device.isLegacy {
            // The lockdown variant takes the jitter as a required positional.
            return simulateLocation + ["play", "--udid", device.udid, path, String(timingRandomness)]
        }
        var args = simulateLocation + ["play"] + transportFlags + ["--udid", device.udid]
        if timingRandomness > 0 { args += ["--timing-randomness-range", String(timingRandomness)] }
        return args + [path]
    }

    func preflight() {
        if device.isLegacy {
            log("iOS \(device.productVersion): using the lockdown location service (no tunnel).")
        }
        do {
            _ = try pmd.run(["mounter", "auto-mount", "--udid", device.udid], timeout: 120)
        } catch {
            warn("could not auto-mount the DeveloperDiskImage (may already be mounted): \(firstLine(error))")
        }
    }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("warning: \(message)\n".utf8))
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

func firstLine(_ error: Error) -> String {
    let text = "\(error)"
    return text.split(separator: "\n").first.map(String.init) ?? text
}
