import Foundation
@preconcurrency import Network
import Observation
#if canImport(UIKit)
import UIKit
#elseif canImport(SystemConfiguration)
import SystemConfiguration
#endif

nonisolated private struct LANSyncClearPacket: Codable, Sendable {
    let hello: LANSyncCryptoSession.Hello?
    let error: String?

    init(hello: LANSyncCryptoSession.Hello? = nil, error: String? = nil) {
        self.hello = hello
        self.error = error
    }
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
        var dataChunks: [LANSyncDataSnapshot] = []
        var transferPlaintexts: [Data] = []
        var chunks: [LANSyncTransferChunk] = []
        var receivedPlaintexts: [Data] = []
        var pendingOffer: LANSyncOffer?
        var phase = "connected"
        /// 正在等的那一帧从什么时候开始等；nil = 此刻不在读（例如等用户确认、正在合并）。
        var awaitingFrameSince: Date?
        var watchdog: Task<Void, Never>?

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

    private static let deviceIDKey = PreferenceKey.lanSyncDeviceID
    private static let hostPairingCodeKey = PreferenceKey.lanSyncHostPairingCode
    private static let mobilePairingCodeKey = PreferenceKey.lanSyncPairingCode
    private static let receiverActivatedKey = PreferenceKey.lanSyncReceiverActivated

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
        LANSyncDateCoding.configure(encoder: encoder, decoder: decoder)
        let existingID = defaults.string(forKey: Self.deviceIDKey)
        let id = existingID ?? UUID().uuidString
        if existingID == nil { defaults.set(id, forKey: Self.deviceIDKey) }
        deviceID = id
        deviceName = Self.localDeviceName()

        switch role {
        case .sender:
            let code = defaults.string(forKey: Self.hostPairingCodeKey) ?? Self.makePairingCode()
            defaults.set(code, forKey: Self.hostPairingCodeKey)
            pairingCode = code
        case .receiver:
            pairingCode = defaults.string(forKey: Self.mobilePairingCodeKey) ?? ""
        }
    }

    /// 本机给对端看的名字（Bonjour 服务名、确认弹窗里的「设备」）。只作展示，不参与密钥派生。
    ///
    /// **别用 `ProcessInfo.processInfo.hostName`**：它要走网络解析本机名，在 iOS 上会触发「查找
    /// 本地网络上的设备」授权并**同步阻塞**调用线程直到用户作答。本类在 `MobileApp.init()` 的
    /// 主线程上创建，首次安装启动时主线程就卡在授权弹窗上，20 s 后被系统启动看门狗杀掉
    /// （`process-launch watchdog transgression`，栈底正是这一行）。macOS 上它同样会做反向解析，
    /// DNS 不通时也能卡上好几秒。
    static func localDeviceName() -> String {
        #if canImport(UIKit)
        return UIDevice.current.name
        #elseif canImport(SystemConfiguration)
        return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #else
        return "uTerm"
        #endif
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
        for context in connections.values {
            context.watchdog?.cancel()
            context.connection.cancel()
        }
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

    // MARK: - 接收端何时开始监听

    // 监听（Bonjour 广播 + NWListener）会触发系统的「查找本地网络上的设备」授权。按 Apple 的
    // 做法，授权应在用户真正用到这项功能时才请求，而不是首次启动就弹：所以首次启动不监听，
    // 用户第一次在设置里看到「局域网接收」区块时才开始（此时弹授权，上下文清楚），并记下已启用，
    // 之后每次启动直接监听（授权只问一次，之后不再弹）。只对接收端（移动端）生效。

    /// 已启用过：看到过局域网接收区块，或升级前就配过配对码（老用户不必再进一次设置）。
    var isReceiverActivated: Bool {
        guard role == .receiver else { return false }
        if defaults.bool(forKey: Self.receiverActivatedKey) { return true }
        return !pairingCode.isEmpty
    }

    /// 局域网接收区块滚进可视区时调用：记下已启用，并在还没监听（或上次出错）时开始监听。
    func activateReceiver() {
        guard role == .receiver else { return }
        defaults.set(true, forKey: Self.receiverActivatedKey)
        startIfIdle()
    }

    /// 启动时 / 回到前台时调用：启用过的才（重新）开始监听。退到后台后系统会让监听失效
    ///（状态转为出错 / 停止），不重启的话 Mac 怎么发都找不到这台手机。
    func resumeIfActivated() {
        guard isReceiverActivated else { return }
        startIfIdle()
    }

    private func startIfIdle() {
        switch status {
        case .stopped, .error: start()
        default: break
        }
    }

    private func respondToPendingSync(accepted: Bool) {
        guard role == .receiver, let id = pendingConnectionID,
              let context = connections[id], let crypto = context.crypto else { return }
        do {
            pendingOffer = nil
            pendingConnectionID = nil
            if accepted {
                try sendEncrypted(LANSyncDecision(accepted: true), type: "decision",
                                  on: context, crypto: crypto)
                status = .syncing
                receiveChunks(on: context)
            } else {
                try sendEncryptedThenClose(LANSyncDecision(accepted: false), type: "decision",
                                           on: context, crypto: crypto)
                status = .hosting
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
        startReceiveWatchdog(on: context)
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
            try sendClear(LANSyncClearPacket(hello: crypto.hello), on: context)
            context.phase = "waiting for receiver hello"
            readFrame(on: context) { [weak self] data in
                guard let self else { return }
                do {
                    let packet = try self.decoder.decode(LANSyncClearPacket.self, from: data)
                    if let error = packet.error {
                        throw LANSyncTransportError.connectionFailed(error)
                    }
                    guard let remote = packet.hello else {
                        throw LANSyncTransportError.invalidMessage
                    }
                    var initiator = crypto
                    try initiator.establish(with: remote, initiator: true)
                    context.crypto = initiator
                    context.phase = "sending encrypted offer"
                    try self.sendOffer(on: context)
                } catch { self.fail(context, error: error) }
            }
        } catch { fail(context, error: error) }
    }

    private func receiveClearHello(on connection: NWConnection) {
        guard let context = context(for: connection) else { return }
        context.phase = "waiting for sender hello"
        readFrame(on: context) { [weak self] data in
            guard let self else { return }
            do {
                let packet = try self.decoder.decode(LANSyncClearPacket.self, from: data)
                guard let remote = packet.hello else {
                    throw LANSyncTransportError.invalidMessage
                }
                // The code field is editable while the listener is already running.
                // Read the persisted value at handshake time so an earlier empty cache
                // cannot reject a code that is now visible in Settings.
                let pairingCode = self.currentReceiverPairingCode
                guard !pairingCode.isEmpty else { throw LANSyncTransportError.authenticationFailed }
                let base = LANSyncCryptoSession(sessionID: remote.sessionID, deviceID: self.deviceID,
                                                 deviceName: self.deviceName, pairingCode: pairingCode)
                let responder = try base.respondingSession(to: remote, deviceID: self.deviceID,
                                                            deviceName: self.deviceName,
                                                            pairingCode: pairingCode)
                context.crypto = responder
                try self.sendClear(LANSyncClearPacket(hello: responder.hello), on: context)
                context.phase = "waiting for encrypted offer"
                self.receiveOffer(on: context)
            } catch {
                self.sendRejectionAndClose(context, message: "移动端未设置配对码或配对码无效",
                                            error: error)
            }
        }
    }

    private func sendOffer(on context: ConnectionContext) throws {
        guard let crypto = context.crypto else { throw LANSyncTransportError.handshakeRequired }
        let payload = try dataStore.fullSnapshot(preferences: preferences.lanSnapshot())
        let fittedChunks = try LANSyncDataStore.fittingSnapshots(payload.data, encoder: encoder)
        let chunks = fittedChunks.isEmpty ? [.empty] : fittedChunks
        // Hash the exact Codable representation that will cross the wire. This avoids
        // Date/optional normalization differences between the sender's model snapshot
        // and the receiver's decoded chunks.
        let wireData = LANSyncDataSnapshot(
            profiles: chunks.flatMap { $0.profiles },
            groups: chunks.flatMap { $0.groups },
            knownHosts: chunks.flatMap { $0.knownHosts },
            sshKeys: chunks.flatMap { $0.sshKeys },
            providers: chunks.flatMap { $0.providers },
            forwardingRules: chunks.flatMap { $0.forwardingRules },
            quickCommands: chunks.flatMap { $0.quickCommands },
            quickCommandRuns: chunks.flatMap { $0.quickCommandRuns },
            chatSessions: chunks.flatMap { $0.chatSessions },
            chatMessages: chunks.flatMap { $0.chatMessages })
        let wirePreferences = payload.preferences.map {
            LANSyncPreference(key: $0.key, value: $0.value,
                              modifiedAt: Date(timeIntervalSince1970: $0.modifiedAt.timeIntervalSince1970.rounded()))
        }
        let wirePayload = LANSyncFullSnapshot(data: wireData,
                                              preferences: wirePreferences,
                                              secrets: payload.secrets)
        let transferChunks = chunks.enumerated().map { index, snapshot in
            LANSyncTransferChunk(index: index, total: chunks.count, data: snapshot,
                                 preferences: index == 0 ? wirePayload.preferences : [],
                                 secrets: index == 0 ? wirePayload.secrets : [])
        }
        let transferPlaintexts = try transferChunks.map { try encoder.encode($0) }
        let offer = LANSyncOffer(
            sessionID: crypto.sessionID, deviceID: deviceID, deviceName: deviceName,
            recordCount: wirePayload.recordCount, preferenceCount: wirePayload.preferences.count,
            secretCount: wirePayload.secretCount, chunkCount: chunks.count,
            digest: LANSyncPayloadDigest.digestBytes(transferPlaintexts),
            includesSensitiveData: true)
        context.payload = wirePayload
        context.dataChunks = chunks
        context.transferPlaintexts = transferPlaintexts
        try sendEncrypted(offer, type: "offer", on: context, crypto: crypto)
        readDecision(on: context)
    }

    private func receiveOffer(on context: ConnectionContext) {
        context.phase = "waiting for encrypted offer"
        readEncrypted(on: context, expectedType: "offer") { [weak self] (offer: LANSyncOffer, _) in
            guard let self, offer.sessionID == context.crypto?.sessionID else {
                self?.fail(context, error: LANSyncTransportError.invalidMessage); return
            }
            let id = ObjectIdentifier(context.connection)
            // 已有一个请求在等确认 / 正在同步：拒掉后来的。改前直接覆盖 `pendingConnectionID`，
            // 前一个连接的 context 永远留在 `connections` 里，用户确认的也成了后来那个。
            if (self.pendingConnectionID.map { $0 != id } ?? false) || self.status == .syncing {
                if let crypto = context.crypto,
                   (try? self.sendEncryptedThenClose(LANSyncDecision(accepted: false), type: "decision",
                                                     on: context, crypto: crypto)) != nil {
                    return
                }
                self.close(context)
                return
            }
            context.pendingOffer = offer
            self.pendingConnectionID = id
            self.pendingOffer = offer
            self.status = .waitingForConfirmation
            context.phase = "waiting for receiver decision"
            self.expirePendingOffer(on: context)
        }
    }

    /// 等确认超过发送端的超时就作废：那时 Mac 早已放弃，再点「确认」只会对着一条死连接。
    private func expirePendingOffer(on context: ConnectionContext) {
        let id = ObjectIdentifier(context.connection)
        Task { [weak self, weak context] in
            try? await Task.sleep(for: .seconds(LANSyncConstants.syncTimeoutSeconds))
            guard let self, let context, self.pendingConnectionID == id else { return }
            AppLogger.info("LAN sync offer expired before confirmation", category: "sync")
            self.close(context)
            self.status = .hosting
        }
    }

    /// 接收端的读帧看门狗：在等某一帧、超过发送端超时还没等到就判失败。
    /// 发送端合盖或断 Wi-Fi 时不一定发 RST，`receive` 会一直挂着，状态永远停在「同步中」，
    /// 而 `activateReceiver` / `resumeIfActivated` 只在 `.stopped` / `.error` 时重启——只能杀进程。
    private func startReceiveWatchdog(on context: ConnectionContext) {
        context.watchdog = Task { [weak self, weak context] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self, let context,
                      self.connections[ObjectIdentifier(context.connection)] != nil else { return }
                guard let since = context.awaitingFrameSince,
                      Date().timeIntervalSince(since) > LANSyncConstants.syncTimeoutSeconds else { continue }
                self.fail(context, error: LANSyncTransportError.connectionFailed("同步中断：Mac 长时间没有响应"))
                return
            }
        }
    }

    private func readDecision(on context: ConnectionContext) {
        context.phase = "waiting for receiver decision"
        readEncrypted(on: context, expectedType: "decision") { [weak self] (decision: LANSyncDecision, _) in
            guard let self else { return }
            guard decision.accepted else { self.fail(context, error: LANSyncTransportError.rejected); return }
            self.status = .syncing
            context.phase = "sending encrypted chunks"
            do { try self.sendChunks(on: context) } catch { self.fail(context, error: error) }
        }
    }

    private func sendChunks(on context: ConnectionContext) throws {
        guard context.payload != nil, let crypto = context.crypto else {
            throw LANSyncTransportError.handshakeRequired
        }
        let transferPlaintexts = context.transferPlaintexts
        for plaintext in transferPlaintexts {
            try sendEncryptedBytes(plaintext, type: "chunk", on: context, crypto: crypto)
        }
        try sendEncrypted(LANSyncTransferResult(succeeded: true, message: "发送完成", digest: nil),
                          type: "finish", on: context, crypto: crypto)
        readSenderResult(on: context)
    }

    private func receiveChunks(on context: ConnectionContext) {
        context.chunks.removeAll()
        context.receivedPlaintexts.removeAll()
        context.phase = "receiving encrypted chunks"
        readNextChunk(on: context)
    }

    private func readNextChunk(on context: ConnectionContext) {
        readEncrypted(on: context, expectedType: "chunk") { [weak self] (chunk: LANSyncTransferChunk, plaintext: Data) in
            guard let self else { return }
            guard chunk.index == context.chunks.count,
                  chunk.total > 0, chunk.total <= LANSyncConstants.maxTotalBytes else {
                self.fail(context, error: LANSyncTransportError.invalidMessage); return
            }
            context.chunks.append(chunk)
            context.receivedPlaintexts.append(plaintext)
            if context.chunks.count < chunk.total { self.readNextChunk(on: context) }
            else { self.readSenderFinish(on: context) }
        }
    }

    private func readSenderFinish(on context: ConnectionContext) {
        context.phase = "waiting for sender finish"
        readEncrypted(on: context, expectedType: "finish") { [weak self] (_: LANSyncTransferResult, _) in
            guard let self else { return }
            self.finishReceiverPayload(on: context)
        }
    }

    private func readSenderResult(on context: ConnectionContext) {
        context.phase = "waiting for receiver result"
        readEncrypted(on: context, expectedType: "result") { [weak self] (result: LANSyncTransferResult, _) in
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
        guard let offer = context.pendingOffer else {
            fail(context, error: LANSyncTransportError.invalidMessage)
            return
        }
        let chunks = context.chunks
        let plaintexts = context.receivedPlaintexts
        context.phase = "applying payload"
        Task { [weak self] in
            guard let self else { return }
            do {
                // 拼装（几十 MB 的 flatMap 复制）与摘要校验、模型合并、钥匙串写入都不在主线程。
                let payload = try await Self.assembleVerified(chunks, plaintexts: plaintexts,
                                                              expectedDigest: offer.digest)
                AppLogger.info("LAN sync applying verified payload records=\(payload.recordCount) secrets=\(payload.secretCount)",
                               category: "sync")
                _ = try await self.dataStore.replace(with: payload)
                // 数据已落库：偏好必须跟着落，不论发送端此刻还在不在（它可能已超时断开）。
                _ = self.preferences.replaceFromLAN(payload.preferences)
                self.status = .hosting
                self.lastSyncedAt = Date()
                guard self.connections[ObjectIdentifier(context.connection)] != nil,
                      let crypto = context.crypto else { return }
                try self.sendEncryptedThenClose(LANSyncTransferResult(succeeded: true, message: "同步完成",
                                                                      digest: offer.digest), type: "result",
                                                on: context, crypto: crypto)
            } catch {
                let result = LANSyncTransferResult(succeeded: false, message: error.localizedDescription, digest: nil)
                if let crypto = context.crypto {
                    try? self.sendEncrypted(result, type: "result", on: context, crypto: crypto)
                }
                self.fail(context, error: error)
            }
        }
    }

    /// 把收齐的分片拼回整份快照，并核对发送端在 offer 里给的摘要。
    @concurrent nonisolated private static func assembleVerified(
        _ chunks: [LANSyncTransferChunk], plaintexts: [Data], expectedDigest: String
    ) async throws -> LANSyncFullSnapshot {
        guard let first = chunks.first, chunks.count == first.total else {
            throw LANSyncTransportError.invalidMessage
        }
        let payload = LANSyncFullSnapshot(
            data: LANSyncDataSnapshot(
                profiles: chunks.flatMap { $0.data.profiles },
                groups: chunks.flatMap { $0.data.groups },
                knownHosts: chunks.flatMap { $0.data.knownHosts },
                sshKeys: chunks.flatMap { $0.data.sshKeys },
                providers: chunks.flatMap { $0.data.providers },
                forwardingRules: chunks.flatMap { $0.data.forwardingRules },
                quickCommands: chunks.flatMap { $0.data.quickCommands },
                quickCommandRuns: chunks.flatMap { $0.data.quickCommandRuns },
                chatSessions: chunks.flatMap { $0.data.chatSessions },
                chatMessages: chunks.flatMap { $0.data.chatMessages }),
            preferences: first.preferences, secrets: first.secrets)
        let computedDigest = LANSyncPayloadDigest.digestBytes(plaintexts)
        guard computedDigest == expectedDigest else {
            AppLogger.warn("LAN sync digest mismatch: chunks=\(chunks.count), "
                           + "receivedRecords=\(payload.recordCount), "
                           + "offerPrefix=\(expectedDigest.prefix(8)), computedPrefix=\(computedDigest.prefix(8))",
                           category: "sync")
            throw LANSyncTransportError.invalidMessage
        }
        return payload
    }

    private func readFrame(on context: ConnectionContext,
                           completion: @escaping @MainActor @Sendable (Data) -> Void) {
        context.awaitingFrameSince = Date()
        context.reader.readFrame(from: context.connection) { [weak self, weak context] result in
            guard let self, let context else { return }
            Task { @MainActor in
                context.awaitingFrameSince = nil
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
        let plaintext = try encoder.encode(value)
        try sendEncryptedBytes(plaintext, type: type, on: context, crypto: crypto)
    }

    /// 发出最后一帧，等它真的写出去再关连接。
    ///
    /// `close()` 紧跟在 `send` 之后时，帧可能还没写出去连接就拆了：对端读到 EOF，
    /// 只能报「消息格式无效」——数据其实已经合并成功，发送端却显示同步失败。
    /// 合并改成异步之后这个窗口在机器忙时能稳定撞上（全量测试里复现过）。
    private func sendEncryptedThenClose<T: Encodable>(_ value: T, type: String, on context: ConnectionContext,
                                                      crypto: LANSyncCryptoSession) throws {
        let plaintext = try encoder.encode(value)
        let sequence = context.nextSendSequence
        context.nextSendSequence += 1
        let data = try crypto.encryptedBytes(plaintext, messageType: type, sequence: sequence)
        AppLogger.info("LAN sync sending final \(type) frame seq=\(sequence) bytes=\(data.count)", category: "sync")
        // 等待写出期间不再算「在读帧」，看门狗不会误判；连接留在表里直到关掉。
        context.awaitingFrameSince = nil
        LANSyncTransport.send(data, on: context.connection) { [weak self, weak context] _ in
            Task { @MainActor in
                guard let self, let context else { return }
                self.close(context)
            }
        }
    }

    private func sendEncryptedBytes(_ plaintext: Data, type: String, on context: ConnectionContext,
                                    crypto: LANSyncCryptoSession) throws {
        let sequence = context.nextSendSequence
        context.nextSendSequence += 1
        let data = try crypto.encryptedBytes(plaintext, messageType: type, sequence: sequence)
        AppLogger.info("LAN sync sending \(type) frame seq=\(sequence) bytes=\(data.count)", category: "sync")
        LANSyncTransport.send(data, on: context.connection) { [weak self, weak context] error in
            guard let self, let context, let error else { return }
            Task { @MainActor in self.fail(context, error: error) }
        }
    }

    private func readEncrypted<T: Decodable & Sendable>(
        on context: ConnectionContext, expectedType: String,
        completion: @escaping @MainActor @Sendable (T, Data) -> Void
    ) {
        readFrame(on: context) { [weak self, weak context] data in
            guard let self, let context, let crypto = context.crypto else { return }
            let expectedSequence = context.nextReceiveSequence
            // 解 Envelope（base64 JSON）、ChaChaPoly 解密、再解一层 JSON：一片最大 5MB 明文，
            // 放在主线程上每片都卡一下。挪到并发线程池，结果回主线程推进状态机。
            Task { [weak self, weak context] in
                let opened: Result<(T, Data), any Error> = await Self.open(
                    data, crypto: crypto, expectedType: expectedType, expectedSequence: expectedSequence)
                guard let self, let context,
                      self.connections[ObjectIdentifier(context.connection)] != nil else { return }
                switch opened {
                case .success(let (value, bytes)):
                    context.nextReceiveSequence += 1
                    completion(value, bytes)
                case .failure(let error):
                    if expectedType == "offer" {
                        self.sendRejectionAndClose(context, message: "配对码不正确或移动端未设置配对码",
                                                    error: error)
                        return
                    }
                    self.fail(context, error: error)
                }
            }
        }
    }

    @concurrent nonisolated private static func open<T: Decodable & Sendable>(
        _ data: Data, crypto: LANSyncCryptoSession, expectedType: String, expectedSequence: UInt64
    ) async -> Result<(T, Data), any Error> {
        do {
            let decoder = JSONDecoder()
            LANSyncDateCoding.configure(encoder: JSONEncoder(), decoder: decoder)
            if let clear = try? decoder.decode(LANSyncClearPacket.self, from: data),
               let error = clear.error {
                throw LANSyncTransportError.connectionFailed(error)
            }
            let result = try crypto.decryptedBytes(data)
            AppLogger.info("LAN sync received \(result.messageType) frame seq=\(result.sequence) bytes=\(result.bytes.count)", category: "sync")
            guard result.messageType == expectedType else {
                throw LANSyncTransportError.connectionFailed(
                    "收到意外消息 \(result.messageType)，预期 \(expectedType)")
            }
            guard result.sequence == expectedSequence else {
                throw LANSyncTransportError.connectionFailed(
                    "消息序号错误：收到 \(result.sequence)，预期 \(expectedSequence)")
            }
            return .success((try decoder.decode(T.self, from: result.bytes), result.bytes))
        } catch {
            return .failure(error)
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

    private var currentReceiverPairingCode: String {
        String((defaults.string(forKey: Self.mobilePairingCodeKey) ?? "")
            .filter(\.isNumber).prefix(6))
    }

    private func sendRejectionAndClose(_ context: ConnectionContext, message: String, error: Error) {
        do {
            let data = try encoder.encode(LANSyncClearPacket(error: message))
            LANSyncTransport.send(data, on: context.connection) { [weak self, weak context] _ in
                guard let self, let context else { return }
                Task { @MainActor in self.fail(context, error: error) }
            }
        } catch {
            fail(context, error: error)
        }
    }

    private func context(for connection: NWConnection) -> ConnectionContext? {
        connections[ObjectIdentifier(connection)]
    }

    private func retain(_ context: ConnectionContext) {
        connections[ObjectIdentifier(context.connection)] = context
    }

    private func close(_ context: ConnectionContext) {
        context.watchdog?.cancel()
        context.connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(context.connection))
        if pendingConnectionID == ObjectIdentifier(context.connection) {
            pendingConnectionID = nil
            pendingOffer = nil
        }
    }

    private func fail(_ context: ConnectionContext, error: Error) {
        AppLogger.warn("LAN sync failed at \(context.phase): \(error.localizedDescription)", category: "sync")
        close(context)
        status = .error(error.localizedDescription)
        lastSyncedAt = nil
    }

    private static func makePairingCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
}
