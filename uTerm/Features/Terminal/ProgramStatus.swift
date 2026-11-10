import Foundation

/// OSC 7501（程序状态协议）：程序经 pty 报告自己在干什么，所以 SSH 下同样可用。
/// Claude Code 收到查询应答后才开始报告，Codex 一直在报告。
/// 规格：https://superlogical.com/rex/docs/build/program-status
nonisolated enum ProgramState: String, Equatable, Sendable, Codable {
    case idle, working, done, blocked, error

    /// 一条会话有多条记录时，标签显示最需要人处理的那条。
    fileprivate var priority: Int {
        switch self {
        case .blocked: 4
        case .error: 3
        case .working: 2
        case .done: 1
        case .idle: 0
        }
    }
}

nonisolated enum ProgramBlockKind: String, Equatable, Sendable, Codable {
    case permission, question, auth
}

nonisolated struct ProgramStatusRecord: Equatable, Sendable, Codable {
    var state: ProgramState
    var kind: ProgramBlockKind?
    var progress: Int?
    var app: String?
    var title: String?
    var message: String?
}

nonisolated enum ProgramStatusMessage: Equatable, Sendable {
    case query
    /// `id` 为 nil 时清掉全部记录。
    case clear(id: String?)
    /// 根记录的 `id` 是空串。
    case report(id: String, record: ProgramStatusRecord)

    private static let maxSequenceBytes = 4096
    private static let maxIDBytes = 128
    private static let maxAppBytes = 32
    private static let maxTitleBytes = 192
    private static let maxMessageBytes = 2048

    /// 按规格解析：坏的键值对跳过，未知键忽略，重复键以最后一个为准；超限、base64 解不开、
    /// 解出控制字符或 `state` 不认识时，整条丢弃。
    static func parse(_ data: ArraySlice<UInt8>) -> ProgramStatusMessage? {
        guard data.count <= maxSequenceBytes else { return nil }
        if data.first == UInt8(ascii: "?") { return .query }
        let pairs = keyValuePairs(data)
        guard let stateText = pairs["state"] else { return nil }

        let id = pairs["id"] ?? ""
        let app = pairs["app"]
        guard id.utf8.count <= maxIDBytes, (app?.utf8.count ?? 0) <= maxAppBytes else { return nil }
        if stateText == "clear" { return .clear(id: id.isEmpty ? nil : id) }
        guard let state = ProgramState(rawValue: stateText) else { return nil }

        var texts: [String: String] = [:]
        for (key, maxBytes) in [("title", maxTitleBytes), ("msg", maxMessageBytes)] {
            guard let encoded = pairs[key] else { continue }
            guard let text = decodedText(encoded, maxBytes: maxBytes) else { return nil }
            texts[key] = text
        }

        return .report(id: id, record: ProgramStatusRecord(
            state: state,
            kind: state == .blocked ? pairs["kind"].flatMap(ProgramBlockKind.init(rawValue:)) : nil,
            progress: progress(pairs["progress"], state: state),
            app: app,
            title: texts["title"],
            message: texts["msg"]))
    }

    private static func keyValuePairs(_ data: ArraySlice<UInt8>) -> [String: String] {
        var pairs: [String: String] = [:]
        for item in String(decoding: data, as: UTF8.self).split(separator: ":") {
            guard let separator = item.firstIndex(of: "=") else { continue }
            let key = item[..<separator]
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isLowercase }) else { continue }
            pairs[String(key)] = String(item[item.index(after: separator)...])
        }
        return pairs
    }

    private static func progress(_ text: String?, state: ProgramState) -> Int? {
        guard state == .working || state == .blocked,
              let text, let value = Int(text), (0...100).contains(value) else { return nil }
        return value
    }

    private static func decodedText(_ encoded: String, maxBytes: Int) -> String? {
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded + padding),
              bytes.count <= maxBytes,
              let text = String(data: bytes, encoding: .utf8),
              !text.unicodeScalars.contains(where: \.isControlCharacter) else { return nil }
        return text
    }
}

/// 一条终端会话当前的全部程序状态记录。
nonisolated struct ProgramStatusBoard: Equatable, Sendable, Codable {
    private static let maxRecords = 256

    private var records: [String: ProgramStatusRecord] = [:]

    /// 最需要人处理的那条记录；同级时根记录优先，其余按 id 排序以保证结果稳定。
    var summary: ProgramStatusRecord? {
        records.min { left, right in
            if left.value.state.priority != right.value.state.priority {
                return left.value.state.priority > right.value.state.priority
            }
            return left.key < right.key
        }?.value
    }

    /// 写入一条报告，返回这次变化是否值得打断用户。
    ///
    /// `idle` 永远不算：Codex 启动时没有 prompt 也会走一遍 `working → idle`，用户取消时
    /// 也报 `idle`。`done` / `error` 只看根记录，子记录是程序内部的后台任务，由主程序
    /// 自己处理；但任何一条记录卡住都得有人来点。
    mutating func apply(id: String, record: ProgramStatusRecord) -> Bool {
        let previous = records[id]
        guard previous != nil || records.count < Self.maxRecords else { return false }
        var resolved = record
        resolved.app = record.app ?? inheritedApp(for: id)
        records[id] = resolved

        switch record.state {
        case .blocked:
            return previous?.state != .blocked || previous?.message != record.message
        case .done, .error:
            return id.isEmpty && previous?.state != record.state
        case .idle, .working:
            return false
        }
    }

    /// 清掉 `id` 及其子记录；nil 清掉全部。
    mutating func clear(id: String?) {
        guard let id else {
            records.removeAll()
            return
        }
        records = records.filter { $0.key != id && !$0.key.hasPrefix(id + "/") }
    }

    /// 新 shell 提示符出现，上一个程序已经结束：它不可能还在运行或等待，但结果还没人看。
    mutating func programEnded() {
        records = records.filter { $0.value.state != .working && $0.value.state != .blocked }
    }

    /// 用户看到结果了：`done` / `error` 不再需要提示。
    mutating func acknowledgeResults() {
        for (id, record) in records where record.state == .done || record.state == .error {
            records[id]?.state = .idle
        }
    }

    private func inheritedApp(for id: String) -> String? {
        var path = id
        while let separator = path.lastIndex(of: "/") {
            path = String(path[..<separator])
            if let app = records[path]?.app { return app }
        }
        return id.isEmpty ? nil : records[""]?.app
    }
}

private extension Unicode.Scalar {
    /// 规格定义的控制字符：U+0000–U+001F、U+007F、U+0080–U+009F。
    nonisolated var isControlCharacter: Bool {
        value < 0x20 || (0x7F...0x9F).contains(value)
    }
}
