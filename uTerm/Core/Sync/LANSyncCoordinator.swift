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
    /// 本机的结构化数据是否已由 CloudKit 持续同步。决定要不要从局域网再搬一遍历史。
    private let coveredByCloudKit: @MainActor () -> Bool
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

    /// 每次 `syncNow` 自增。用来忽略上一轮同步迟到的回调（超时后旧连接仍可能回数据）。
    private var syncGeneration = 0

    private(set) var status: Status = .stopped
    private(set) var lastSyncedAt: Date?
    private(set) var pairingCode: String

    var peers: [Peer] {
        discovered.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    init(role: LANSyncRole,
         preferences: SharedPreferencesSync,
         dataStore: LANSyncDataStore,
         defaults: UserDefaults = .standard,
         coveredByCloudKit: @escaping @MainActor () -> Bool = {
             FileManager.default.ubiquityIdentityToken != nil
         }) {
        self.role = role
        self.preferences = preferences
        self.dataStore = dataStore
        self.defaults = defaults
        self.coveredByCloudKit = coveredByCloudKit
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

        syncGeneration += 1
        let generation = syncGeneration
        status = .syncing
        let connection = NWConnection(to: peer.endpoint, using: .tcp)
        retain(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard state == .ready, let connection else { return }
            Task { @MainActor [weak self] in
                self?.sendSyncRequest(on: connection, pairingCode: code, generation: generation)
            }
        }
        connection.start(queue: queue)
        scheduleTimeout(for: generation, on: connection)
    }

    /// 超时闸：到点仍停在「同步中」且还是这一轮，就判失败并断开。
    /// 没有它，对端不按新协议应答（例如尚未升级、还在等换行分帧的旧版 Mac）
    /// 会让界面永远停在「同步中…」。
    private func scheduleTimeout(for generation: Int, on connection: NWConnection) {
        Task { @MainActor [weak self, weak connection] in
            try? await Task.sleep(for: .seconds(LANSyncConstants.syncTimeoutSeconds))
            guard let self, self.syncGeneration == generation, self.status == .syncing else { return }
            self.finish(error: LANSyncTransportError.connectionFailed("等待 Mac 响应超时"))
            if let connection {
                connection.cancel()
                self.release(connection)
            }
        }
    }

    /// 这一轮是否仍然有效（没被新一轮或超时取代）。
    private func isCurrent(_ generation: Int) -> Bool { syncGeneration == generation }

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

    private func sendSyncRequest(on connection: NWConnection, pairingCode: String,
                                 generation: Int) {
        let coordinator = self
        let isInitial = !defaults.bool(forKey: Self.didCompleteInitialSyncKey)
        let request = LANSyncRequest(
            version: LANSyncConstants.protocolVersion,
            deviceID: deviceID,
            deviceName: deviceName,
            pairingCode: pairingCode,
            preferences: isInitial ? [] : preferences.lanSnapshot(),
            scope: requestedScope())
        do {
            let data = try encoder.encode(request)
            LANSyncTransport.send(data, on: connection) { [weak coordinator, weak connection] error in
                guard let connection else { return }
                if let error {
                    Task { @MainActor [weak coordinator] in coordinator?.finish(error: error) }
                    return
                }
                let reader = LANSyncFrameReader()
                reader.readFrame(from: connection) { [weak coordinator, weak connection] result in
                    guard let connection else { return }
                    Task { @MainActor [weak coordinator] in
                        switch result {
                        case .success(let data):
                            coordinator?.handleResponseHeader(data, reader: reader,
                                                              on: connection, generation: generation)
                        case .failure(let error):
                            coordinator?.finish(error: error)
                        }
                    }
                }
            }
        } catch {
            finish(error: error)
        }
    }

    /// 本机这次要哪些数据。已经被 CloudKit 持续同步的设备只要配置 —— 历史照样会到，
    /// 只是走 iCloud 那条通道，不必每次手动同步都从局域网再搬几 MB。
    private func requestedScope() -> LANSyncScope {
        coveredByCloudKit() ? .config : .all
    }

    private func receiveRequest(from connection: NWConnection) {
        let coordinator = self
        let reader = LANSyncFrameReader()
        reader.readFrame(from: connection) { [weak coordinator, weak connection] result in
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
                try reject("协议版本不兼容", on: connection)
                return
            }
            guard request.pairingCode == pairingCode else {
                try reject("配对码不正确", on: connection)
                return
            }
            _ = preferences.mergeLANSnapshot(request.preferences)

            // 对端要什么给什么：scope 同时限定了它那边的删除权威范围。
            let scope = request.scope
            let chunkFrames = try dataStore.encodedChunks(scope: scope, encoder: encoder)
            let header = LANSyncResponseHeader(
                version: LANSyncConstants.protocolVersion,
                accepted: true,
                message: "同步完成",
                preferences: preferences.lanSnapshot(),
                scope: scope,
                chunkCount: chunkFrames.count)
            var frames = [try encoder.encode(header)]
            frames.append(contentsOf: chunkFrames)
            LANSyncTransport.sendAll(frames, on: connection) { [weak self, weak connection] error in
                guard let error, let connection else { return }
                Task { @MainActor [weak self] in self?.close(connection, error: error) }
            }
        } catch {
            close(connection, error: error)
        }
    }

    private func handleResponseHeader(_ data: Data, reader: LANSyncFrameReader,
                                      on connection: NWConnection, generation: Int) {
        guard isCurrent(generation) else { return }
        do {
            let header = try decoder.decode(LANSyncResponseHeader.self, from: data)
            guard header.accepted else {
                finish(error: LANSyncTransportError.connectionFailed(header.message))
                return
            }
            _ = preferences.mergeLANSnapshot(header.preferences)
            // 合并会话跨分片存活：删除要等所有分片到齐才能判定。
            let session = try dataStore.beginMerge(scope: header.scope)
            receiveChunk(remaining: header.chunkCount, into: session,
                         reader: reader, on: connection, generation: generation)
        } catch {
            finish(error: error)
        }
    }

    /// 逐帧收数据分片；收满 `remaining` 帧后收尾。
    private func receiveChunk(remaining: Int, into session: LANSyncMergeSession,
                              reader: LANSyncFrameReader, on connection: NWConnection,
                              generation: Int) {
        guard isCurrent(generation) else {
            session.cancel()
            return
        }
        guard remaining > 0 else {
            completeSync(session, on: connection, generation: generation)
            return
        }
        reader.readFrame(from: connection) { [weak self, weak connection] result in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isCurrent(generation) else {
                    session.cancel()
                    return
                }
                switch result {
                case .success(let data):
                    do {
                        let chunk = try self.decoder.decode(LANSyncDataSnapshot.self, from: data)
                        try session.apply(chunk)
                        self.receiveChunk(remaining: remaining - 1, into: session,
                                          reader: reader, on: connection, generation: generation)
                    } catch {
                        session.cancel()
                        self.finish(error: error)
                    }
                case .failure(let error):
                    session.cancel()
                    self.finish(error: error)
                }
            }
        }
    }

    private func completeSync(_ session: LANSyncMergeSession, on connection: NWConnection,
                              generation: Int) {
        guard isCurrent(generation) else {
            session.cancel()
            return
        }
        do {
            // 最小增量合并：只写真正变化的字段。开着 CloudKit 镜像时，这一步的写入量
            // 直接决定会被广播给其它设备的改动量，全等时一条都不产生。
            let report = try session.finish()
            if !report.isEmpty {
                AppLogger.info("局域网同步已应用：\(report.summary)", category: "sync")
            }
            defaults.set(true, forKey: Self.didCompleteInitialSyncKey)
            lastSyncedAt = Date()
            status = .ready
            connection.cancel()
            release(connection)
        } catch {
            session.cancel()
            finish(error: error)
        }
    }

    /// 握手失败：只发一帧 header，chunkCount = 0。
    private func reject(_ message: String, on connection: NWConnection) throws {
        try send(LANSyncResponseHeader(version: LANSyncConstants.protocolVersion,
                                       accepted: false, message: message,
                                       preferences: [], scope: [], chunkCount: 0),
                 on: connection)
    }

    private func send(_ response: LANSyncResponseHeader, on connection: NWConnection) throws {
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
        // 作废本轮：迟到的分片回调会在 isCurrent 处被挡下并回滚。
        syncGeneration += 1
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
