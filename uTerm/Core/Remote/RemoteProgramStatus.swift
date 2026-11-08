import Foundation

/// Mac → 设备：终端里程序的状态（`programStatus`，通道 0）。
///
/// 每条带的是那个会话此刻的完整状态（不是差量），重复收到也无害：快照与紧随其后的变化推送撞在一起时，
/// 以后到的为准。
nonisolated struct RemoteProgramStatusUpdate: Codable, Equatable, Sendable {
    /// true = 全量快照：没列出的会话都没有状态。false = 只列出变了的会话。
    var replacesAll: Bool
    var entries: [Entry]

    struct Entry: Codable, Equatable, Sendable {
        var sessionID: UUID
        /// nil = 这个会话已没有程序状态（程序退出、清掉了、连接断了）。
        var status: RemoteProgramStatus?
    }
}

/// `ProgramStatusRecord` 的线上形态。枚举都按字符串传：以后多一种状态，老设备只丢这一条，不丢整份更新。
nonisolated struct RemoteProgramStatus: Codable, Equatable, Sendable {
    var state: String
    var kind: String?
    var progress: Int?
    var app: String?
    var title: String?
    var message: String?

    init(_ record: ProgramStatusRecord) {
        state = record.state.rawValue
        kind = record.kind?.rawValue
        progress = record.progress
        app = record.app
        title = record.title
        message = record.message
    }

    /// 认不出的状态返回 nil（当作没有状态）。
    var record: ProgramStatusRecord? {
        guard let state = ProgramState(rawValue: state) else { return nil }
        return ProgramStatusRecord(state: state, kind: kind.flatMap(ProgramBlockKind.init(rawValue:)),
                                   progress: progress, app: app, title: title, message: message)
    }
}

/// 设备这一侧记着的各会话程序状态，以及哪些结果已经看过。纯逻辑，`RemoteMacClient` 持有一份。
nonisolated struct RemoteProgramStatusBook: Equatable, Sendable {
    /// Mac 报的（含 `idle`）。
    private(set) var reports: [UUID: ProgramStatusRecord] = [:]
    /// 在这台设备上看过的结果（`done` / `error`）。Mac 上没人看，它那边仍是「已完成」，这里不再提示。
    private var acknowledged: [UUID: ProgramStatusRecord] = [:]

    init() {}

    mutating func apply(_ update: RemoteProgramStatusUpdate) {
        if update.replacesAll {
            let listed = Set(update.entries.map(\.sessionID))
            for id in reports.keys where !listed.contains(id) { set(nil, for: id) }
        }
        for entry in update.entries { set(entry.status?.record, for: entry.sessionID) }
    }

    /// Mac 的会话列表里没了的，状态一并丢掉。
    mutating func retain(_ sessionIDs: Set<UUID>) {
        for id in reports.keys where !sessionIDs.contains(id) { set(nil, for: id) }
    }

    /// 连接断了：重连后 Mac 会再发一份快照。看过的记录留着，免得同一个结果重连后又亮起来。
    mutating func removeAllReports() {
        reports.removeAll()
    }

    /// 含 `idle`：有程序在用这套协议。
    func report(for sessionID: UUID) -> ProgramStatusRecord? { reports[sessionID] }

    /// 标签上显示的：`idle` 不显示，看过的结果不显示。
    func display(for sessionID: UUID) -> ProgramStatusRecord? {
        guard let report = reports[sessionID], report.state != .idle, acknowledged[sessionID] != report else { return nil }
        return report
    }

    mutating func acknowledge(_ sessionID: UUID) {
        guard let report = reports[sessionID], report.state == .done || report.state == .error else { return }
        acknowledged[sessionID] = report
    }

    private mutating func set(_ record: ProgramStatusRecord?, for sessionID: UUID) {
        reports[sessionID] = record
        // 换成了别的状态，之前看过的那个结果作废：下一次「已完成」是新的结果。
        if let seen = acknowledged[sessionID], seen != record { acknowledged[sessionID] = nil }
    }
}
