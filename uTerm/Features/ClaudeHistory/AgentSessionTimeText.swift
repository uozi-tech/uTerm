import SwiftUI

/// 会话列表（和搜索结果里一个会话那一组）的第二行，开头是「多久以前」。两端共用，字体与颜色由外面给。
///
/// 时间是列表记的文件修改时间（后台重列时跟着变）；看过这个会话、读到了更新的内容（实时跟随接上的）时换成那个
/// 更新的时间，和对话顶栏的「最后活动」对得上。
///
/// 每一行都按整分钟自己重算一次：行里的字原来只在那一行的数据变了、被重画时才重算，停着没写的会话（跑完了、在等输入）
/// 会一直写着画出来那一刻的「刚刚」「56 秒钟前」。重算的只是这一个 `Text`，列表不跟着重排。
struct AgentSessionTimeText: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    /// 这一行的字；参数是更新的时间，没有为 nil。
    let text: (Date?) -> String

    /// 隔多久重算一次（秒，测试换成短的）。
    static var refreshInterval: TimeInterval = 60

    var body: some View {
        let activity = history.liveActivity(of: file)
        TimelineView(AgentSessionTimeSchedule(interval: Self.refreshInterval)) { _ in
            Text(text(activity))
        }
    }
}

/// 按固定间隔、对齐到间隔整数倍的时刻（60 秒就是整分钟，同 `.everyMinute`）：各行在同一拍换字，不各跳各的。
nonisolated struct AgentSessionTimeSchedule: TimelineSchedule {
    let interval: TimeInterval

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        let step = max(interval, 0.01)
        let start = (startDate.timeIntervalSinceReferenceDate / step).rounded(.down) * step
        return Entries(upcoming: start, step: step)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: TimeInterval
        let step: TimeInterval

        mutating func next() -> Date? {
            defer { upcoming += step }
            return Date(timeIntervalSinceReferenceDate: upcoming)
        }
    }
}
