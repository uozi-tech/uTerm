import SwiftUI

/// 大标题首页骨架（设计稿 `BigHeader` + 滚动体）。底部为标签栏预留安全间距。
/// 滚动体最小高度撑满可视区，使空状态等 `maxHeight: .infinity` 内容可垂直居中。
struct MScreen<Header: View, Content: View>: View {
    var title: String
    var sub: String? = nil
    @ViewBuilder var actions: Header
    @ViewBuilder var content: Content
    /// 系统 TabView 已为内容预留底部安全区，这里只补少量呼吸留白。
    var bottomInset: CGFloat = 12

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(M.sans(30, weight: .bold)).tracking(-0.6)
                        .foregroundStyle(M.text)
                    if let sub {
                        Text(sub).font(M.mono(13)).foregroundStyle(M.text3)
                    }
                }
                Spacer()
                HStack(spacing: 8) { actions }
            }
            .padding(.horizontal, 20)
            .padding(.top, M.topBreath)
            .padding(.bottom, 12)

            GeometryReader { proxy in
                ScrollView {
                    content
                        .padding(.bottom, bottomInset)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: M.readableWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(M.bg)
    }
}

extension MScreen where Header == EmptyView {
    init(title: String, sub: String? = nil, bottomInset: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.init(title: title, sub: sub, actions: { EmptyView() }, content: content, bottomInset: bottomInset)
    }
}

extension View {
    /// 宽屏（横屏 / iPad）把内容限制到易读宽度并水平居中；竖屏（窄屏）保持满宽不变。
    func mReadableColumn(_ maxWidth: CGFloat = M.readableWidth) -> some View {
        frame(maxWidth: maxWidth).frame(maxWidth: .infinity, alignment: .top)
    }
}

/// 空状态占位（设计稿各 Empty 态）。在所给空间内垂直居中。
struct MEmptyState: View {
    var icon: String
    var title: String
    var message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    @Environment(\.mAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 14) {
                MIcon(name: icon, size: 40, color: M.text4, weight: .light)
                    .frame(width: 84, height: 84)
                    .background(M.fillFaint)
                    .clipShape(Circle())
                Text(title).font(M.sans(18, weight: .semibold)).foregroundStyle(M.text)
                Text(message).font(M.sans(14)).foregroundStyle(M.text3)
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: 280)
                if let actionTitle, let action {
                    MBtn(title: actionTitle, icon: "plus", kind: .tinted, action: action)
                        .fixedSize()
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}
