import Foundation

/// 主机名 / UUID → `ServerProfile` 的三级解析，抽成纯函数以便单测。
///
/// 规则（照抄 uTable 的连接解析）：
/// 1. 字符串能解析成 UUID 且命中某条档案 → 直达；
/// 2. 名字**精确**匹配 → 唯一即命中；
/// 3. 名字**忽略大小写**匹配 → 唯一即命中；
/// 4. 名字**前缀**匹配（忽略大小写）→ 唯一即命中。
///
/// 任何一级命中多条都是「歧义」，把候选（带 UUID）回给 CLI ——
/// CloudKit 同步下同名主机是常态，技能文档教模型改用 UUID 重试。
///
/// 入参是**已摘取的轻量候选**（id + name），不吃 `@Model`（不是 `Sendable`，也不便造夹具）；
/// `ControlHandler+Hosts.resolveHost` 负责取数据、翻错。快捷命令的名字解析
/// （`quick-run`）共用同一套规则，所以候选类型是通用的 `Candidate` 而不是主机专用类型。
nonisolated enum HostResolver {

    /// 一条可被名字指定的记录。主机与快捷命令共用。
    struct Candidate: Sendable, Equatable, Identifiable {
        let id: UUID
        let name: String

        init(id: UUID, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// 解析结果。`ambiguous` 带上全部候选，调用方把它们回给 CLI。
    enum Outcome: Sendable, Equatable {
        case matched(UUID)
        case ambiguous([Candidate])
        case notFound
    }

    /// 三级解析。`needle` 两端空白由调用方或本函数去掉；空串一律 `notFound`。
    static func resolve(_ needle: String, in candidates: [Candidate]) -> Outcome {
        let trimmed = needle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        // 1) UUID 直达 —— 歧义时技能文档教模型改用它，所以必须最优先且绝不可能歧义。
        if let uuid = UUID(uuidString: trimmed),
           let match = candidates.first(where: { $0.id == uuid }) {
            return .matched(match.id)
        }

        // 2) 名字精确匹配。CloudKit 同步能造出同名档案，所以这里也可能是多条。
        if let outcome = unique(candidates.filter { $0.name == trimmed }) {
            return outcome
        }

        // 3) 忽略大小写。
        let folded = trimmed.lowercased()
        if let outcome = unique(candidates.filter { $0.name.lowercased() == folded }) {
            return outcome
        }

        // 4) 唯一前缀。
        if let outcome = unique(candidates.filter { $0.name.lowercased().hasPrefix(folded) }) {
            return outcome
        }

        return .notFound
    }

    /// 一级匹配的收口：0 条继续往下试（nil），1 条命中，多条歧义。
    private static func unique(_ matches: [Candidate]) -> Outcome? {
        switch matches.count {
        case 0: return nil
        case 1: return .matched(matches[0].id)
        default: return .ambiguous(matches)
        }
    }
}
