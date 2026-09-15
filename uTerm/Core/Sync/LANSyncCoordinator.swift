import Foundation
@preconcurrency import Network
import Observation

nonisolated private struct LANSyncClearHello: Codable, Sendable {
    let hello: LANSyncCryptoSession.Hello
}

@MainActor @Observable
final class LANSyncCoordinator {
    enum Status: Equatable {
        case stopped, searching, hosting, ready, waitingForConfirmation, syncing
        case error(String)

        var label: String {
            switch self {
            case .stopped: return "未启动"
            case .searching: return "搜索移动设备"
            case .hosting: return "等待同步请求"
            case .ready: return "可发送"
            case .waitingForConfirmation: return "等待移动端确认"
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

    @MainActor private final class ConnectionContext: @unchecked Sendable {
        let connection: NWConnection
        let reader = LANSyncFrameReader()
        let generation: Int
        var crypto: LANSyncCryptoSession?
        var nextSendSequence: UInt64 = 0
        var nextReceiveSequence: UInt64 = 0
        var payload: LANSyncFullSnapshot?
        var chunks: [LANSyncTransferChunk] = []
        var pendingOffer: LANSyncOffer?

        init(connection: NWConnection, generation: Int = 0) {
            self.connection = connection
            self.generation = generation
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
    private var connections: [ObjectIdentifier: ConnectionContext] = [:]
    private var discovered: [String: Peer] = [:]
    private var pendingConnectionID: ObjectIdentifier?
    private var syncGeneration = 0

    private static let deviceIDKey = "lanSync.deviceID"
    private static let hostPairingCodeKey = "lanSync.hostPairingCode"
    private static let mobilePairingCodeKey = "lanSync.pairingCode"

    private(set) var status: Status = .stopped
    private(set) var lastSyncedAt: Date?
    private(set) var pairingCode: String
    private(set) var pendingOffer: LANSyncOffer?

    var peers: [Peer] {
        discovered.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(role: LANSyncRole, preferences: SharedPreferencesSync, dataStore: LANSyncDataStore,
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

        switch role {
        case .sender:
            let code = defaults.string(forKey: Self.hostPairingCodeKey) ?? Self.makePairingCode()
            defaults.set(code, forKey: Self.hostPairingCodeKey)
            pairingCode = code
        case .receiver:
            pairingCode = defaults.string(forKey: Self.mobilePairingCodeKey) ?? ""
        }
    }

    func start() {
        stop()
        switch role {
        case .sender: startSearching()
        case .receiver: startHosting()
        }
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for context in connections.values { context.connection.cancel() }
        connections.removeAll()
        discovered.removeAll()
        pendingConnectionID = nil
        pendingOffer = nil
        status = .stopped
    }

    /// Mac-only entry point. The receiver never opens a connection or requests data.
    func sendSync(to peer: Peer? = nil) {
        guard role == .sender else { return }
        guard !pairingCode.isEmpty else { status = .error("配对码未生成"); return }
        guard let peer = peer ?? peers.first else {
            status = .error("未发现移动设备，请确认两端在同一局域网")
            return
        }
        syncGeneration += 1
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        let context = ConnectionContext(connection: connection, generation: syncGeneration)
        retain(context)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let connection else { return }
            Task { @MainActor [weak self] in self?.beginSenderHandshake(on: connection) }
        }
        connection.start(queue: queue)
        status = .waitingForConfirmation
        scheduleTimeout(for: context.generation, on: context)
    }

    func confirmPendingSync() { respondToPendingSync(accepted: true) }
    func rejectPendingSync() { respondToPendingSync(accepted: false) }

    func setPairingCode(_ code: String) {
        guard role == .receiver else { return }
        let normalized = String(code.filter(\.isNumber).prefix(6))
        pairingCode = normalized
        defaults.set(normalized, forKey: Self.mobilePairingCodeKey)
    }

    private func respondToPendingSync(accepted: Bool) {
        guard role == .receiver, let id = pendingConnectionID,
              let context = connections[id], let crypto = context.crypto else { return }
        do {
            try sendEncrypted(LANSyncDecision(accepted: accepted), type: "decision",
                              on: context, crypto: crypto)
            pendingOffer = nil
            pendingConnectionID = nil
            if accepted {
                status = .syncing
                receiveChunks(on: context)
            } else {
                status = .hosting
                close(context)
            }
        } catch { fail(context, error: error) }
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
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch { status = .error(error.localizedDescription) }
    }

    private func startSearching() {
        let browser = NWBrowser(for: .bonjour(type: LANSyncConstants.serviceType, domain: nil), using: .tcp)
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
            Task { @MainActor in self?.updatePeers(results) }
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
        let context = ConnectionContext(connection: connection)
        retain(context)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let connection else { return }
            Task { @MainActor [weak self] in self?.receiveClearHello(on: connection) }
        }
        connection.start(queue: queue)
    }

    private func beginSenderHandshake(on connection: NWConnection) {
        guard let context = context(for: connection) else { return }
        do {
            let crypto = LANSyncCryptoSession(deviceID: deviceID, deviceName: deviceName,
                                               pairingCode: pairingCode)
            context.crypto = crypto
            try sendClear(LANSyncClearHello(hello: crypto.hello), on: context)
            readFrame(on: context) { [weak self] data in
                guard let self else { return }
                do {
                    let remote = try self.decoder.decode(LANSyncClearHello.self, from: data).hello
                    var initiator = crypto
                    try initiator.establish(with: remote, initiator: true)
                    context.crypto = initiator
                    try self.sendOffer(on: context)
                } catch { self.fail(context, error: error) }
            }
        } catch { fail(context, error: error) }
    }

    private func receiveClearHello(on connection: NWConnection) {
        guard let context = context(for: connection) else { return }
        readFrame(on: context) { [weak self] data in
            guard let self else { return }
            do {
                let remote = try self.decoder.decode(LANSyncClearHello.self, from: data).hello
                guard !self.pairingCode.isEmpty else { throw LANSyncTransportError.authenticationFailed }
                let base = LANSyncCryptoSession(sessionID: remote.sessionID, deviceID: self.deviceID,
                                                 deviceName: self.deviceName, pairingCode: self.pairingCode)
                let responder = try base.respondingSession(to: remote, deviceID: self.deviceID,
                                                            deviceName: self.deviceName,
                                                            pairingCode: self.pairingCode)
                context.crypto = responder
                try self.sendClear(LANSyncClearHello(hello: responder.hello), on: context)
                self.receiveOffer(on: context)
            } catch { self.fail(context, error: error) }
        }
    }

    private func sendOffer(on context: ConnectionContext) throws {
        guard let crypto = context.crypto else { throw LANSyncTransportError.handshakeRequired }
        let payload = try dataStore.fullSnapshot(preferences: preferences.lanSnapshot())
        let chunks = try LANSyncDataStore.fittingSnapshots(payload.data, encoder: encoder)
        let offer = LANSyncOffer(
            sessionID: crypto.sessionID, deviceID: deviceID, deviceName: deviceName,
            recordCount: payload.recordCount, preferenceCount: payload.preferences.count,
            secretCount: payload.secretCount, chunkCount: max(1, chunks.count),
            digest: try LANSyncPayloadDigest.digest(payload, encoder: encoder),
            includesSensitiveData: true)
        context.payload = payload
        try sendEncrypted(offer, type: "offer", on: context, crypto: crypto)
        readDecision(on: context)
    }

    private func receiveOffer(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "offer") { [weak self] (offer: LANSyncOffer) in
            guard let self, offer.sessionID == context.crypto?.sessionID else {
                self?.fail(context, error: LANSyncTransportError.invalidMessage); return
            }
            context.pendingOffer = offer
            self.pendingConnectionID = ObjectIdentifier(context.connection)
            self.pendingOffer = offer
            self.status = .waitingForConfirmation
        }
    }

    private func readDecision(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "decision") { [weak self] (decision: LANSyncDecision) in
            guard let self else { return }
            guard decision.accepted else { self.fail(context, error: LANSyncTransportError.rejected); return }
            self.status = .syncing
            do { try self.sendChunks(on: context) } catch { self.fail(context, error: error) }
        }
    }

    private func sendChunks(on context: ConnectionContext) throws {
        guard let payload = context.payload, let crypto = context.crypto else {
            throw LANSyncTransportError.handshakeRequired
        }
        let pieces = try LANSyncDataStore.fittingSnapshots(payload.data, encoder: encoder)
        let snapshots = pieces.isEmpty ? [.empty] : pieces
        for (index, snapshot) in snapshots.enumerated() {
            let chunk = LANSyncTransferChunk(index: index, total: snapshots.count, data: snapshot,
                                              preferences: index == 0 ? payload.preferences : [],
                                              secrets: index == 0 ? payload.secrets : [])
            try sendEncrypted(chunk, type: "chunk", on: context, crypto: crypto)
        }
        try sendEncrypted(LANSyncTransferResult(succeeded: true, message: "发送完成", digest: nil),
                          type: "finish", on: context, crypto: crypto)
        readSenderResult(on: context)
    }

    private func receiveChunks(on context: ConnectionContext) {
        context.chunks.removeAll()
        readNextChunk(on: context)
    }

    private func readNextChunk(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "chunk") { [weak self] (chunk: LANSyncTransferChunk) in
            guard let self else { return }
            guard chunk.index == context.chunks.count,
                  chunk.total > 0, chunk.total <= LANSyncConstants.maxTotalBytes else {
                self.fail(context, error: LANSyncTransportError.invalidMessage); return
            }
            context.chunks.append(chunk)
            if context.chunks.count < chunk.total { self.readNextChunk(on: context) }
            else { self.readSenderFinish(on: context) }
        }
    }

