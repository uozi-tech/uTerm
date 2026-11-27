import SwiftUI

/// 系统 UI 在屏幕上**实际**占的位置。
///
/// iPhone Duo 的状态栏只占屏幕一角（竖屏：右上角一小块；横屏：右侧一列的顶部），但安全区是整条矩形：
/// 竖屏时整个顶边都算进安全区，横屏时整列右边都算进安全区。只按安全区布局，状态栏旁边那一截
/// 横条、那一列状态栏下面的空间就都浪费了，居中的页面也是按「去掉那一列」的宽度居中、看起来偏左。
/// iOS 27.1 起系统用「遮挡」类保留区（`UIView.ReservedRegion.Kind.occlusion`）报告状态栏真正占的矩形，
/// 用「容器边距」（`ContentMarginGuide.container`）报告屏幕圆角处该留的边距，用 `verticalBarEdge`
/// 报告侧边那一列在哪边——这里在根视图量一次，经环境值下发，需要贴着状态栏 / 屏幕角布局的视图据此计算。
///
/// 状态栏矩形只能从 UIKit 读（`MTopBarProbe`）：Duo 真机上 SwiftUI 的 `GeometryProxy.reservedRegions`
/// 在任何姿态下都不含状态栏（2026-11-15 `FoldableChromeProbeTests` 实录），UIKit 每次都报。
nonisolated struct MChromeGeometry: Equatable, Sendable {
    /// 根视图（安全区内）在全局坐标里的矩形。
    var root: CGRect = .zero
    var safeAreaInsets = EdgeInsets()
    /// 状态栏实际占的矩形（全局坐标，含系统给的交互边距）。不在顶边、与安全区对不上或系统不报告时为 nil。
    /// 由 UIKit 探针量（见类型注释）。
    var statusBar: CGRect?
    /// 系统放侧边竖栏的那一边（`UITraitCollection.verticalBarEdge`，iOS 27.1）：Duo 上就是状态栏那一列。
    /// 系统说没有竖栏（普通 iPhone / iPad、Duo 展开竖屏）为 nil。只在 `reportsVerticalBarEdge` 时有意义。
    var verticalBarEdge: HorizontalEdge?
    /// 系统能回答 `verticalBarEdge`（iOS 27.1 起）。否则侧列只能按安全区猜。
    var reportsVerticalBarEdge = false
    /// 容器边距（屏幕圆角等）。iOS 27.1 以下为 0。
    var containerMargins = EdgeInsets()
    /// 系统给「贴顶的自绘横条（高 `MChromeGeometry.topBarExtent`）」划的区域（全局坐标）：
    /// 已避开状态栏、灵动岛与屏幕圆角（UIKit `UIView.LayoutRegion.bar(onEdge: .top, extent:)`，
    /// iOS 27.1）。iOS 27.1 以下为 nil。
    var topBar: CGRect?
    /// 横向角落适配的安全区（`UIView.LayoutRegion.safeArea(cornerAdaptation: .horizontal)`，全局坐标）：
    /// 把屏幕角上的系统元素（Duo 竖屏右上角的状态栏）当「角」，在横向让开它、纵向不再整条让出顶边。
    /// 它伸进顶部安全区时，右沿就是状态栏左侧能用到的位置。iOS 26 以下为 nil。
    var cornerSafeArea: CGRect?
    /// 系统在侧边竖栏那一边（`verticalBarEdge`）给「贴边的自绘竖条（宽 `topBarExtent`）」划的区域（全局坐标，
    /// UIKit `UIView.LayoutRegion.bar(onEdge:extent:)`，iOS 27.1）。状态栏里的时间、信号按它的中线排，
    /// 见 `statusColumnControlCenter`。没有竖栏时为 nil。
    var sideBar: CGRect?
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
    #endif
    struct RawRegion: Equatable, Sendable { var frame: CGRect; var active: Bool }

    /// 整块屏幕（全局坐标）。
    var screen: CGRect {
        CGRect(x: root.minX - safeAreaInsets.leading, y: root.minY - safeAreaInsets.top,
               width: root.width + safeAreaInsets.leading + safeAreaInsets.trailing,
               height: root.height + safeAreaInsets.top + safeAreaInsets.bottom)
    }

    static func measure(_ proxy: GeometryProxy) -> MChromeGeometry {
        var geometry = MChromeGeometry(root: proxy.frame(in: .global), safeAreaInsets: proxy.safeAreaInsets)
        if #available(iOS 27.1, *) {
            geometry.containerMargins = proxy.contentMargins(for: .container)
        }
        return geometry
    }

    /// 从系统报的活动遮挡区里挑出状态栏：贴着屏幕顶、贴着左或右沿，且与安全区对得上——
    /// 顶行右端的一块（Duo 展开竖屏），或宽度等于侧边安全区的一列（Duo 折叠、展开横屏；折叠横屏在左边）。
    /// 转屏途中系统会先报几次过期 / 转置的矩形（实测竖屏先后报过 (0,0,82×144)、(585,0,84×124)，
    /// 稳定后才是 (525,0,144×82)），按那些布局要么让错位置、要么整个模式不生效，所以对不上就不认。
    /// 前置摄像头那一小块（Duo 折叠 (399,29 37×37)）不贴屏幕顶，自然排除。
    static func statusBar(among regions: [CGRect], screen: CGRect, safeArea insets: EdgeInsets) -> CGRect? {
        regions.first { bar in
            guard bar.minY <= screen.minY + 1 else { return false }
            if abs(bar.maxX - screen.maxX) < 1 {
                let isRow = insets.top > 0 && abs(bar.height - insets.top) <= 2 && bar.width < screen.width / 2
                let isColumn = insets.trailing > 0 && abs(bar.width - insets.trailing) <= 2
                return isRow || isColumn
            }
            if abs(bar.minX - screen.minX) < 1 {
                return insets.top == 0 && insets.leading > 0 && abs(bar.width - insets.leading) <= 2
            }
            return false
        }
    }
}

