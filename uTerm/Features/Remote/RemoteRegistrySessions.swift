import Foundation
import Observation

/// `RemoteHostSessions` 的进程内实现：直接读 `TerminalSessionRegistry`、接管 `TerminalSession`。
///
/// 远控服务跑在 App 里（测试、开发构建、远控进程不可用时）用它；远控服务跑在远控进程里时，App 侧的
/// `RemoteHostAgentBridge` 也用它来响应远控进程转来的接入，所以接管的规则只有这一份。
@MainActor
final class RemoteRegistrySessions: RemoteHostSessions {
    let registry: TerminalSessionRegistry
    let terminalEngine = TerminalEngineVersion.current
    /// 接回本机终端（重启后）完成之前，列表与接入都要等它。nil = 没有要等的。
    var restoration: (@MainActor () async -> Void)?

    /// 每个会话当前钉着尺寸的接入。后来的接入接管尺寸；先前那条结束时不能把后来者钉的尺寸解掉。
    fileprivate var gridOwners: [UUID: ObjectIdentifier] = [:]
    private var observer: RemoteHostSessionObserver?
    /// 观察链的代次：`observe` 每调一次加一，旧链醒来对不上就自行结束。
    private var generation = 0

    init(registry: TerminalSessionRegistry, restoration: (@MainActor () async -> Void)? = nil) {
        self.registry = registry
        self.restoration = restoration
    }

    func orderedSessions() -> [RemoteHostSessionEntry] {
        registry.orderedEntries().map { entry in
            RemoteHostSessionEntry(id: entry.id, serverID: entry.serverID, serverName: entry.serverName, title: entry.title,
                                   windowKind: entry.windowKind, connectedAt: entry.connectedAt,
                                   tabTitle: registry.displayTitle(of: entry), program: registry.programReport(of: entry))
        }
    }

    func waitUntilRestored() async {
        await restoration?()
    }

    func requestClose(sessionID: UUID) async -> Bool {
        registry.requestClose(sessionID: sessionID)
    }

    func requestArrange(order: [UUID]) async {
        registry.arrangeTabs(by: order)
    }

    func attach(_ request: RemoteHostAttachRequest) async -> Result<any RemoteHostTerminalAttachment, RemoteHostAttachError> {
        guard let session = registry.session(for: request.sessionID), session.connectionState == .connected else {
            return .failure(.unavailable)
        }
        let attachment = RegistryAttachment(owner: self, sessionID: request.sessionID, session: session)
        gridOwners[request.sessionID] = ObjectIdentifier(attachment)
        // 先钉尺寸再订阅：第一份快照就是对端的行列数（订阅里等钉好）。
        session.pinRemoteGrid(cols: request.cols, rows: request.rows, controller: request.controller)
        session.remoteDisconnect = { [weak attachment] in attachment?.onRemoteDisconnect?() }
        let shadow = session.shadow
        let target = (cols: request.cols, rows: request.rows)
        attachment.subscriber = session.mirrorTap.subscribe(
            id: attachment.subscriberID,
            format: request.snapshotFormat,
            firstSnapshotWhen: { shadow.size == target },
            timeout: request.settleTimeout,
            onReadable: request.onReadable)
        return .success(attachment)
    }

    // MARK: - 观察

    func observe(_ observer: RemoteHostSessionObserver) {
        self.observer = observer
        generation &+= 1
        observeEntries(generation)
        observeTitles(generation)
        observeProgramStatuses(generation)
        observeOrder(generation, listed: registry.orderedEntries().map(\.id))
    }

    func stopObserving() {
        observer = nil
        generation &+= 1
    }

    private func isCurrent(_ generation: Int) -> Bool {
        observer != nil && generation == self.generation
    }

    private func observeEntries(_ generation: Int) {
        withObservationTracking {
            _ = registry.entries
        } onChange: { [weak self] in
            Self.onMain {
                guard let self, self.isCurrent(generation) else { return }
                self.observer?.sessionsChanged(Set(self.registry.entries.map(\.id)))
                self.observeEntries(generation)
            }
        }
    }

    private func observeTitles(_ generation: Int) {
        withObservationTracking {
            for entry in registry.entries { _ = registry.displayTitle(of: entry) }
        } onChange: { [weak self] in
            Self.onMain {
                guard let self, self.isCurrent(generation) else { return }
                self.observer?.titlesChanged()
                self.observeTitles(generation)
            }
        }
    }

