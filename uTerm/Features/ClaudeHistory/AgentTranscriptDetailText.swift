import SwiftUI

/// 对话顶栏的第二行（目录 · 分支 · 最后活动，子代理是 子代理 · 类型 · 最后活动）。两端共用，字体与颜色由外面给。
///
/// 只有这一行每分钟重算一次（「刚刚」「3 分钟前」自己往前走）；实时跟随接上新条目时随 `transcript.lastActivity` 变。
struct AgentTranscriptDetailText: View {
    let transcript: AgentTranscriptModel
    let metadata: AgentHistorySessionMetadata?

    var body: some View {
        TimelineView(.everyMinute) { _ in
            Text(AgentHistoryText.transcriptDetail(transcript, metadata: metadata))
        }
    }
}
