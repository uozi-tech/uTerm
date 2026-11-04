import SwiftUI

/// 系统 UI 在屏幕上**实际**占的位置。
///
/// iPhone Duo 的状态栏只占屏幕一角（竖屏：右上角一小块；横屏：右侧一列的顶部），但安全区是整条矩形：
/// 竖屏时整个顶边都算进安全区，横屏时整列右边都算进安全区。只按安全区布局，状态栏旁边那一截
/// 横条、那一列状态栏下面的空间就都浪费了，居中的页面也是按「去掉那一列」的宽度居中、看起来偏左。
/// iOS 27.1 起系统用「遮挡」类保留区（`ReservedRegion.Kind.occlusion`）报告状态栏真正占的矩形，
/// 用「容器边距」（`ContentMarginGuide.container`）报告屏幕圆角处该留的边距——这里在根视图量一次，
/// 经环境值下发，需要贴着状态栏 / 屏幕角布局的视图据此计算。
nonisolated struct MChromeGeometry: Equatable, Sendable {
    /// 根视图（安全区内）在全局坐标里的矩形。
    var root: CGRect = .zero
    var safeAreaInsets = EdgeInsets()
    /// 状态栏实际占的矩形（全局坐标，含系统给的交互边距）。不在顶边或系统不报告时为 nil。
    var statusBar: CGRect?
    /// 容器边距（屏幕圆角等）。iOS 27.1 以下为 0。
    var containerMargins = EdgeInsets()
    /// 系统给「贴顶的自绘横条（高 `MChromeGeometry.topBarExtent`）」划的区域（全局坐标）：
    /// 已避开状态栏、灵动岛与屏幕圆角（UIKit `UIView.LayoutRegion.bar(onEdge: .top, extent:)`，
    /// iOS 27.1）。真机 Duo 不把状态栏报成遮挡保留区（实测只有一块无关的非活动区），状态栏
    /// 旁边那截能不能放东西、能放多宽，只有这个接口说得准。iOS 27.1 以下为 nil。
    var topBar: CGRect?
    /// 横向角落适配的安全区（`UIView.LayoutRegion.safeArea(cornerAdaptation: .horizontal)`，全局坐标）：
    /// 把屏幕角上的系统元素（Duo 竖屏右上角的状态栏）当「角」，在横向让开它、纵向不再整条让出顶边。
    /// 它伸进顶部安全区时，右沿就是状态栏左侧能用到的位置。iOS 26 以下为 nil。
    var cornerSafeArea: CGRect?
    /// 这台设备是展开的 iPhone Duo（见 `isUnfoldedPhone(idiom:screenSize:)`）。
    var isUnfoldedPhone = false

    /// 探测顶部横条区域时用的横条高度 = 工作区标签条高度。
    static let topBarExtent: CGFloat = 48
    /// 手机屏幕短边达到这个宽度才算展开的折叠屏：普通 iPhone 最宽约 440pt，Duo 折叠 466pt、展开 669pt。
    static let unfoldedPhoneMinShortSide: CGFloat = 600

    /// 看整块屏幕而不是窗口：Duo 内屏分屏时窗口只有约 330pt 宽，状态栏仍只占屏幕一角。
    static func isUnfoldedPhone(idiom: UIUserInterfaceIdiom, screenSize: CGSize) -> Bool {
        idiom == .phone && min(screenSize.width, screenSize.height) >= unfoldedPhoneMinShortSide
    }
    #if DEBUG
    /// 系统报告的全部遮挡区（未过滤、含非活动），只给布局诊断浮层看。
    var rawOcclusion: [RawRegion] = []
    struct RawRegion: Equatable, Sendable { var frame: CGRect; var active: Bool }
    #endif

    /// 整块屏幕（全局坐标）。
    var screen: CGRect {
        CGRect(x: root.minX - safeAreaInsets.leading, y: root.minY - safeAreaInsets.top,
               width: root.width + safeAreaInsets.leading + safeAreaInsets.trailing,
               height: root.height + safeAreaInsets.top + safeAreaInsets.bottom)
    }

    static func measure(_ proxy: GeometryProxy) -> MChromeGeometry {
        var geometry = MChromeGeometry(root: proxy.frame(in: .global), safeAreaInsets: proxy.safeAreaInsets)
        if #available(iOS 27.1, *) {
            let origin = geometry.root.origin
            let screenTop = geometry.screen.minY
            let screen = geometry.screen
            let insets = geometry.safeAreaInsets
            geometry.statusBar = proxy.reservedRegions(kind: .occlusion)
                .filter(\.isActive)
                .map { $0.frame.offsetBy(dx: origin.x, dy: origin.y) }
                .first { bar in
                    // 只认与安全区对得上的状态栏矩形。转屏途中系统会先报几次过期 / 转置的矩形
                    // （实测竖屏先后报过 (0,0,82×144)、(585,0,84×124)，稳定后才是 (525,0,144×82)），
                    // 按那些布局要么让错位置、要么整个模式不生效（实机：竖屏标签条没进状态行）。
                    guard bar.minY <= screenTop + 1, abs(bar.maxX - screen.maxX) < 1 else { return false }
                    let isRow = insets.top > 0 && abs(bar.height - insets.top) <= 2 && bar.width < screen.width / 2
                    let isColumn = insets.trailing > 0 && abs(bar.width - insets.trailing) <= 2
                    return isRow || isColumn
                }
            geometry.containerMargins = proxy.contentMargins(for: .container)
            #if DEBUG
            geometry.rawOcclusion = proxy.reservedRegions(kind: .occlusion, options: .includeInactive)
                .map { RawRegion(frame: $0.frame.offsetBy(dx: origin.x, dy: origin.y), active: $0.isActive) }
            #endif
        }
        return geometry
    }
}

