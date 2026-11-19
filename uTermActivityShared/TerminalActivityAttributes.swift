import ActivityKit
import Foundation

/// 灵动岛 / 锁屏上的「终端状态」实时活动。App（`uTermMobile`）与组件扩展（`uTermLiveActivity`）共用这一份类型。
///
/// 文字全部由 App 算好再放进来（程序名、状态、底行说明都已本地化）：扩展不编译 `uTerm/` 的共享源码，
/// 也就没有第二份文案目录，跟随应用内语言设置也不会错。扩展只管画。
///
/// 只靠 App 自己更新，没有推送：App 被挂起后内容停在最后一次。为此 App 在挂起前推一次 `paused`，
/// 并给每次更新设 `staleDate` 兜底（见 `TerminalActivityCenter`）。
nonisolated struct TerminalActivityAttributes: ActivityAttributes, Sendable {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// 最多 3 行（展开的灵动岛只放得下 3 行），最需要人处理的在前。
        var rows: [Row]
        /// 没放下的行数。
        var overflow: Int
        /// 「还有 2 个」这类文字；`overflow` 为 0 时为 nil。
        var overflowText: String?
        /// 后台保持中：到这个时刻结束（扩展用它倒计时）。nil = 没有在保持。
        var keepUntil: Date?
        /// App 已经（或马上）被挂起，内容不再更新。行里的计时停走、整体变淡。
        var paused: Bool
        /// 底行：「已暂停，回到 uTerm 查看最新状态」/「后台保持中，还剩」（后面接倒计时）。nil = 不显示底行。
        var footer: String?
        /// 内容过期（`staleDate` 到了、App 没来得及推「已暂停」）时扩展显示的底行。和 `paused` 时的 `footer` 同一句。
        var pausedText: String
    }

    nonisolated struct Row: Codable, Hashable, Sendable, Identifiable {
        /// 标签页的 ID（点这一行打开 `uterm://terminal/<id>`）。
        var id: UUID
        /// 标签页标题（shell 设的标题或主机名）。
        var title: String
        /// 主机名；和标题相同时为 nil。
        var host: String?
        /// 「Claude Code」。
        var program: String
        /// 「等待确认」「运行中」。
        var status: String
        /// 紧凑态右边的短字：「需确认」「运行中」「完成」「出错」。
        var shortStatus: String
        var tone: Tone
        /// 进入当前状态的时刻（运行中的行据此计时）。
        var since: Date
    }

    /// 与 App 里 `ProgramStatusTone` 一一对应（扩展里看不到那个类型）。
    nonisolated enum Tone: String, Codable, Hashable, Sendable {
        case attention, working, done, failed
    }

    /// 深链接：`uterm://terminal/<标签页 ID>`。不带 ID 只打开工作区。
    nonisolated static let linkScheme = "uterm"
    nonisolated static let linkHost = "terminal"

    nonisolated static func link(tab id: UUID?) -> URL {
        var components = URLComponents()
        components.scheme = linkScheme
        components.host = linkHost
        if let id { components.path = "/" + id.uuidString }
        return components.url!
    }

    /// 解析深链接。不是终端链接返回 nil；是终端链接但没有（或不认得的）ID 时返回 `.some(nil)`。
    nonisolated static func tabID(from url: URL) -> UUID?? {
        guard url.scheme == linkScheme, url.host == linkHost else { return nil }
        let raw = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return .some(UUID(uuidString: raw))
    }
}
