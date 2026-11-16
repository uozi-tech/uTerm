import Foundation

/// 键盘条面板里一点就发的短语：启动 AI 命令行的命令、常用提示词、斜杠命令。用户可以在设置里增删、排序，
/// 整份以 JSON 存在本机偏好 `DefaultsKey.terminalKeyBarPhrases` 下（不跨设备同步）。
///
/// 只有 iOS 的键盘条用它，放在共享目录是因为它是纯数据与规则，不碰界面。
nonisolated enum TerminalPhraseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 在 shell 里启动 AI 命令行（`claude`、`codex`）。
    case launch
    /// 发给 AI 命令行的一句话。
    case prompt
    /// AI 命令行的斜杠命令。
    case slash

    var id: String { rawValue }
}

nonisolated struct TerminalPhrases: Codable, Equatable, Sendable {
    var launch: [String]
    var prompts: [String]
    var slash: [String]

    /// 默认的启动命令。不放 `--dangerously-skip-permissions` 这类一点就放开权限的参数，要的话用户自己加。
    static let defaultLaunch = [
        "claude",
        "claude -c",
        "claude -r",
        "codex",
        "codex resume --last",
        "codex resume",
    ]
    /// 常用提示词。不放一点就有破坏性的（回退、推送）。
    static let defaultPrompts = [
        "继续",
        "按你的方案做",
        "先说方案，别改代码",
        "这个方向不对，换个思路",
        "修复这个错误",
        "跑测试并修复失败项",
        "解释一下刚才的改动",
        "检查刚才的改动有没有问题",
        "总结当前进度和下一步",
        "提交当前改动",
    ]
    /// Claude Code 与 Codex 都支持的斜杠命令。
    static let defaultSlash = ["/clear", "/compact", "/resume", "/model", "/status", "/init"]

    static let defaults = TerminalPhrases(launch: defaultLaunch, prompts: defaultPrompts, slash: defaultSlash)

    /// 一组最多这么多条：面板高度固定，再多就要在面板里翻很久。
    static let maxPerKind = 30
    /// 一条最长这么多字符：键帽一行显示不下的长句也不该从键盘条发。
    static let maxLength = 200

    init(launch: [String], prompts: [String], slash: [String]) {
        self.launch = launch
        self.prompts = prompts
        self.slash = slash
    }

    /// 缺哪一组就用那一组的默认值：以后加新组时旧数据照样能读。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launch = try container.decodeIfPresent([String].self, forKey: .launch) ?? Self.defaultLaunch
        prompts = try container.decodeIfPresent([String].self, forKey: .prompts) ?? Self.defaultPrompts
        slash = try container.decodeIfPresent([String].self, forKey: .slash) ?? Self.defaultSlash
    }

    subscript(kind: TerminalPhraseKind) -> [String] {
        get {
            switch kind {
            case .launch: launch
            case .prompt: prompts
            case .slash: slash
            }
        }
        set {
            switch kind {
            case .launch: launch = newValue
            case .prompt: prompts = newValue
            case .slash: slash = newValue
            }
        }
    }

    // MARK: 存取

    /// 偏好里存的那串。空串（没改过）和解不开的都当默认值。
    static func decode(_ raw: String) -> TerminalPhrases {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              var phrases = try? JSONDecoder().decode(TerminalPhrases.self, from: data) else { return defaults }
        for kind in TerminalPhraseKind.allCases { phrases[kind] = cleaned(phrases[kind]) }
        return phrases
    }

    /// 面板按文本区分键帽（`ForEach` 的 id）：去掉空的、重复的、带换行的，防偏好被别处写坏后串键。
    private static func cleaned(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.compactMap { raw in
            let phrase = raw.trimmingCharacters(in: .whitespaces)
            guard !phrase.isEmpty, !phrase.contains(where: \.isNewline), seen.insert(phrase).inserted else { return nil }
            return phrase
        }
    }

    /// 等于默认值时存空串：以后默认值改了，没动过的用户跟着变。
    var encoded: String {
        guard self != Self.defaults else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: 编辑

    enum AddResult: Equatable, Sendable {
        case added
        case empty
        /// 含换行：发出去会在半截提交。
        case multiline
        case tooLong
        case duplicate
        case full
    }

    /// 首尾空白去掉再比：同一组里不能有两条一样的（键帽和长按菜单按文本区分）。
    @discardableResult
    mutating func add(_ text: String, to kind: TerminalPhraseKind) -> AddResult {
        let phrase = text.trimmingCharacters(in: .whitespaces)
        if phrase.isEmpty { return .empty }
        if phrase.contains(where: \.isNewline) { return .multiline }
        if phrase.count > Self.maxLength { return .tooLong }
        if self[kind].contains(phrase) { return .duplicate }
        if self[kind].count >= Self.maxPerKind { return .full }
        self[kind].append(phrase)
        return .added
    }

    mutating func remove(atOffsets offsets: IndexSet, from kind: TerminalPhraseKind) {
        var list = self[kind]
        for index in offsets.sorted(by: >) where list.indices.contains(index) {
            list.remove(at: index)
        }
        self[kind] = list
    }

    /// 与 SwiftUI 的 `onMove` 同一套参数：`destination` 是移动前数组里的插入位置。
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int, in kind: TerminalPhraseKind) {
        var list = self[kind]
        let valid = source.filter { list.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { list[$0] }
        let insertAt = destination - valid.filter { $0 < destination }.count
        for index in valid.sorted(by: >) { list.remove(at: index) }
        list.insert(contentsOf: moving, at: min(max(insertAt, 0), list.count))
        self[kind] = list
    }

    mutating func reset(_ kind: TerminalPhraseKind) {
        self[kind] = Self.defaults[kind]
    }
}
