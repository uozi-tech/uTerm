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
    /// 页头固定在顶部：手指滚动时系统不把导航栏滑走。
    var pinsHeader: Bool = false
    @ViewBuilder var actions: Header
    @ViewBuilder var content: Content
    /// 系统 TabView 已为内容预留底部安全区，这里只补少量呼吸留白。
    var bottomInset: CGFloat = 12
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.mChrome) private var chrome

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
            .clipShape(MTopEdgeClip(clipsTop: chrome.hasSideStatusColumn))
        }
        .background(M.canvas)
        .navigationTitle(title)
        // 关掉栏的自动隐藏后，`.large` 会照常收起成小字；侧边状态栏形态下要真固定就得用 `.inlineLarge`。
        .modifier(MTitleDisplayMode(regularWidth: horizontalSizeClass == .regular
                                    || (pinsHeader && chrome.hasSideStatusColumn)))
        .mNavigationSubtitle(sub)
        .modifier(MPinnedHeader(isPinned: pinsHeader))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                actions.environment(\.mToolbarItem, true)
            }
        }
    }
}

/// iOS 27 起系统会在手指上滑时把导航栏滑出屏幕、反向滑动再滑回来（Duo 真机录到：栏高 82→24，
/// 标题移到屏幕外）。只有真实手势触发，程序设 `contentOffset` 不会，所以自动化用例看不到。
private struct MPinnedHeader: ViewModifier {
    var isPinned: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.0, *) {
            content.toolbarMinimizationBehavior(isPinned ? .never : .automatic, for: .navigationBar)
        } else {
            content
        }
    }
}

/// 状态栏在侧边时（Duo 外屏、展开横屏），系统不管标题模式都把标题钉在顶上、滚动不收起，
/// 内容一直从标题下面滑过。实测 `.large` / `.inlineLarge` / `.automatic` 一样，能不能看清全靠系统的
/// 滚动边缘虚化；实机截图里它没出现，标题直接压在内容上。这里让内容停在标题栏下沿，不再依赖它。
/// 不用 `toolbarBackground` 铺实底：它会让标题字号变大，顶边还留一条没盖住。
///
/// 始终挂着、只改形状：换成 `if` 分支的话，开合时 ScrollView 身份一变，滚动位置和页面状态都会丢。
/// path 可以大过 bounds，SwiftUI 不与 bounds 求交，所以其余方向不受影响。
nonisolated private struct MTopEdgeClip: Shape {
    var clipsTop: Bool

    func path(in rect: CGRect) -> Path {
        let outset: CGFloat = 4000
        let top = clipsTop ? rect.minY : rect.minY - outset
        return Path(CGRect(x: rect.minX - outset, y: top,
                           width: rect.width + outset * 2, height: rect.maxY + outset - top))
    }
}

extension MScreen where Header == EmptyView {
    init(title: String, sub: String? = nil, maxContentWidth: CGFloat = M.readableWidth,
         embedsNavigationStack: Bool = true, pinsHeader: Bool = false, bottomInset: CGFloat = 12,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, sub: sub, maxContentWidth: maxContentWidth,
                  embedsNavigationStack: embedsNavigationStack, pinsHeader: pinsHeader,
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
    var label: String = String(localized: "关闭", comment: "关闭按钮")
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
    /// 并排的第二个动作（如「生成密钥」旁的「导入密钥」），样式次一级。
    var secondaryTitle: String? = nil
    var secondaryIcon: String = "plus"
    var secondaryAction: (() -> Void)? = nil
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
                if let secondaryTitle, let secondaryAction {
                    MBtn(title: secondaryTitle, icon: secondaryIcon, kind: .secondary, action: secondaryAction)
                        .fixedSize()
                }
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 30)
    }
}