nonisolated extension MChromeGeometry {
    /// 状态栏在右侧一列的顶部（Duo 折叠、Duo 展开横屏）：该列宽度（= 右侧安全区），以及状态栏
    /// 底边距根视图顶边的距离——这一列在它下面是空的、可以用。
    var statusColumn: (width: CGFloat, statusBottom: CGFloat)? {
        guard let bar = statusBar, safeAreaInsets.trailing > 0,
              abs(bar.width - safeAreaInsets.trailing) <= 2 else { return nil }
        return (safeAreaInsets.trailing, bar.maxY - root.minY)
    }

    /// 状态栏在顶部一行的右端（Duo 展开竖屏）：整条顶边都算安全区，但状态栏只占右边一块，
    /// 左边那一截可以放自己的东西。返回该行高度（= 顶部安全区）。
    ///
    /// 顶部横条区域的上沿在哪台设备上都高于顶部安全区（模拟器实测上沿都是 10：iPhone 18 Pro 安全区 62、
    /// iPhone 17e 47、iPad 32），它本身分不出「顶行有空位」。普通 iPhone 顶行正中是灵动岛 / 刘海，iPad
    /// 的状态栏横跨整行，只有展开的 Duo 状态栏才缩在一角，所以先按设备判断。
    /// 退路是遮挡保留区里的状态栏矩形（vphone 报告、真机不报）。
    var statusRowHeight: CGFloat? {
        guard safeAreaInsets.top > 0, safeAreaInsets.trailing == 0 else { return nil }
        if let topBar {
            guard isUnfoldedPhone else { return nil }
            return topBar.minY < screen.minY + safeAreaInsets.top - 1 ? safeAreaInsets.top : nil
        }
        guard let bar = statusBar,
              abs(bar.height - safeAreaInsets.top) <= 2, bar.minX > screen.midX else { return nil }
        return safeAreaInsets.top
    }
}

private struct MChromeGeometryKey: EnvironmentKey {
    static let defaultValue = MChromeGeometry()
}

extension EnvironmentValues {
    /// 根视图量到的系统 UI 几何（见 `MChromeGeometry`）。
    var mChrome: MChromeGeometry {
        get { self[MChromeGeometryKey.self] }
        set { self[MChromeGeometryKey.self] = newValue }
    }
}

/// 在根视图上量 `MChromeGeometry` 并下发给子树。
private struct MChromeMeasurer: ViewModifier {
    @State private var geometry = MChromeGeometry()
    @State private var probe = MChromeProbeResult()
    /// 换 id 即重建量尺视图、再量一次（见下方补测）。
    @State private var pass = 0
    @State private var followUp: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .environment(\.mChrome, merged)
            .background {
                MTopBarProbe { if probe != $0 { probe = $0 } }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .background {
                Color.clear
                    .id(pass)
                    .onGeometryChange(for: MChromeGeometry.self) { MChromeGeometry.measure($0) } action: { measured in
                        guard measured != geometry else { return }
                        geometry = measured
                        // 转屏 / 开合后系统的保留区要过一会儿才稳定，而稳定那一下不一定再触发布局：
                        // 几何一变就在 0.4 s、1.2 s 各补量一次，直到量到的值不再变化。
                        followUp?.cancel()
                        followUp = Task { @MainActor in
                            for delay in [400, 800] {
                                try? await Task.sleep(for: .milliseconds(delay))
                                if Task.isCancelled { return }
                                pass &+= 1
                            }
                        }
                    }
            }
    }
}

