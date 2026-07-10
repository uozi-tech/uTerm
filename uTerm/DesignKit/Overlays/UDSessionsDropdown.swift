import SwiftUI

/// 单条会话历史记录（AI 助手会话列表项）。纯展示输入，不依赖任何 domain model。
struct UDChatSessionItem: Identifiable {
    let id = UUID()
    /// 会话标题。
    let title: String
    /// 首条消息预览（单行截断）。
    let preview: String
    /// 更新时间（已格式化的相对时间字串）。
    let updated: String
    /// 是否为当前活动会话。
    let active: Bool

    init(title: String, preview: String, updated: String, active: Bool = false) {
        self.title = title
        self.preview = preview
        self.updated = updated
        self.active = active
    }
}

/// uTerm DesignKit 会话历史下拉 —— AI 助手的会话列表浮层（设计稿 `Components.html`）。
///
/// 纯展示组件：只读 `UD` token + 普通值输入。实体浮层面 `UD.overlay` + `UD.border`
/// 描边 + `.md` 投影 + 顶部内高光。活动会话用 `UD.accent` 软底高亮，尾部「新建对话」按钮。
struct UDSessionsDropdown: View {
    /// 会话列表。
    let sessions: [UDChatSessionItem]
    /// 「新建对话」回调。
    let onNew: () -> Void

    init(sessions: [UDChatSessionItem] = .sample, onNew: @escaping () -> Void = {}) {
        self.sessions = sessions
        self.onNew = onNew
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(UD.overlay)
        )
        .overlay(
            // 浮层细发丝边：单层 UD.border（白 7% / 黑 10%），无内高光。
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(UD.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .udShadow(.md)
    }

    // MARK: - 头部

    private var header: some View {
        Text("会话历史")
            .font(UD.font(10.5))
            .foregroundStyle(UD.text4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.bottom, 4)
            .padding(.horizontal, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
    }

    // MARK: - 列表

    private var list: some View {
        VStack(spacing: 1) {
            ForEach(sessions) { session in
                row(session)
            }
        }
        .padding(4)
    }

    private func row(_ session: UDChatSessionItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(session.title)
                    .font(UD.font(12.5, weight: session.active ? .medium : .regular))
                    .foregroundStyle(session.active ? UD.text : UD.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(session.updated)
                    .font(UD.font(10))
                    .foregroundStyle(UD.text4)
            }

            Text(session.preview)
                .font(UD.font(11))
                .foregroundStyle(UD.text4)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            // 选中行 = accent 14% 填充、无 accent 描边（v2）。
            RoundedRectangle(cornerRadius: UD.Radius.sm)
                .fill(session.active ? UD.accentSoft : .clear)
        )
    }

    // MARK: - 尾部

    private var footer: some View {
        Button(action: onNew) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(UD.font(11))
                Text("新建对话")
                    .font(UD.font(12))
                Spacer(minLength: 0)
                Text("⌘⇧N")
                    .font(UD.mono(10))
                    .foregroundStyle(UD.text4)
            }
            .foregroundStyle(UD.text2)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(footerBackground)
            .overlay(alignment: .top) {
                Rectangle().fill(UD.border).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { footerHovered = $0 }
    }

    @State private var footerHovered = false

    private var footerBackground: Color {
        footerHovered ? UD.panelHover : .clear
    }
}

extension Array where Element == UDChatSessionItem {
    /// 设计稿示例会话列表。
    static var sample: [UDChatSessionItem] {
        [
            UDChatSessionItem(title: "nginx 502 排查",
                              preview: "为什么 nginx 偶尔会 502？",
                              updated: "刚刚",
                              active: true),
            UDChatSessionItem(title: "配置 supervisor",
                              preview: "帮我写一个 supervisor 配置",
                              updated: "今天 11:42"),
            UDChatSessionItem(title: "TLS 证书续期",
                              preview: "certbot renew 失败怎么办",
                              updated: "昨天"),
            UDChatSessionItem(title: "rsync 增量备份",
                              preview: "怎么用 rsync 做增量备份",
                              updated: "3 天前"),
        ]
    }
}

#Preview {
    UDSessionsDropdown()
        .padding(40)
        .background(UD.bg)
}