nonisolated extension MChromeGeometry {
    /// 状态栏在侧边一列的顶部（Duo 折叠竖屏、展开横屏在右边，折叠横屏在左边）：在哪边、该列宽度
    /// （= 那一侧的安全区），以及状态栏底边距根视图顶边的距离——这一列在它下面是空的、可以用。
    var statusColumn: (edge: HorizontalEdge, width: CGFloat, statusBottom: CGFloat)? {
        guard let bar = statusBar, safeAreaInsets.top == 0 else { return nil }
        let screen = screen
        let edge: HorizontalEdge
        if abs(bar.maxX - screen.maxX) < 1 {
            edge = .trailing
        } else if abs(bar.minX - screen.minX) < 1 {
            edge = .leading
        } else {
            return nil
        }
        let width = inset(edge)
        guard width > 0, abs(bar.width - width) <= 2 else { return nil }
        return (edge, width, bar.maxY - root.minY)
    }

    /// 能放自己东西的侧边一列：状态栏那一列（`statusColumn`），或者顶边没有安全区、只有一侧有安全区而那里没有状态栏
    /// （Duo 外屏反过来横握：状态栏不在那一侧，那一侧的安全区让的是前置摄像头，实机那一列整列空白）。后一种上面没有
    /// 状态栏要让，`statusBottom` 为 0。太窄（< 44pt）的不算。
    var sideColumn: (edge: HorizontalEdge, width: CGFloat, statusBottom: CGFloat)? {
        if let statusColumn { return statusColumn }
        guard safeAreaInsets.top == 0, (safeAreaInsets.leading > 0) != (safeAreaInsets.trailing > 0) else { return nil }
        let edge: HorizontalEdge = safeAreaInsets.leading > 0 ? .leading : .trailing
        let width = inset(edge)
        return width >= 44 ? (edge, width, 0) : nil
    }

    /// 放在侧列里的按钮的横向中心，离状态栏那一侧屏幕边多远。
    ///
    /// 系统状态栏里的时间、信号不在安全区那一列的正中，而在系统给侧边竖栏划的区域的中线上，往屏幕里偏约 6pt
    /// （Duo 实测：列宽 84，竖栏区域 x 24–72，中线离边 48）。按列宽居中的按钮看着比状态栏偏外。
    /// 量不到竖栏区域、或它的中线不在这一列里时，退回列的中线。
    var statusColumnControlCenter: CGFloat? {
        guard let column = statusColumn else { return nil }
        let fallback = column.width / 2
        guard let sideBar, sideBar.width > 0 else { return fallback }
        let screen = screen
        let distance = column.edge == .leading ? sideBar.midX - screen.minX : screen.maxX - sideBar.midX
        return distance > 0 && distance < column.width ? distance : fallback
    }

    /// 状态栏占侧边一整列、顶边没有安全区（Duo 外屏竖握 / 横握、Duo 展开横屏）。
    ///
    /// iOS 27.1 起听系统的 `verticalBarEdge`：普通 iPhone / iPad 报「无」。转屏后它会比安全区晚一拍
    /// （实测折叠横握第一次读数仍是 trailing、安全区已到左边），所以还要那一侧真有安全区才算。
    /// 更早的系统按安全区猜：只有一侧有、顶边没有（普通 iPhone 横屏左右都有，不算）。
    var hasSideStatusColumn: Bool {
        guard safeAreaInsets.top == 0 else { return false }
        if reportsVerticalBarEdge {
            guard let verticalBarEdge else { return false }
            return inset(verticalBarEdge) > 0
        }
        return (safeAreaInsets.leading > 0) != (safeAreaInsets.trailing > 0)
    }

    private func inset(_ edge: HorizontalEdge) -> CGFloat {
        edge == .leading ? safeAreaInsets.leading : safeAreaInsets.trailing
    }

    /// 状态栏在顶部一行的右端（Duo 展开竖屏）：整条顶边都算安全区，但状态栏只占右边一块，
    /// 左边那一截可以放自己的东西。返回该行高度（= 顶部安全区）。
    ///
    /// 顶部横条区域的上沿在哪台设备上都高于顶部安全区（模拟器实测上沿都是 10：iPhone 18 Pro 安全区 62、
    /// iPhone 17e 47、iPad 32），它本身分不出「顶行有空位」。普通 iPhone 顶行正中是灵动岛 / 刘海，iPad
    /// 的状态栏横跨整行，只有展开的 Duo 状态栏才缩在一角，所以先按设备判断。
    /// 退路是遮挡保留区里的状态栏矩形（没有顶部横条区域时）。
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
    /// 叠上 UIKit 探针量到的、SwiftUI 量不到（或量不准）的那几项。
    func merging(_ probe: MChromeProbeResult) -> MChromeGeometry {
        var g = self
        g.topBar = probe.topBar
        g.cornerSafeArea = probe.cornerSafeArea
        g.sideBar = probe.sideBar
        g.isUnfoldedPhone = probe.isUnfoldedPhone
        g.verticalBarEdge = probe.verticalBarEdge
        g.reportsVerticalBarEdge = probe.reportsVerticalBarEdge
        g.statusBar = MChromeGeometry.statusBar(among: probe.occlusion.filter(\.active).map(\.frame),
                                                screen: g.screen, safeArea: g.safeAreaInsets)
        #if DEBUG
        g.rawOcclusion = probe.occlusion
        #endif
        return g
    }
}