extension MChromeMeasurer {
    private var merged: MChromeGeometry { geometry.merging(probe) }
}

extension MChromeGeometry {
    /// 叠上 UIKit 探针量到的、SwiftUI 量不到的那几项。
    func merging(_ probe: MChromeProbeResult) -> MChromeGeometry {
        var g = self
        g.topBar = probe.topBar
        g.cornerSafeArea = probe.cornerSafeArea
        g.isUnfoldedPhone = probe.isUnfoldedPhone
        return g
    }
}

/// 全屏的 UIKit 探针：向系统要「贴顶横条」的布局区域（`UIView.LayoutRegion.bar`），换算成
/// 窗口坐标报上去。布局、安全区一变就重算。SwiftUI 没有对应接口，只能借一层 UIView。
nonisolated struct MChromeProbeResult: Equatable, Sendable {
    var topBar: CGRect?
    var cornerSafeArea: CGRect?
    var isUnfoldedPhone = false
}

private struct MTopBarProbe: UIViewRepresentable {
    var onChange: (MChromeProbeResult) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((MChromeProbeResult) -> Void)?
        private var last: MChromeProbeResult?

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        private func report() {
            guard let window else { return }
            var result = MChromeProbeResult()
            result.isUnfoldedPhone = MChromeGeometry.isUnfoldedPhone(idiom: traitCollection.userInterfaceIdiom,
                                                                     screenSize: window.screen.bounds.size)
            if #available(iOS 26.0, *) {
                let insets = edgeInsets(for: .safeArea(cornerAdaptation: .horizontal))
                result.cornerSafeArea = convert(bounds.inset(by: insets), to: window)
            }
            if #available(iOS 27.1, *) {
                let insets = edgeInsets(for: .bar(onEdge: UIRectEdge.top, extent: MChromeGeometry.topBarExtent))
                result.topBar = convert(bounds.inset(by: insets), to: window)
            }
            guard last != result else { return }
            last = result
            // 布局过程中改 SwiftUI 状态会被警告 / 丢弃：挪到下一轮主循环。
            DispatchQueue.main.async { [weak self] in self?.onChange?(result) }
        }
    }
}

