import SwiftUI

/// 大标题首页骨架：**系统导航栏**（大标题 + 副标题 + 右侧工具栏按钮）+ 滚动体。
///
/// 改前是自绘页头（标题 + 圆钮）挂在 `safeAreaBar` 里。iPhone Duo 上它有两处不对（实机反馈）：
/// - 系统会把**标准**导航栏 / 工具栏按钮挪到侧边状态栏下方那一列（Apple「Prepare your app for
///   iPhone Duo」），自绘页头不会，按钮仍挤在顶上、侧边那列空着；
/// - Duo 的状态栏在侧边、顶部没有安全区，自绘页头的 scroll edge effect 没有落点，滚上去的内容
///   与标题直接叠在一起、不虚化。
/// 用系统导航栏后，按钮位置、顶边虚化、大标题随滚动收起都由系统按设备形态处理。
///
/// 页面本身没有包在 `NavigationStack` 里时（主机 / 终端 / 文件三个标签的首页）由本视图补一层；
/// 已在自己的栈里、要下钻的页面（命令、设置）传 `embedsNavigationStack: false`。
struct MScreen<Header: View, Content: View>: View {
    var title: String
    var sub: String? = nil
    /// 内容的最大宽度（水平居中）。列表页取易读宽度；卡片网格页传 `M.gridContentWidth`。
    var maxContentWidth: CGFloat = M.readableWidth
    var embedsNavigationStack: Bool = true
    @ViewBuilder var actions: Header
    @ViewBuilder var content: Content
    /// 系统 TabView 已为内容预留底部安全区，这里只补少量呼吸留白。
    var bottomInset: CGFloat = 12
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if embedsNavigationStack {
            NavigationStack { page }
        } else {
            page
        }
    }

    private var page: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: maxContentWidth)
                    // 最小高度撑满可视区，使空状态等 `maxHeight: .infinity` 内容可垂直居中。
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background(M.canvas)
        .navigationTitle(title)
        .modifier(MTitleDisplayMode(regularWidth: horizontalSizeClass == .regular))
        .mNavigationSubtitle(sub)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                actions.environment(\.mToolbarItem, true)
            }
        }
    }
}

extension MScreen where Header == EmptyView {
    init(title: String, sub: String? = nil, maxContentWidth: CGFloat = M.readableWidth,
         embedsNavigationStack: Bool = true, bottomInset: CGFloat = 12,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, sub: sub, maxContentWidth: maxContentWidth,
                  embedsNavigationStack: embedsNavigationStack,
                  actions: { EmptyView() }, content: content, bottomInset: bottomInset)
    }
}

/// 标题显示方式。常规宽度（iPhone Duo 展开、iPad）用 iOS 26 的 `.inlineLarge`：大标题与工具栏
/// 按钮、状态栏同在顶行，不再在按钮行下面单占一行（实机反馈：Duo 展开时标题应与状态栏同行）。
/// 紧凑宽度（iPhone、Duo 折叠）保留标准大标题——滚动时收起成小标题，是那里的惯例。
private struct MTitleDisplayMode: ViewModifier {
    var regularWidth: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.toolbarTitleDisplayMode(regularWidth ? .inlineLarge : .large)
        } else {
            content.navigationBarTitleDisplayMode(.large)
        }
    }
}

/// 导航栏副标题（iOS 26 起系统原生；更早的系统不显示）。
private struct MNavigationSubtitle: ViewModifier {
    var text: String?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), let text {
            content.navigationSubtitle(text)
        } else {
            content
        }
    }
}

extension View {
    /// 导航栏副标题：iOS 26 起交给系统 `.navigationSubtitle`，更早的系统不显示。
    func mNavigationSubtitle(_ text: String?) -> some View {
        modifier(MNavigationSubtitle(text: text))
    }
}

/// 全屏覆盖层导航栏左上角的「关闭」：iOS 26 用系统的关闭角色（液态玻璃 ×，随工具栏挪到
/// iPhone Duo 的侧边列），更早的系统画一个同样语义的 × 按钮。
struct MToolbarCloseButton: View {
    var label: String = "关闭"
    var action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityLabel(Text(label))
        } else {
            Button(action: action) {
                Image(systemName: MGlyph.symbol("x"))
            }
            .accessibilityLabel(Text(label))
        }
    }
}

private struct MToolbarItemKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 视图是否作为系统工具栏按钮呈现（`MScreen` 的 `actions` 里为 true）。
    /// `MRoundBtn` 据此改用系统工具栏按钮的外观，不再自画圆底。
    var mToolbarItem: Bool {
        get { self[MToolbarItemKey.self] }
        set { self[MToolbarItemKey.self] = newValue }
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