    private func readSenderFinish(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "finish") { [weak self] (_: LANSyncTransferResult) in
            guard let self else { return }
            self.finishReceiverPayload(on: context)
        }
    }

    private func readSenderResult(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "result") { [weak self] (result: LANSyncTransferResult) in
            guard let self else { return }
            if result.succeeded {
                self.status = .ready
                self.lastSyncedAt = Date()
                self.close(context)
            } else {
                self.fail(context, error: LANSyncTransportError.connectionFailed(result.message))
            }
        }
    }

    private func finishReceiverPayload(on context: ConnectionContext) {
        do {
            guard let first = context.chunks.first, context.chunks.count == first.total else {
                throw LANSyncTransportError.invalidMessage
            }
            let payload = LANSyncFullSnapshot(
                data: LANSyncDataSnapshot(
                    profiles: context.chunks.flatMap { $0.data.profiles },
                    groups: context.chunks.flatMap { $0.data.groups },
                    knownHosts: context.chunks.flatMap { $0.data.knownHosts },
                    sshKeys: context.chunks.flatMap { $0.data.sshKeys },
                    providers: context.chunks.flatMap { $0.data.providers },
                    forwardingRules: context.chunks.flatMap { $0.data.forwardingRules },
                    quickCommands: context.chunks.flatMap { $0.data.quickCommands },
                    quickCommandRuns: context.chunks.flatMap { $0.data.quickCommandRuns },
                    chatSessions: context.chunks.flatMap { $0.data.chatSessions },
                    chatMessages: context.chunks.flatMap { $0.data.chatMessages }),
                preferences: first.preferences, secrets: first.secrets)
            guard let offer = context.pendingOffer,
                  try LANSyncPayloadDigest.digest(payload, encoder: encoder) == offer.digest else {
                throw LANSyncTransportError.invalidMessage
            }
            _ = try dataStore.replace(with: payload)
            _ = preferences.replaceFromLAN(payload.preferences)
            guard let crypto = context.crypto else { throw LANSyncTransportError.handshakeRequired }
            try sendEncrypted(LANSyncTransferResult(succeeded: true, message: "同步完成",
                                                     digest: offer.digest), type: "result",
                              on: context, crypto: crypto)
            status = .hosting
            lastSyncedAt = Date()
            close(context)
        } catch {
            let result = LANSyncTransferResult(succeeded: false, message: error.localizedDescription, digest: nil)
            if let crypto = context.crypto {
                try? sendEncrypted(result, type: "result", on: context, crypto: crypto)
            }
            fail(context, error: error)
        }
    }

    private func readFrame(on context: ConnectionContext,
                           completion: @escaping @MainActor @Sendable (Data) -> Void) {
        context.reader.readFrame(from: context.connection) { [weak self, weak context] result in
            guard let self, let context else { return }
            Task { @MainActor in
                switch result {
                case .success(let data): completion(data)
                case .failure(let error): self.fail(context, error: error)
                }
            }
        }
    }

    private func sendClear<T: Encodable>(_ value: T, on context: ConnectionContext) throws {
        let data = try encoder.encode(value)
        LANSyncTransport.send(data, on: context.connection) { [weak self, weak context] error in
            guard let self, let context, let error else { return }
            Task { @MainActor in self.fail(context, error: error) }
        }
    }

    private func sendEncrypted<T: Encodable>(_ value: T, type: String, on context: ConnectionContext,
                                             crypto: LANSyncCryptoSession) throws {
        let sequence = context.nextSendSequence
        context.nextSendSequence += 1
        let data = try crypto.encrypted(value, messageType: type, sequence: sequence, encoder: encoder)
        LANSyncTransport.send(data, on: context.connection) { [weak self, weak context] error in
            guard let self, let context, let error else { return }
            Task { @MainActor in self.fail(context, error: error) }
        }
    }

    private func readEncrypted<T: Decodable & Sendable>(
        on context: ConnectionContext, expectedType: String,
        completion: @escaping @MainActor @Sendable (T) -> Void
    ) {
        readFrame(on: context) { [weak self, weak context] data in
            guard let self, let context, let crypto = context.crypto else { return }
            do {
                let result = try crypto.decryptedBytes(data)
                guard result.messageType == expectedType,
                      result.sequence == context.nextReceiveSequence else {
                    throw LANSyncTransportError.invalidMessage
                }
                context.nextReceiveSequence += 1
                completion(try self.decoder.decode(T.self, from: result.bytes))
            } catch { self.fail(context, error: error) }
        }
    }

    private func scheduleTimeout(for generation: Int, on context: ConnectionContext) {
        Task { @MainActor [weak self, weak context] in
            try? await Task.sleep(for: .seconds(LANSyncConstants.syncTimeoutSeconds))
            guard let self, let context, self.syncGeneration == generation,
                  self.connections[ObjectIdentifier(context.connection)] != nil else { return }
            self.fail(context, error: LANSyncTransportError.connectionFailed("等待移动端响应超时"))
        }
    }

    private func context(for connection: NWConnection) -> ConnectionContext? {
        connections[ObjectIdentifier(connection)]
    }

    private func retain(_ context: ConnectionContext) {
        connections[ObjectIdentifier(context.connection)] = context
    }

    private func close(_ context: ConnectionContext) {
        context.connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(context.connection))
        if pendingConnectionID == ObjectIdentifier(context.connection) {
            pendingConnectionID = nil
            pendingOffer = nil
        }
    }

    private func fail(_ context: ConnectionContext, error: Error) {
        AppLogger.warn("LAN sync failed: \(error.localizedDescription)", category: "sync")
        close(context)
        status = .error(error.localizedDescription)
        lastSyncedAt = nil
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