/// 让一条贴顶的自绘标签条 / 工具条用上状态栏旁边的空间，同时不压到状态栏、不挤进屏幕圆角：
/// - 状态栏在顶行（Duo 展开竖屏）且本条贴着屏幕顶：条高撑到状态行高度，与状态栏同一行；
/// - 与状态栏矩形上下有重叠：右侧让出与状态栏重叠的那一截；
/// - 贴着屏幕左上角（Duo 折叠 / 横屏没有顶部安全区）：左侧补系统给的容器边距，避开圆角。
/// 本条自己量全局位置（外框不受这里加的内边距影响，不会来回抖）。
private struct MStatusBarAvoidance: ViewModifier {
    /// 状态行里状态栏底板（时间 / 电池 / 灵动岛）从右沿算起占的宽度 + 8pt 间隙。见 body 里的保底让位。
    static let statusPlatterReserve: CGFloat = 136
    var minHeight: CGFloat
    @Environment(\.mChrome) private var chrome
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        let screen = chrome.screen
        let atTop = frame.height > 0 && frame.minY <= screen.minY + 1
        let atLeading = frame.width > 0 && frame.minX <= screen.minX + 1
        var trailing: CGFloat = 0
        var leading: CGFloat = atTop && atLeading ? chrome.containerMargins.leading : 0
        if let bar = chrome.topBar, atTop {
            // 系统划的横条区域避开了灵动岛与圆角：本条超出它的左右两截都让出来。
            if atLeading { leading = max(0, bar.minX - frame.minX) }
            trailing = max(0, frame.maxX - bar.maxX)
        }
        // 横条区域不一定避开状态栏（真机竖屏实测：标签条尾部的按钮钻到了状态栏底板下面）。
        // 横向角落适配的安全区伸进状态行时，它的右沿就是状态栏左边：按它再让一次。
        let inRow = atTop && chrome.statusRowHeight != nil
        if inRow, let corner = chrome.cornerSafeArea, corner.minY < screen.minY + chrome.safeAreaInsets.top - 1 {
            trailing = max(trailing, frame.maxX - corner.maxX)
        }
        // 三路都没让出状态栏（真机竖屏：遮挡保留区不报状态栏；横条区域与角落安全区都横跨整宽）时，
        // 按真机实测的状态栏底板宽度保底让位：底板约占 545–650pt（屏宽 669），右沿留 136pt。
        if inRow, chrome.statusBar == nil, frame.maxX > screen.maxX - Self.statusPlatterReserve {
            trailing = max(trailing, frame.maxX - (screen.maxX - Self.statusPlatterReserve))
        }
        // vphone 上横条区域不避开状态栏、遮挡保留区却报了状态栏矩形；两路取较大的让位。
        if let bar = chrome.statusBar, frame.minY < bar.maxY, frame.maxX > bar.minX {
            trailing = max(trailing, frame.maxX - bar.minX + 8)
        }
        let rowHeight = inRow ? (chrome.statusRowHeight ?? minHeight) : minHeight
        let height = max(minHeight, rowHeight)
        // 状态行里：内容（高 minHeight）的中线对齐状态栏图标的中线。图标在 82pt 行里偏下，
        // 中线约在行高 0.56 处（vphone 与真机实测都在 45pt 上下），而不是几何正中 41pt。
        let topPad = inRow ? max(0, min(height - minHeight, (rowHeight * 0.56 - minHeight / 2).rounded())) : 0
        return content
            .environment(\.mInStatusRow, inRow)
            .frame(height: minHeight)
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .padding(.top, topPad)
            .frame(height: height, alignment: .top)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
    }
}

private struct MInStatusRowKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 本条是否坐在 Duo 竖屏的状态栏那一行（行更高，标签与按钮相应放大，见 WorkspaceTabStrip）。
    var mInStatusRow: Bool {
        get { self[MInStatusRowKey.self] }
        set { self[MInStatusRowKey.self] = newValue }
    }
}

/// 全屏居中的过场页（连接中、应用锁）：状态栏在右侧一列时（Duo），横向按整块屏幕居中，而不是
/// 按「去掉那一列」的宽度居中（那样在屏幕上看是偏左的）。其它设备不变。
private struct MScreenCentering: ViewModifier {
    @Environment(\.mChrome) private var chrome

    func body(content: Content) -> some View {
        if chrome.statusColumn != nil {
            content.ignoresSafeArea(.container, edges: .horizontal)
        } else {
            content
        }
    }
}

extension View {
    /// 根视图调用一次：量系统 UI 几何并经 `\.mChrome` 下发。
    func mMeasuresChrome() -> some View { modifier(MChromeMeasurer()) }

    /// 见 `MStatusBarAvoidance`。`minHeight` 是本条平时的高度。
    func mAvoidsStatusBar(minHeight: CGFloat) -> some View {
        modifier(MStatusBarAvoidance(minHeight: minHeight))
    }

    /// 见 `MScreenCentering`。
    func mCentersOnScreen() -> some View { modifier(MScreenCentering()) }

    /// 挂在横向 ScrollView 上：内容不进侧边安全区。
    ///
    /// ScrollView 默认把内容画进安全区。Duo 横屏时右侧安全区是状态栏那一列，内容滚进去看得见、
    /// 却点不到（实机反馈）。画面和命中区都收到安全区边界：`clipped` 只裁画面，不限制命中。
    /// 滚到底时最后一项正好停在边界上，不会缺内容。
    func mKeepsScrollContentInSafeArea() -> some View {
        clipped().contentShape(Rectangle())
    }
}

extension Edge.Set {
    /// 工作区会话正文（终端 / 文件 / Agent）的底色往哪些安全区延伸：左右与底边照常铺满
    /// （横屏刘海、Duo 侧列、Home 条那一截与正文同色），**顶边不延伸**。Duo 竖屏时工作区伸进
    /// 顶部安全区、标签条坐在状态栏那一行，正文的上沿恰好贴着安全区边界——颜色背景默认四边都
    /// 延伸，正文底色会往上铺满 82pt、盖住排在它前面的标签条（实机：左格标签条整条不见）。
    static let mSessionBody: Edge.Set = [.horizontal, .bottom]
}

