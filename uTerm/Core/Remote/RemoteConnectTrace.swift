import Foundation
@preconcurrency import Network

/// 建连走到哪一步。界面上的进度文字、日志、诊断页的时间线都按它。
nonisolated enum RemoteConnectStage: String, Codable, Sendable, CaseIterable {
    case localNetwork
    case gather
    case relayControl
    case signal
    case direct
    case relayDial
    case handshake
    case pairing
    case desktopStart
    case firstFrame

    /// 时间线上的名字。
    var label: String {
        switch self {
        case .localNetwork: return String(localized: "局域网")
        case .gather: return String(localized: "收集地址")
        case .relayControl: return String(localized: "连接中继")
        case .signal: return String(localized: "经中继联系 Mac")
        case .direct: return String(localized: "尝试直连")
        case .relayDial: return String(localized: "经中继接通")
        case .handshake: return String(localized: "验证身份")
        case .pairing: return String(localized: "等待配对结果")
        case .desktopStart: return String(localized: "请求屏幕")
        case .firstFrame: return String(localized: "第一帧画面")
        }
    }

    /// 连接中界面上的一行进度。
    var progress: String {
        switch self {
        case .localNetwork: return String(localized: "正在经局域网连接…")
        case .gather, .relayControl: return String(localized: "正在连接中继…")
        case .signal: return String(localized: "正在经中继联系 Mac…")
        case .direct: return String(localized: "正在尝试直连…")
        case .relayDial: return String(localized: "正在经中继接通…")
        case .handshake, .pairing: return String(localized: "正在验证身份…")
        case .desktopStart: return String(localized: "正在请求屏幕…")
        case .firstFrame: return String(localized: "正在等待画面…")
        }
    }
}

/// 存下来的一次建连：诊断页「最近的连接」显示它，也能整段拷贝。
nonisolated struct RemoteConnectTraceRecord: Codable, Equatable, Sendable, Identifiable {
    nonisolated enum Kind: String, Codable, Sendable {
        case connect
        case desktop
    }

    nonisolated struct Step: Codable, Equatable, Sendable {
        var stage: RemoteConnectStage
        /// 相对这次建连开始，毫秒。
        var startMillis: Int
        /// nil = 这一步还没结束就收工了（被总时限或更早的一步打断）。
        var durationMillis: Int?
        var ok: Bool?
        /// 走的网卡（Wi-Fi / 蜂窝网络 / 有线）或别的补充（选中的打洞地址、失败原因）。
        var detail: String?
    }

    var id: String
    var kind: Kind
    var macName: String
    var startedAt: Date
    /// 开始时手机的网络（`RemoteNetworkLabel`）。
    var network: String?
    var attempt: Int
    var totalMillis: Int
    var ok: Bool
    /// 成功时是走的路，失败时是原因。
    var outcome: String
    var steps: [Step]
    /// 期间发生的事：网络变化、重试。
    var events: [String]

    var summaryLine: String {
        let kindLabel = kind == .desktop ? String(localized: "打开屏幕") : String(localized: "连接")
        return "\(kindLabel) \(macName) · \(ok ? "✓" : "✗") \(totalMillis) ms · \(outcome)"
    }

    var exportText: String {
        var lines = ["[\(id)] \(summaryLine)"]
        lines.append("  \(startedAt.formatted(date: .numeric, time: .standard)) · \(network ?? "?") · 第 \(attempt) 次")
        for step in steps {
            let result = step.ok.map { $0 ? "✓" : "✗" } ?? "…"
            let duration = step.durationMillis.map { "\($0) ms" } ?? "未结束"
            lines.append("  +\(step.startMillis) ms \(step.stage.label) \(result) \(duration)"
                         + (step.detail.map { " · \($0)" } ?? ""))
        }
        for event in events { lines.append("  · \(event)") }
        return lines.joined(separator: "\n")
    }
}

