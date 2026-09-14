import Foundation
@preconcurrency import Network
import Observation

@MainActor @Observable
final class LANSyncCoordinator {
    enum Status: Equatable {
        case stopped
        case searching
        case hosting
        case ready
        case syncing
        case error(String)

        var label: String {
            switch self {
            case .stopped: return "未启动"
            case .searching: return "搜索 Mac"
            case .hosting: return "等待连接"
            case .ready: return "可同步"
            case .syncing: return "同步中…"
            case .error(let message): return message
            }
        }
    }

    struct Peer: Identifiable, Equatable {
        let id: String
        let name: String
        fileprivate let endpoint: NWEndpoint

        static func == (lhs: Peer, rhs: Peer) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name
        }
    }

    private let role: LANSyncRole
    private let preferences: SharedPreferencesSync
    private let dataStore: LANSyncDataStore
    private let defaults: UserDefaults
    private let deviceID: String
    private let deviceName: String
    private let queue = DispatchQueue(label: "com.uozi.uTerm.lan-sync")
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var discovered: [String: Peer] = [:]

    private static let deviceIDKey = "lanSync.deviceID"
    private static let hostPairingCodeKey = "lanSync.hostPairingCode"
    private static let didCompleteInitialSyncKey = "lanSync.didCompleteInitialSync"

    private(set) var status: Status = .stopped
    private(set) var lastSyncedAt: Date?
    private(set) var pairingCode: String

    var peers: [Peer] {
        discovered.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(role: LANSyncRole,
         preferences: SharedPreferencesSync,
         dataStore: LANSyncDataStore,
         defaults: UserDefaults = .standard) {
        self.role = role
        self.preferences = preferences
        self.dataStore = dataStore
        self.defaults = defaults
        let existingID = defaults.string(forKey: Self.deviceIDKey)
        let id = existingID ?? UUID().uuidString
        if existingID == nil { defaults.set(id, forKey: Self.deviceIDKey) }
        deviceID = id
        deviceName = ProcessInfo.processInfo.hostName

        if role == .host {
            let code = defaults.string(forKey: Self.hostPairingCodeKey) ?? Self.makePairingCode()
            defaults.set(code, forKey: Self.hostPairingCodeKey)
            pairingCode = code
        } else {
            pairingCode = ""
        }
    }

    func start() {
        stop()
        switch role {
        case .host: startHosting()
        case .client: startSearching()
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        discovered.removeAll()
        status = .stopped
    }

    func syncNow(pairingCode: String) {
        guard role == .client else { return }
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            status = .error("请输入 6 位配对码")
            return
        }
        guard let peer = peers.first else {
            status = .error("未发现 Mac，请确认两端在同一局域网")
            return
        }

        status = .syncing
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let connection else { return }
            Task { @MainActor [weak self] in
                self?.sendSyncRequest(on: connection, pairingCode: code)
            }
        }
        connection.start(queue: queue)
    }

    private func startHosting() {
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: deviceName, type: LANSyncConstants.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.status = .hosting
                    case .failed(let error): self.status = .error(error.localizedDescription)
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    private func startSearching() {
        let browser = NWBrowser(
            for: .bonjour(type: LANSyncConstants.serviceType, domain: nil),
            using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready, .setup: self.status = .searching
                case .failed(let error): self.status = .error(error.localizedDescription)
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.updatePeers(results)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
        status = .searching
    }

    private func updatePeers(_ results: Set<NWBrowser.Result>) {
        var next: [String: Peer] = [:]
        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else { continue }
            let id = "\(name).\(type).\(domain)"
            next[id] = Peer(id: id, name: name, endpoint: result.endpoint)
        }
        discovered = next
        if !next.isEmpty, status == .searching { status = .ready }
    }

    private func accept(_ connection: NWConnection) {
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let connection else { return }
            Task { @MainActor [weak self] in
                self?.receiveRequest(from: connection)
            }
        }
        connection.start(queue: queue)
    }

    private func sendSyncRequest(on connection: NWConnection, pairingCode: String) {
        let coordinator = self
        let isInitial = !defaults.bool(forKey: Self.didCompleteInitialSyncKey)
        let request = LANSyncRequest(
            version: LANSyncConstants.protocolVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            pairingCode: pairingCode,
            preferences: isInitial ? [] : preferences.lanSnapshot(),
            data: nil)
        do {
            let data = try encoder.encode(request)
            LANSyncTransport.send(data, on: connection) { [weak coordinator, weak connection] error in
                guard let connection else { return }
                if let error {
                    Task { @MainActor [weak coordinator] in coordinator?.finish(error: error) }
                    return
                }
                let reader = LANSyncLineReader()
                reader.receive(from: connection) { [weak coordinator, weak connection] result in
                    guard let connection else { return }
                    Task { @MainActor [weak coordinator] in
                        switch result {
                        case .success(let data): coordinator?.handleResponse(data, on: connection)
                        case .failure(let error): coordinator?.finish(error: error)
                        }
                    }
                }
            }
        } catch {
            finish(error: error)
        }
    }

    private func receiveRequest(from connection: NWConnection) {
        let coordinator = self
        let reader = LANSyncLineReader()
        reader.receive(from: connection) { [weak coordinator, weak connection] result in
            guard let connection else { return }
            Task { @MainActor [weak coordinator] in
                switch result {
                case .success(let data): coordinator?.handleRequest(data, on: connection)
                case .failure(let error): coordinator?.close(connection, error: error)
                }
            }
        }
    }

    private func handleRequest(_ data: Data, on connection: NWConnection) {
        do {
            let request = try decoder.decode(LANSyncRequest.self, from: data)
            guard request.version == LANSyncConstants.protocolVersion else {
                try send(LANSyncResponse(version: LANSyncConstants.protocolVersion,
                                         accepted: false,
                                         message: "协议版本不兼容",
                                         preferences: [], data: nil), on: connection)
                return
            }
            guard request.pairingCode == pairingCode else {
                try send(LANSyncResponse(version: LANSyncConstants.protocolVersion,
                                         accepted: false,
                                         message: "配对码不正确",
                                         preferences: [], data: nil), on: connection)
                return
            }
            _ = preferences.mergeLANSnapshot(request.preferences)
            let data = try dataStore.snapshot()
            try send(LANSyncResponse(version: LANSyncConstants.protocolVersion,
                                     accepted: true,
                                     message: "同步完成",
                                     preferences: preferences.lanSnapshot(),
                                     data: data), on: connection)
        } catch {
            close(connection, error: error)
        }
    }

    private func handleResponse(_ data: Data, on connection: NWConnection) {
        do {
            let response = try decoder.decode(LANSyncResponse.self, from: data)
            guard response.accepted else {
                finish(error: LANSyncTransportError.connectionFailed(response.message))
                return
            }
            _ = preferences.mergeLANSnapshot(response.preferences)
            if let data = response.data {
                try dataStore.replace(with: data)
            }
            defaults.set(true, forKey: Self.didCompleteInitialSyncKey)
            lastSyncedAt = Date()
            status = .ready
            connection.cancel()
            release(connection)
        } catch {
            finish(error: error)
        }
    }

    private func send(_ response: LANSyncResponse, on connection: NWConnection) throws {
        let data = try encoder.encode(response)
        LANSyncTransport.send(data, on: connection) { [weak self, weak connection] error in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                if let error { self?.close(connection, error: error) }
                else { connection.cancel(); self?.release(connection) }
            }
        }
    }

    private func finish(error: Error) {
        status = .error(error.localizedDescription)
        lastSyncedAt = nil
    }

    private func close(_ connection: NWConnection, error: Error) {
        AppLogger.warn("LAN sync connection closed: \(error.localizedDescription)", category: "sync")
        connection.cancel()
        release(connection)
    }

    private func retain(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
    }

    private func release(_ connection: NWConnection) {
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