/// 全屏的 UIKit 探针：向系统要「贴顶横条」的布局区域（`UIView.LayoutRegion.bar`）、遮挡保留区与
/// 侧边竖栏的位置，换算成窗口坐标报上去。布局、安全区、相关特征一变就重算。SwiftUI 要么没有对应
/// 接口，要么（遮挡保留区）在真机上漏报状态栏，只能借一层 UIView。
nonisolated struct MChromeProbeResult: Equatable, Sendable {
    var topBar: CGRect?
    var cornerSafeArea: CGRect?
    var sideBar: CGRect?
    var isUnfoldedPhone = false
    /// 全部遮挡保留区（窗口坐标，含非活动）。状态栏从活动的里挑，见 `MChromeGeometry.statusBar(among:)`。
    var occlusion: [MChromeGeometry.RawRegion] = []
    var verticalBarEdge: HorizontalEdge?
    var reportsVerticalBarEdge = false
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
        private var followUp: Task<Void, Never>?

        override init(frame: CGRect) {
            super.init(frame: frame)
            if #available(iOS 27.1, *) {
                registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
                    (view: ProbeView, _: UITraitCollection) in view.report()
                }
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
                result.occlusion = reservedRegions(kind: .occlusion, options: .includeInactive).map {
                    MChromeGeometry.RawRegion(frame: convert($0.frame, to: window), active: $0.isActive)
                }
                result.reportsVerticalBarEdge = true
                result.verticalBarEdge = switch traitCollection.verticalBarEdge {
                case .leading: .leading
                case .trailing: .trailing
                default: nil
                }
                if let edge = result.verticalBarEdge {
                    let leftToRight = effectiveUserInterfaceLayoutDirection == .leftToRight
                    let rectEdge: UIRectEdge = (edge == .leading) == leftToRight ? .left : .right
                    let insets = edgeInsets(for: .bar(onEdge: rectEdge, extent: MChromeGeometry.topBarExtent))
                    result.sideBar = convert(bounds.inset(by: insets), to: window)
                }
            }
            guard last != result else { return }
            last = result
            // 布局过程中改 SwiftUI 状态会被警告 / 丢弃：挪到下一轮主循环。
            DispatchQueue.main.async { [weak self] in self?.onChange?(result) }
            // 转屏 / 开合后保留区与竖栏位置要过一会儿才稳定，稳定那一下不一定再触发布局：
            // 一变就在 0.4 s、1.2 s 各补量一次（量到的没变就不再上报）。
            followUp?.cancel()
            followUp = Task { @MainActor [weak self] in
                for delay in [400, 800] {
                    try? await Task.sleep(for: .milliseconds(delay))
                    guard !Task.isCancelled, let self else { return }
                    self.report()
                }
            }
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
        // 三路都没让出状态栏（遮挡保留区没报状态栏、横条区域与角落安全区都横跨整宽）时，
        // 按真机实测的状态栏底板宽度保底让位：底板约占 545–650pt（屏宽 669），右沿留 136pt。
        if inRow, chrome.statusBar == nil, frame.maxX > screen.maxX - Self.statusPlatterReserve {
            trailing = max(trailing, frame.maxX - (screen.maxX - Self.statusPlatterReserve))
        }
        // 横条区域不一定避开状态栏（vphone 实测）；与状态栏矩形真有重叠时两路取较大的让位。
        // 左边一列的状态栏（Duo 折叠横握）在本条左侧、不重叠，不让。
        if let bar = chrome.statusBar, frame.minY < bar.maxY, frame.maxX > bar.minX, frame.minX < bar.maxX {
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

    /// 挂在 ScrollView 上：内容不进侧边安全区。
    ///
    /// ScrollView 默认把内容画进安全区。Duo 横屏时右侧安全区是状态栏那一列，内容滚进去看得见、
    /// 却点不到（实机反馈）。画面和命中区都收到左右的安全区边界：`clipShape` 只裁画面，不限制命中。
    /// 滚到底时最后一项正好停在边界上，不会缺内容。
    ///
    /// 画面只裁左右：竖向列表照常滚进底部 Home 条那一截（系统列表的样子），裁上下的话列表底下空一整条
    ///（实机反馈）。路径可以比自身大，SwiftUI 不拿它和自身的范围求交。
    ///
    /// 命中区仍是自身的矩形。**别把命中区也换成上下伸出去的形状**：那样每个挂了它的横向滚动区（标签条、
    /// 键盘条）都会接住整屏上下所有的触摸，整个 App 点不动、滚不动（实机事故，`MBottomSafeAreaTests` 拦着）。
    func mKeepsScrollContentInSafeArea() -> some View {
        clipShape(MHorizontalClip()).contentShape(Rectangle())
    }
}

/// 只在左右两边裁的形状：上下伸出去很远，不裁。
struct MHorizontalClip: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: 0, dy: -10_000))
    }
}

extension Edge.Set {
    /// 工作区会话正文（终端 / 文件 / Agent）的底色往哪些安全区延伸：左右与底边照常铺满
    /// （横屏刘海、Duo 侧列、Home 条那一截与正文同色），**顶边不延伸**。Duo 竖屏时工作区伸进
    /// 顶部安全区、标签条坐在状态栏那一行，正文的上沿恰好贴着安全区边界——颜色背景默认四边都
    /// 延伸，正文底色会往上铺满 82pt、盖住排在它前面的标签条（实机：左格标签条整条不见）。
    static let mSessionBody: Edge.Set = [.horizontal, .bottom]
}

