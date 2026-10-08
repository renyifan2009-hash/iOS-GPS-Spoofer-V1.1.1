import Foundation
@preconcurrency import Network
import Observation
import os
import RemoteAPI
import UIKit

/// Finds the Mac over Bonjour, pairs with it, and sends it commands.
///
/// iOS has no public API that lets an app change the location the whole
/// system reports. The Mac does that through Apple's developer location
/// service (the same one Xcode uses); this app is the remote control.
@MainActor
@Observable
final class ConnectionManager {
    struct DiscoveredMac: Identifiable, Hashable, Sendable {
        let serviceName: String
        let type: String
        let domain: String
        let serverID: String?
        let displayName: String
        let addresses: [String]
        let port: UInt16?

        var id: String { "\(serviceName).\(domain)" }
    }

    struct Server: Codable, Equatable, Sendable {
        var serverID: String
        var name: String
        var host: String
        var port: UInt16
    }

    enum Link: Equatable {
        case unpaired
        case connecting
        case online
        case offline(String)
    }

    enum ClientError: LocalizedError {
        case notPaired
        case http(Int, String)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .notPaired: return "Pair with your Mac first."
            case .http(_, let message): return message
            case .message(let message): return message
            }
        }
    }

    private(set) var discovered: [DiscoveredMac] = []
    private(set) var server: Server?
    private(set) var link: Link = .unpaired
    private(set) var status: RemoteStatus?
    private(set) var isWorking = false
    var lastError: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let clientID: String
    @ObservationIgnored private var failures = 0

    private static let serverKey = "pairedServer"
    private static let clientIDKey = "clientID"

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Self.clientIDKey) {
            clientID = id
        } else {
            let id = UUID().uuidString
            defaults.set(id, forKey: Self.clientIDKey)
            clientID = id
        }
        if let data = defaults.data(forKey: Self.serverKey),
           let saved = try? JSONDecoder().decode(Server.self, from: data),
           KeychainStore.token(for: saved.serverID) != nil {
            server = saved
            link = .connecting
        }
    }

    var isPaired: Bool { server != nil }
    var isOnline: Bool { link == .online }
    /// A location is being held (or re-established) on the iPhone.
    var isSpoofing: Bool { status?.spoofing ?? false }

    // MARK: - Discovery

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: RemoteAPI.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            // Started on the main queue below.
            MainActor.assumeIsolated {
                self?.discovered = results.compactMap { Self.mac(from: $0) }
                    .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state {
                    self?.lastError = "Couldn't look for Macs: \(error.localizedDescription)"
                    self?.browser?.cancel()
                    self?.browser = nil
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    private static func mac(from result: NWBrowser.Result) -> DiscoveredMac? {
        guard case let .service(name, type, domain, _) = result.endpoint else { return nil }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = result.metadata { txt = record.dictionary }
        let addresses = (txt[RemoteAPI.TXTKey.addresses] ?? "")
            .split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
        return DiscoveredMac(serviceName: name, type: type, domain: domain,
                             serverID: txt[RemoteAPI.TXTKey.serverID],
                             displayName: txt[RemoteAPI.TXTKey.name] ?? name,
                             addresses: addresses,
                             port: txt[RemoteAPI.TXTKey.port].flatMap { UInt16($0) })
    }

    func isPaired(with mac: DiscoveredMac) -> Bool {
        guard let server, let id = mac.serverID else { return false }
        return server.serverID == id
    }

    /// A Bonjour service → an IPv4 address and port (falling back to the
    /// addresses the Mac lists in its TXT record).
    private func resolve(_ mac: DiscoveredMac) async -> (host: String, port: UInt16)? {
        let endpoint = NWEndpoint.service(name: mac.serviceName, type: mac.type, domain: mac.domain, interface: nil)
        if let resolved = await Self.resolveIPv4(endpoint) {
            return (resolved.0, resolved.1)
        }
        if let port = mac.port, let host = mac.addresses.first {
            return (host, port)
        }
        return nil
    }

    nonisolated private static func resolveIPv4(_ endpoint: NWEndpoint) async -> (String, UInt16)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(String, UInt16)?, Never>) in
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable ((String, UInt16)?) -> Void = { result in
                let first = resumed.withLock { (done: inout Bool) -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                guard first else { return }
                connection.cancel()
                continuation.resume(returning: result)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        finish((hostString(host), port.rawValue))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) { finish(nil) }
        }
    }

    nonisolated private static func hostString(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address):
            return address.rawValue.map { String($0) }.joined(separator: ".")
        case .ipv6(let address):
            return "[\("\(address)".replacingOccurrences(of: "%", with: "%25"))]"
        case .name(let name, _):
            return name
        @unknown default:
            return "\(host)"
        }
    }

    // MARK: - Pairing

    func pair(with mac: DiscoveredMac, code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        guard let target = await resolve(mac) else {
            lastError = "Couldn't reach \(mac.displayName). Make sure the iPhone and the Mac are on the same network."
            return false
        }
        return await pair(host: target.host, port: target.port, code: code)
    }

    func pair(host: String, port: UInt16, code: String) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        lastError = nil
        do {
            let request = PairRequest(code: code, clientName: UIDevice.current.name, clientID: clientID)
            let body = try RemoteAPI.makeEncoder().encode(request)
            let data = try await send("POST", RemoteAPI.Path.pair, body: body, host: host, port: port, authorized: false)
            let response = try RemoteAPI.makeDecoder().decode(PairResponse.self, from: data)
            guard KeychainStore.save(token: response.token, for: response.server.serverID) else {
                lastError = "Couldn't save the pairing to the Keychain."
                return false
            }
            let paired = Server(serverID: response.server.serverID, name: response.server.name, host: host, port: port)
            server = paired
            persist(paired)
            link = .connecting
            failures = 0
            startPolling()
            return true
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    func unpair() async {
        if server != nil {
            _ = try? await send("POST", RemoteAPI.Path.unpair)
        }
        forget()
    }

    private func forget() {
        if let server { KeychainStore.delete(for: server.serverID) }
        server = nil
        status = nil
        link = .unpaired
        UserDefaults.standard.removeObject(forKey: Self.serverKey)
        stopPolling()
    }

    private func persist(_ server: Server) {
        if let data = try? JSONEncoder().encode(server) {
            UserDefaults.standard.set(data, forKey: Self.serverKey)
        }
    }

    // MARK: - Status

    func startPolling() {
        guard server != nil else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let delay: Duration = self.link == .online ? .seconds(2) : .seconds(4)
                try? await Task.sleep(for: delay)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard server != nil else { return }
        do {
            let data = try await send("GET", RemoteAPI.Path.status)
            let fresh = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
            if fresh != status { status = fresh }
            if link != .online { link = .online }
            failures = 0
        } catch ClientError.http(401, let message) {
            lastError = message
            forget()
        } catch {
            failures += 1
            if failures >= 2 { link = .offline(Self.describe(error)) }
            if failures == 2 || failures % 5 == 0 { await rediscover() }
        }
    }

    /// The Mac's address changed (new DHCP lease, hotspot): find it again by
    /// its server ID.
    private func rediscover() async {
        guard let current = server,
              let mac = discovered.first(where: { $0.serverID == current.serverID }),
              let target = await resolve(mac),
              target.host != current.host || target.port != current.port else { return }
        var updated = current
        updated.host = target.host
        updated.port = target.port
        server = updated
        persist(updated)
    }

    // MARK: - Commands

    @discardableResult
    func start(at location: LocationRequest) async -> Bool {
        await command(RemoteAPI.Path.start, location)
    }

    @discardableResult
    func move(to location: LocationRequest) async -> Bool {
        await command(RemoteAPI.Path.location, location)
    }

    @discardableResult
    func stop() async -> Bool {
        await command(RemoteAPI.Path.stop, nil)
    }

    private func command(_ path: String, _ location: LocationRequest?) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let body = try location.map { try RemoteAPI.makeEncoder().encode($0) }
            let data = try await send("POST", path, body: body)
            status = try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data)
            link = .online
            failures = 0
            lastError = nil
            return true
        } catch ClientError.http(401, let message) {
            lastError = message
            forget()
            return false
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    // MARK: - HTTP

    private func send(_ method: String, _ path: String, body: Data? = nil,
                      host: String? = nil, port: UInt16? = nil, authorized: Bool = true) async throws -> Data {
        guard let host = host ?? server?.host, let port = port ?? server?.port else {
            throw ClientError.notPaired
        }
        guard let url = URL(string: "http://\(host):\(port)\(path)") else {
            throw ClientError.message("“\(host)” isn't a valid address.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let server, let token = KeychainStore.token(for: server.serverID) else {
                throw ClientError.notPaired
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.message("The Mac didn't answer.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? RemoteAPI.makeDecoder().decode(APIError.self, from: data))?.error
                ?? "The Mac answered with error \(http.statusCode)."
            throw ClientError.http(http.statusCode, message)
        }
        return data
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed:
                return "Can't reach the Mac. Check that the helper is running and both are on the same network."
            default:
                return urlError.localizedDescription
            }
        }
        if let clientError = error as? ClientError {
            return clientError.errorDescription ?? "Something went wrong."
        }
        return error.localizedDescription
    }
}
