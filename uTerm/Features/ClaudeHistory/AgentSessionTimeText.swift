import SwiftUI

/// 会话列表（和搜索结果里一个会话那一组）的第二行，开头是「多久以前」。两端共用，字体与颜色由外面给。
///
/// 时间平时是列表列出来那一刻的文件修改时间，不会自己变。看过这个会话、读到了更新的内容（实时跟随接上的）时换成那个
/// 更新的时间，和对话顶栏的「最后活动」对得上；只有这种行每分钟重算一次。
struct AgentSessionTimeText: View {
    let history: AgentHistoryModel
    let file: AgentHistorySessionFile
    /// 这一行的字；参数是更新的时间，没有为 nil。
    let text: (Date?) -> String

    var body: some View {
        if let activity = history.liveActivity(of: file) {
            TimelineView(.everyMinute) { _ in Text(text(activity)) }
        } else {
            Text(text(nil))
        }
    }
}
