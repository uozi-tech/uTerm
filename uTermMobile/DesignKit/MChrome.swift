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

    /// 探测顶部横条区域时用的横条高度 = 工作区标签条高度。
    static let topBarExtent: CGFloat = 48
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
    /// 首选系统的顶部横条区域：它的上沿高于顶部安全区，就说明横条可以和状态栏同行（真机走这条）。
    /// 退路是遮挡保留区里的状态栏矩形（vphone 报告、真机不报）。
    var statusRowHeight: CGFloat? {
        guard safeAreaInsets.top > 0, safeAreaInsets.trailing == 0 else { return nil }
        if let topBar {
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
    @State private var topBar: CGRect?
    /// 换 id 即重建量尺视图、再量一次（见下方补测）。
    @State private var pass = 0
    @State private var followUp: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .environment(\.mChrome, merged)
            .background {
                MTopBarProbe { if topBar != $0 { topBar = $0 } }
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
    private var merged: MChromeGeometry {
        var g = geometry
        g.topBar = topBar
        return g
    }
}

/// 全屏的 UIKit 探针：向系统要「贴顶横条」的布局区域（`UIView.LayoutRegion.bar`），换算成
/// 窗口坐标报上去。布局、安全区一变就重算。SwiftUI 没有对应接口，只能借一层 UIView。
private struct MTopBarProbe: UIViewRepresentable {
    var onChange: (CGRect?) -> Void

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: UIView {
        var onChange: ((CGRect?) -> Void)?
        private var last: CGRect??

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
            var rect: CGRect?
            if #available(iOS 27.1, *) {
                let insets = edgeInsets(for: .bar(onEdge: UIRectEdge.top, extent: MChromeGeometry.topBarExtent))
                rect = convert(bounds.inset(by: insets), to: window)
            }
            guard last != .some(rect) else { return }
            last = .some(rect)
            // 布局过程中改 SwiftUI 状态会被警告 / 丢弃：挪到下一轮主循环。
            DispatchQueue.main.async { [weak self] in self?.onChange?(rect) }
        }
    }
}

/// 让一条贴顶的自绘标签条 / 工具条用上状态栏旁边的空间，同时不压到状态栏、不挤进屏幕圆角：
/// - 状态栏在顶行（Duo 展开竖屏）且本条贴着屏幕顶：条高撑到状态行高度，与状态栏同一行；
/// - 与状态栏矩形上下有重叠：右侧让出与状态栏重叠的那一截；
/// - 贴着屏幕左上角（Duo 折叠 / 横屏没有顶部安全区）：左侧补系统给的容器边距，避开圆角。
/// 本条自己量全局位置（外框不受这里加的内边距影响，不会来回抖）。
private struct MStatusBarAvoidance: ViewModifier {
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
            // 系统划的横条区域避开了灵动岛与圆角（真机上也避开状态栏）：本条超出它的左右两截都让出来。
            if atLeading { leading = max(0, bar.minX - frame.minX) }
            trailing = max(0, frame.maxX - bar.maxX)
        }
        // vphone 上横条区域不避开状态栏、遮挡保留区却报了状态栏矩形；两路取较大的让位。
        if let bar = chrome.statusBar, frame.minY < bar.maxY, frame.maxX > bar.minX {
            trailing = max(trailing, frame.maxX - bar.minX + 8)
        }
        let height = atTop ? max(minHeight, chrome.statusRowHeight ?? 0) : minHeight
        return content
            .padding(.leading, leading)
            .padding(.trailing, trailing)
            .frame(height: height)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
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
}

extension Edge.Set {
    /// 工作区会话正文（终端 / 文件 / Agent）的底色往哪些安全区延伸：左右与底边照常铺满
    /// （横屏刘海、Duo 侧列、Home 条那一截与正文同色），**顶边不延伸**。Duo 竖屏时工作区伸进
    /// 顶部安全区、标签条坐在状态栏那一行，正文的上沿恰好贴着安全区边界——颜色背景默认四边都
    /// 延伸，正文底色会往上铺满 82pt、盖住排在它前面的标签条（实机：左格标签条整条不见）。
    static let mSessionBody: Edge.Set = [.horizontal, .bottom]
}

