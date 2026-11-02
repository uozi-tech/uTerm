import SwiftUI

/// 大标题首页骨架（设计稿 `BigHeader` + 滚动体）。底部为标签栏预留安全间距。
/// 滚动体最小高度撑满可视区，使空状态等 `maxHeight: .infinity` 内容可垂直居中。
/// 标题头悬浮于滚动体之上，内容从其下滚过：iOS 26 用 `safeAreaBar`，由系统液态玻璃
/// scroll edge effect 渐进虚化标题头 + 状态栏区域（自定义背景会与其冲突，不要加）；
/// iOS 26 以下无液态玻璃，回退 `safeAreaInset` + 毛玻璃材质、背景上延盖住状态栏。
struct MScreen<Header: View, Content: View>: View {
    var title: String
    var sub: String? = nil
    @ViewBuilder var actions: Header
    @ViewBuilder var content: Content
    /// 系统 TabView 已为内容预留底部安全区，这里只补少量呼吸留白。
    var bottomInset: CGFloat = 12
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let scroll = ScrollView {
                content
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity,
                           minHeight: max(0, proxy.size.height - headerHeight),
                           alignment: .top)
            }
            .scrollIndicators(.hidden)

            if #available(iOS 26.0, *) {
                scroll
                    .scrollEdgeEffectStyle(.soft, for: .top)
                    .safeAreaBar(edge: .top, spacing: 0) { headerBar }
            } else {
                scroll
                    .safeAreaInset(edge: .top, spacing: 0) {
                        headerBar.background {
                            Rectangle().fill(.ultraThinMaterial)
                                .ignoresSafeArea(edges: .top)
                        }
                    }
            }
        }
        .frame(maxWidth: M.readableWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(M.canvas)
    }

    private var headerBar: some View {
        // 按钮与「标题 + 副标题」整块垂直居中（按钮命中区已撑到 44pt，按末行基线对齐会把圆钮
        // 压到副标题那一行、比标题低出一截）。
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(M.sans(30, weight: .bold)).tracking(-0.6)
                    .foregroundStyle(M.text)
                if let sub {
                    Text(sub).font(M.mono(13)).foregroundStyle(M.text3)
                }
            }
            Spacer()
            // MRoundBtn 视觉 36pt、命中区 44pt：命中区自带 4pt 外沿，间距相应收为 0（视觉仍 8pt）。
            HStack(spacing: 0) { actions }
                .padding(.trailing, -4)
        }
        .padding(.horizontal, 20)
        .mTopClearance()
        .padding(.bottom, 12)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
    }
}

extension MScreen where Header == EmptyView {
    init(title: String, sub: String? = nil, bottomInset: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.init(title: title, sub: sub, actions: { EmptyView() }, content: content, bottomInset: bottomInset)
    }
}

/// 顶边净空：常规情况下只补 `M.topBreath`（状态栏已由安全区让开）；当这条视图实际贴着屏幕顶
/// （安全区顶边 ≈ 0：横屏 iPhone 隐藏状态栏、iPhone Duo 把状态栏与灵动岛挪到侧边、探针窗口）
/// 时补足到 `M.minTopClearance`，避免页头标题 / 返回钮顶到屏幕边与圆角。
///
/// 用视图自身在**屏幕坐标**里的顶边判断，而不是 `safeAreaInsets`：页头常挂在 `safeAreaBar` /
/// `safeAreaInset` 里，那里读到的安全区恒为 0，分不出「状态栏在上面」与「状态栏在侧边」。
private struct MTopClearance: ViewModifier {
    var base: CGFloat
    /// 本视图顶边离屏幕顶的距离；首帧未量到前按「状态栏在顶」处理（不跳动）。
    @State private var originY: CGFloat = 44

    func body(content: Content) -> some View {
        content
            .padding(.top, max(base, M.minTopClearance - max(0, originY)))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY.rounded() } action: { originY = $0 }
    }
}

extension View {
    /// 页头 / 贴顶工具条的顶边留白：见 `MTopClearance`。
    func mTopClearance(_ base: CGFloat = M.topBreath) -> some View {
        modifier(MTopClearance(base: base))
    }

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