    private func observeProgramStatuses(_ generation: Int) {
        withObservationTracking {
            for entry in registry.entries { _ = registry.programReport(of: entry) }
        } onChange: { [weak self] in
            Self.onMain {
                guard let self, self.isCurrent(generation) else { return }
                self.observer?.programStatusChanged()
                self.observeProgramStatuses(generation)
            }
        }
    }

    /// 重排、拆分、跨组拖动标签。拖分隔条也会叫醒这里，先后没变就不报。
    private func observeOrder(_ generation: Int, listed: [UUID]) {
        withObservationTracking {
            _ = registry.orderedEntries()
        } onChange: { [weak self] in
            Self.onMain {
                guard let self, self.isCurrent(generation) else { return }
                let order = self.registry.orderedEntries().map(\.id)
                if order != listed { self.observer?.orderChanged() }
                self.observeOrder(generation, listed: order)
            }
        }
    }

    private nonisolated static func onMain(_ body: @escaping @MainActor () -> Void) {
        DispatchQueue.main.async { MainActor.assumeIsolated(body) }
    }
}

@MainActor
private final class RegistryAttachment: RemoteHostTerminalAttachment {
    private weak var owner: RemoteRegistrySessions?
    let sessionID: UUID
    private weak var session: TerminalSession?
    let subscriberID = UUID()
    nonisolated(unsafe) var subscriber: TerminalMirrorTap.Subscriber!
    var onRemoteDisconnect: (@MainActor () -> Void)?
    private var isDetached = false

    nonisolated var feed: any RemoteTerminalFeed { subscriber }

    init(owner: RemoteRegistrySessions, sessionID: UUID, session: TerminalSession) {
        self.owner = owner
        self.sessionID = sessionID
        self.session = session
    }

    private var ownsGrid: Bool {
        owner?.gridOwners[sessionID] == ObjectIdentifier(self)
    }

    func write(_ data: Data) {
        session?.writeRemoteInput(data)
    }

    func resize(cols: Int, rows: Int, controller: String) {
        guard ownsGrid else { return }
        session?.pinRemoteGrid(cols: cols, rows: rows, controller: controller)
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        onRemoteDisconnect = nil
        guard let session else { return }
        session.mirrorTap.unsubscribe(id: subscriberID)
        if ownsGrid {
            owner?.gridOwners.removeValue(forKey: sessionID)
            session.unpinRemoteGrid()
            session.remoteDisconnect = nil
        }
    }

    func deliverImage(_ image: TerminalImage) async -> Result<String?, RemoteHostImageError> {
        guard let backend = session?.backend as? any TerminalImageReceiving else {
            return .failure(RemoteHostImageError(message: String(localized: "这个终端不能接收图片")))
        }
        do {
            if case .file(let path) = try await backend.deliverImage(image) { return .success(path) }
            return .success(nil)
        } catch {
            return .failure(RemoteHostImageError(message: String(localized: "图片发送失败：\(error.localizedDescription)")))
        }
    }
}

extension RemoteHostServer {
    /// App 进程内的远控服务：会话直接来自 `registry`。
    convenience init(registry: TerminalSessionRegistry,
                     identity: RemoteIdentityStore = RemoteIdentityStore(role: .controllers),
                     localName: String = LANSyncCoordinator.localDeviceName(),
                     localID: UUID = RemoteLocalDevice.id(),
                     advertises: Bool = true,
                     localFeatures: [String] = RemoteConstants.localFeatures,
                     peerSilenceLimit: TimeInterval = RemoteHeartbeat.standard.peerSilenceLimit,
                     keyConfirmationTimeout: Duration = RemoteConstants.handshakeTimeout,
                     relayStore: RemoteRelayConfigStore? = nil,
                     relayUpdates: RemoteRelayUpdateMonitor = .inert(),
                     relayRevocations: RemoteRelayRevocations = RemoteRelayRevocations(defaults: RemoteLocalState.defaults),
                     desktopEnvironment: RemoteDesktopEnvironment = .disabled,
                     relayRegistrationBlock: RemoteRelayRegistrationBlock? = nil) {
        self.init(sessions: RemoteRegistrySessions(registry: registry), identity: identity, localName: localName,
                  localID: localID, advertises: advertises, localFeatures: localFeatures,
                  peerSilenceLimit: peerSilenceLimit, keyConfirmationTimeout: keyConfirmationTimeout,
                  relayStore: relayStore, relayUpdates: relayUpdates, relayRevocations: relayRevocations,
                  desktopEnvironment: desktopEnvironment, relayRegistrationBlock: relayRegistrationBlock)
    }

    /// 进程内实现时的会话目录（测试与 App 接线用）。
    var registry: TerminalSessionRegistry? { (sessions as? RemoteRegistrySessions)?.registry }
}