/// 一次建连的逐步记录。每一步开始、结束都按 notice 级写日志（会落盘，真机复现后 `log collect` 拿得到），
/// 收工时整条存进 `RemoteConnectTraceLog`。各步可以在任意线程上报。
nonisolated final class RemoteConnectTrace: @unchecked Sendable {
    let id: String
    let kind: RemoteConnectTraceRecord.Kind
    let macName: String
    let attempt: Int
    private let startedAt = Date()
    private let clock = ContinuousClock()
    private let start: ContinuousClock.Instant
    private let lock = NSLock()
    private var network: String?
    private var steps: [RemoteConnectTraceRecord.Step] = []
    private var events: [String] = []
    private var finished = false
    /// 每开始一步回调一次（界面显示进度）。在上报的线程上调。
    private let onStage: (@Sendable (RemoteConnectStage) -> Void)?

    /// 不写日志、不存（测试、诊断里不需要时间线的调用方）。
    private let isSilent: Bool

    init(kind: RemoteConnectTraceRecord.Kind, macName: String, attempt: Int = 1, silent: Bool = false,
         onStage: (@Sendable (RemoteConnectStage) -> Void)? = nil) {
        id = String(UUID().uuidString.prefix(6)).lowercased()
        isSilent = silent
        self.kind = kind
        self.macName = macName
        self.attempt = attempt
        self.onStage = onStage
        start = clock.now
    }

    static func silent(macName: String = "") -> RemoteConnectTrace {
        RemoteConnectTrace(kind: .connect, macName: macName, silent: true)
    }

    var elapsedMillis: Int { Self.millis(clock.now - start) }

    func setNetwork(_ label: String) {
        lock.withLock { network = label }
        log("网络 \(label)")
    }

    /// 开始一步。返回它在列表里的位置，结束时交回来。
    @discardableResult
    func begin(_ stage: RemoteConnectStage, detail: String? = nil) -> Int {
        let at = elapsedMillis
        let index = lock.withLock { () -> Int in
            steps.append(.init(stage: stage, startMillis: at, detail: detail))
            return steps.count - 1
        }
        log("\(stage.label) 开始" + (detail.map { "（\($0)）" } ?? ""))
        onStage?(stage)
        return index
    }

    func end(_ index: Int, ok: Bool, detail: String? = nil) {
        let now = elapsedMillis
        let ended = lock.withLock { () -> RemoteConnectTraceRecord.Step? in
            guard steps.indices.contains(index), steps[index].durationMillis == nil else { return nil }
            steps[index].durationMillis = now - steps[index].startMillis
            steps[index].ok = ok
            if let detail {
                steps[index].detail = [steps[index].detail, detail].compactMap { $0 }.joined(separator: " · ")
            }
            return steps[index]
        }
        guard let ended else { return }
        log("\(ended.stage.label) \(ok ? "完成" : "失败") \(ended.durationMillis ?? 0) ms"
            + (ended.detail.map { "（\($0)）" } ?? ""))
    }

    /// 包一步：开始、结束、失败原因都记上。
    func step<Value>(_ stage: RemoteConnectStage, detail: String? = nil,
                     _ body: () async throws -> Value) async throws -> Value {
        let index = begin(stage, detail: detail)
        do {
            let value = try await body()
            end(index, ok: true)
            return value
        } catch {
            end(index, ok: false, detail: error.localizedDescription)
            throw error
        }
    }

    func event(_ text: String) {
        let at = elapsedMillis
        lock.withLock { events.append("+\(at) ms \(text)") }
        log(text)
    }

    /// 收工，存下来。之后再报的步骤不记。只存一次。
    @discardableResult
    func finish(ok: Bool, outcome: String, log store: RemoteConnectTraceLog? = .standard) -> RemoteConnectTraceRecord? {
        let total = elapsedMillis
        let record = lock.withLock { () -> RemoteConnectTraceRecord? in
            guard !finished else { return nil }
            finished = true
            return RemoteConnectTraceRecord(id: id, kind: kind, macName: macName, startedAt: startedAt,
                                            network: network, attempt: attempt, totalMillis: total, ok: ok,
                                            outcome: outcome, steps: steps, events: events)
        }
        guard let record else { return nil }
        log("\(ok ? "成功" : "失败") 共 \(total) ms：\(outcome)")
        if !isSilent { store?.append(record) }
        return record
    }

    private func log(_ text: String) {
        guard !isSilent else { return }
        let prefix = kind == .desktop ? "开屏" : "建连"
        AppLogger.notice("\(prefix) \(self.id) \(self.macName) +\(self.elapsedMillis) ms · \(text)", category: RemoteLog.category)
    }

    static func millis(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// 最近 `limit` 次建连，存在本机的远控偏好里（`RemoteLocalState.defaults`；不进 iCloud / KVS 同步清单：
/// 只对这台设备的网络有意义。测试宿主里是隔开的那一份）。
nonisolated struct RemoteConnectTraceLog: Sendable {
    static let limit = 20
    static let standard = RemoteConnectTraceLog(defaults: RemoteLocalState.defaults)
    private static let key = DefaultsKey.remoteConnectTraces
    nonisolated(unsafe) let defaults: UserDefaults
    private static let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// 新的在前。
    func load() -> [RemoteConnectTraceRecord] {
        guard let data = defaults.data(forKey: Self.key) else { return [] }
        return (try? JSONDecoder().decode([RemoteConnectTraceRecord].self, from: data)) ?? []
    }

    func append(_ record: RemoteConnectTraceRecord) {
        Self.lock.withLock {
            let all = Array(([record] + load()).prefix(Self.limit))
            if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
        }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
    }

    static func exportText(_ records: [RemoteConnectTraceRecord]) -> String {
        records.map(\.exportText).joined(separator: "\n\n")
    }
}

extension RemoteNetworkLabel {
    /// 一条连接实际走的网卡。
    nonisolated static func interface(of path: NWPath?) -> String? {
        guard let path else { return nil }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi" }
        if path.usesInterfaceType(.cellular) { return String(localized: "蜂窝网络") }
        if path.usesInterfaceType(.wiredEthernet) { return String(localized: "有线") }
        if path.usesInterfaceType(.loopback) { return String(localized: "回环") }
        return path.availableInterfaces.first?.name
    }
}
