import SwiftUI

/// 标签的三种活动态（对齐 macOS `UPaneTabActivity`）。
enum MTabActivity {
    /// 聚焦格的前台标签——全工作区只有一个。
    case active
    /// 另一格的前台标签（分屏时也在屏上，但键盘不归它）。
    case frontUnfocused
    /// 后台标签。
    case inactive
}

/// 关标签前要用户拿主意的一次确认。
struct MTabClosePrompt: Equatable {
    enum Kind: Equatable {
        /// 远控标签：只关手机上的，还是连 Mac 上的一起关。
        case remote(macName: String)
        /// 前台还有程序在跑。
        case busy(TerminalClosePrompt)
    }

    let tabID: UUID
    let kind: Kind
}

/// 关标签前的裁决。文件浏览直接关；远控标签还连着时先问：只关手机上的，还是连 Mac 上的一起关；
/// 已经断开 / Mac 不支持远程关闭时直接关（只断手机这一头，Mac 上的程序不受影响）；
/// 其余终端标签前台还有程序在跑时先确认。
@MainActor
@Observable
final class MTabCloseFlow {
    /// 等用户拿主意的确认。
    var pending: MTabClosePrompt?
    /// 探测前台的标签。探测要走一趟网络，连点关闭按钮不重复发起。
    @ObservationIgnored private let probe = TerminalCloseProbe()

    nonisolated static func asksBeforeClosingRemote(macSupportsClosing: Bool, connected: Bool) -> Bool {
        macSupportsClosing && connected
    }

    func request(_ tab: MWorkTab, close: @escaping (UUID) -> Void) {
        let id = tab.id
        guard let term = tab.terminal else {
            close(id)
            return
        }
        if let remote = term.remote {
            if Self.asksBeforeClosingRemote(macSupportsClosing: remote.client.supportsCloseSession,
                                            connected: term.controller.state == .connected) {
                pending = MTabClosePrompt(tabID: id, kind: .remote(macName: remote.macName))
            } else {
                close(id)
            }
            return
        }
        Task {
            await probe.probe(id, activity: term.controller.foregroundActivity) { prompt in
                if let prompt {
                    pending = MTabClosePrompt(tabID: id, kind: .busy(prompt))
                } else {
                    close(id)
                }
            }
        }
    }
}

/// 一个分屏格的标签条：返回 · 多态标签（终端 / 文件）· 新建 · Agent 开关 · 分屏开关。
///
/// 活动态配色照 macOS 工作区 `.card` 标签（uAppKit `UPaneTabChip.cardChip`）：
/// - 前台标签（含另一格的前台）填中性的 `panelHi` 胶囊，**不染 accent 底**；后台标签透明；
/// - 只有活动标签的图标走 accent，标题正文强度；另一格前台标题降到 `text2`，后台 `text3`。
/// 分屏时「焦点在哪一格」也只靠这一枚 accent 图标与标题强度区分，格外不画焦点框——
/// 两格贴边并排时一圈 accent 框太抢，读起来像选中态而不是焦点。
/// 一屏之内 accent 只出现在一个图标上，不会两三处 accent 抢着说「我是当前」。
struct WorkspaceTabStrip: View {
    /// 标签条高度（不含顶边净空）。
    static let height: CGFloat = 48
    /// 工作区分屏区的坐标空间：拖动判定、分隔条、标签条与标签的位置都在这里量。
    static let coordinateSpace = "workspace-split"
    let tabs: [MWorkTab]
    let activeID: UUID?
    /// 本格是否为聚焦格。
    var paneFocused: Bool = true
    /// 返回主机列表按钮只放在第一格（两格都放就是两个一样的返回）。
    var showsBack: Bool = true
    /// 分屏开关：nil = 不显示；false = 「分屏」；true = 「取消分屏」。只放在最后一格。
    var splitState: Bool? = nil
    /// 标签能否挪到另一格（关掉时长按菜单里不出现「移到另一侧」）。
    var canMoveTabs: Bool = true
    var onSelect: (UUID) -> Void
    var onClose: (UUID) -> Void
    var onNew: (MConnectKind) -> Void
    var onBack: () -> Void
    /// 切换当前终端标签的「终端 ⇄ Agent」模式。
    var onAgent: () -> Void
    var onToggleSplit: () -> Void = {}
    var onMoveToOtherPane: (UUID) -> Void = { _ in }
    /// Agent / 分屏两个开关是否放在条尾。状态栏在右侧一列时（Duo），它们改放到那一列状态栏
    /// 下面（WorkspaceSideControls），条上只留返回与标签。
    var showsTrailingControls: Bool = true
    /// 这一格的 id：标签条与标签的位置按它记进 `frames`。
    var paneID: UUID? = nil
    /// 正在进行的标签拖动（被拖的标签在原位留成空位）。
    var drag: WorkspaceTabDragTracker? = nil
    /// 标签条与标签的位置，交给工作区做拖动判定。
    var frames: WorkspaceStripFrames? = nil
    /// 开始拖某个标签：条里横着拖是排序，拖出条到工作区边上分屏、拖进另一格并入。
    var onDragTab: (UUID) -> Void = { _ in }
    /// 等用户确认的关闭。归属标签自己弹，所以宽屏下的 popover 指向那枚标签。
    var closePrompt: Binding<MTabClosePrompt?> = .constant(nil)
    var onConfirmClose: (UUID, _ alsoOnMac: Bool) -> Void = { _, _ in }

    @Environment(\.mAccent) private var accent

    private var frontTerminal: TermTab? { tabs.first { $0.id == activeID }?.terminal }
    private var agentOn: Bool { frontTerminal?.mode == .agent }

    var body: some View {
        HStack(spacing: 4) {
            if showsBack {
                stripButton(icon: "back", color: accent, label: "返回主机列表", action: onBack)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tabs) { tab in
                            WorkspaceTabChip(tab: tab, activity: activity(tab), canMove: canMoveTabs,
                                             onSelect: { onSelect(tab.id) },
                                             onClose: { onClose(tab.id) },
                                             onMove: { onMoveToOtherPane(tab.id) },
                                             onDragStart: { onDragTab(tab.id) },
                                             closePrompt: closePrompt,
                                             onConfirmClose: { onConfirmClose(tab.id, $0) },
                                             isPlaceholder: drag?.isPlaceholder(tab.id) == true)
                                // 空位换位不滑：它要是也滑，会从让位的标签身上横穿过去。别的标签滑开，空位直接出现在新位置。
                                .transaction { if drag?.isPlaceholder(tab.id) == true { $0.animation = nil } }
                                .onGeometryChange(for: CGRect.self) {
                                    $0.frame(in: .named(Self.coordinateSpace))
                                } action: { frame in
                                    if let paneID { frames?.strips[paneID, default: MStripFrame(frame: .zero)].chips[tab.id] = frame }
                                }
                                .id(tab.id)
                        }
                        newMenu
                    }
                    .padding(.leading, showsBack ? 0 : 8)
                }
                .mKeepsScrollContentInSafeArea()
                .onChange(of: activeID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id) }
                }
            }

            // 远控标签（经 Mac 接入的终端、Mac 本机 shell）没有 Agent：Agent 要直连那台主机执行命令。
            if showsTrailingControls, let frontTerminal, frontTerminal.remote == nil { agentButton }
            if showsTrailingControls, let split = splitState {
                // 开关语义：分屏中用实心图标表示「开着」，再点一下取消。
                stripButton(systemImage: split ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                            color: M.text2, label: split ? "取消分屏" : "分屏", action: onToggleSplit)
            }
        }
        // 两端按钮命中区 44pt、视觉 34pt：外沿各自带 5pt，水平内边距相应收到 3（视觉仍距边 ~8）。
        .padding(.horizontal, 3)
        // Duo：竖屏时这一条上移进状态栏那一行（让出状态栏），横屏 / 折叠时左上角避开圆角。
        .mAvoidsStatusBar(minHeight: Self.height)
        // 与终端同一个工作面（M.surface = 终端底色），只用底边 hairline 分区。
        .background(M.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(M.divider).frame(height: 1) }
        .onGeometryChange(for: CGRect.self) {
            $0.frame(in: .named(Self.coordinateSpace))
        } action: { frame in
            guard let paneID, let frames else { return }
            // 关掉 / 挪走的标签留下的旧位置不用清：判定只看这一格此刻的标签。
            frames.strips[paneID, default: MStripFrame(frame: frame)].frame = frame
        }
    }


    private func activity(_ tab: MWorkTab) -> MTabActivity {
        guard tab.id == activeID else { return .inactive }
        return paneFocused ? .active : .frontUnfocused
    }

    @Environment(\.mInStatusRow) private var inStatusRow

    private var newMenu: some View {
        MMenu {
            Button { onNew(.terminal) } label: { Label("新建终端", systemImage: MGlyph.symbol("term")) }
            Button { onNew(.sftp) } label: { Label("浏览文件", systemImage: MGlyph.symbol("folder")) }
        } label: {
            MIcon(name: "plus", size: inStatusRow ? 16 : 14, color: M.text2, weight: .semibold)
                .frame(width: inStatusRow ? 36 : 30, height: inStatusRow ? 36 : 30)
                .padding(.vertical, inStatusRow ? 4 : 7).padding(.horizontal, 4)   // 命中区 ≥ 38×44
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("新建标签页"))
    }

    private var agentButton: some View {
        WorkspaceAgentButton(agentOn: agentOn, action: onAgent)
    }

    private func stripButton(icon: String? = nil, systemImage: String? = nil, color: Color,
                             label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        WorkspaceRoundButton(icon: icon, systemImage: systemImage, color: color, label: label, action: action)
    }
}

/// 标签条两端的圆形按钮（视觉 34pt、命中区 44pt）。标签条与 Duo 侧列共用。
struct WorkspaceRoundButton: View {
    var icon: String? = nil
    var systemImage: String? = nil
    var color: Color
    var label: LocalizedStringKey
    var action: () -> Void
    /// Duo 状态行里（行更高）放大到 38pt，与放大的标签同高。
    @Environment(\.mInStatusRow) private var inStatusRow

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 16, weight: .medium))
                        .foregroundStyle(color)
                } else if let icon {
                    MIcon(name: icon, size: 19, color: color, weight: .semibold)
                }
            }
            .frame(width: inStatusRow ? 38 : 34, height: inStatusRow ? 38 : 34)
            .background(M.button).clipShape(Circle())
            .frame(width: M.minTarget, height: M.minTarget)   // 命中区 44pt
            .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel(Text(label))
    }
}

/// 「终端 ⇄ Agent」开关。
struct WorkspaceAgentButton: View {
    var agentOn: Bool
    var action: () -> Void
    @Environment(\.mInStatusRow) private var inStatusRow

    var body: some View {
        Button(action: action) {
            MIcon(name: agentOn ? "term" : "spark", size: 17,
                  color: agentOn ? .white : M.aiAccent, weight: .semibold)
                .frame(width: inStatusRow ? 38 : 34, height: inStatusRow ? 38 : 34)
                .background(agentOn ? M.aiAccent : M.aiAccent.opacity(0.15))
                .clipShape(Circle())
                .frame(width: M.minTarget, height: M.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(MPressStyle())
        .accessibilityLabel(Text(agentOn ? "返回终端" : "切换到 Agent"))
        .accessibilityAddTraits(agentOn ? [.isButton, .isSelected] : .isButton)
    }
}

/// Duo 状态栏在右侧一列时，Agent / 分屏两个开关竖排在那一列状态栏下面（Apple 对 Duo 的建议：
/// 按钮放侧边、内容让出整块左侧），而不是挤在标签条尾、让那一列空着。作用于聚焦格。
struct WorkspaceSideControls: View {
    /// 聚焦格的前台标签是终端时才有 Agent 开关。
    var agentOn: Bool?
    var isSplit: Bool
    var onAgent: () -> Void
    var onToggleSplit: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            if let agentOn { WorkspaceAgentButton(agentOn: agentOn, action: onAgent) }
            WorkspaceRoundButton(systemImage: isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                                 color: M.text2, label: isSplit ? "取消分屏" : "分屏", action: onToggleSplit)
        }
        .padding(.top, 8)
    }
}

/// 标签条上的一枚标签：状态点 · 标题 · 关闭。终端是常态，不放图标；文件浏览标题同样是主机名，靠文件夹图标区分。
struct WorkspaceTabChip: View {
    let tab: MWorkTab
    let activity: MTabActivity
    var canMove: Bool = true
    var onSelect: () -> Void
    var onClose: () -> Void
    var onMove: () -> Void = {}
    var onDragStart: () -> Void = {}
    var closePrompt: Binding<MTabClosePrompt?> = .constant(nil)
    var onConfirmClose: (_ alsoOnMac: Bool) -> Void = { _ in }
    /// 正被拖着：原位只留一个空位（淡淡的胶囊底，没有字），被拖的标签由系统画在手指下。
    var isPlaceholder = false
    @Environment(\.mAccent) private var accent
    /// Duo 状态行里胶囊加高到 36pt（行高 82，30pt 的胶囊显得太扁，实机反馈）。
    @Environment(\.mInStatusRow) private var inStatusRow
    @State private var hovering = false

    private var isFront: Bool { activity != .inactive }
    private var pillHeight: CGFloat { inStatusRow ? 36 : 30 }

    private var iconColor: Color {
        switch activity {
        case .active: return accent
        case .frontUnfocused: return M.text2
        case .inactive: return M.text3
        }
    }

    private var titleColor: Color {
        switch activity {
        case .active: return M.text
        case .frontUnfocused: return M.text2
        case .inactive: return hovering ? M.text2 : M.text3
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            MDot(color: stateDot.color, pulse: stateDot.pulse, size: 6)
            if tab.kind == .sftp {
                MIcon(name: "folder", size: 12, color: iconColor,
                      weight: activity == .active ? .semibold : .regular)
            }
            Text(tab.title)
                .font(M.mono(12.5))
                .foregroundStyle(titleColor)
                .lineLimit(1)
                // 长标题（shell 设的 OSC 标题常带整条路径）截断，别一枚标签占掉整条。
                .frame(maxWidth: 168, alignment: .leading)
            // 后台标签不放关闭钮（触屏没有悬停，放了就是一排 ×）：点一下切到前台再关，
            // 或长按用菜单关。带指针的 iPad 悬停时照 macOS 露出来。
            if isFront || hovering {
                Button(action: onClose) {
                    MIcon(name: "x", size: 10, color: M.text3, weight: .semibold)
                        .frame(width: 26, height: pillHeight)   // 关闭命中区占满胶囊高度
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭标签页"))
            }
        }
        .padding(.leading, 10).padding(.trailing, isFront || hovering ? 0 : 10).frame(height: pillHeight)
        .opacity(isPlaceholder ? 0 : 1)
        .background(
            RoundedRectangle(cornerRadius: MRadius.sm, style: .continuous)
                .fill(isPlaceholder ? M.pressed : isFront ? M.panelHi : (hovering ? M.pressed : Color.clear)))
        // 挂在胶囊上而不是下面撑到 44pt 的命中区上：popover 的箭头要贴着看得见的标签。
        .modifier(TabCloseDialog(tabID: tab.id, prompt: closePrompt, onConfirm: onConfirmClose))
        .padding(.vertical, (44 - pillHeight) / 2)   // 命中区 44pt
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        // 长按拎起即可拖：拖到工作区边上分屏、拖进另一格并入；原地松手就是长按菜单。
        .onDrag {
            onDragStart()
            return WorkspaceTabDrag.itemProvider(tabID: tab.id)
        }
        .mContextMenu {
            if canMove {
                Button(action: onMove) {
                    Label("移到另一侧", systemImage: "rectangle.righthalf.inset.filled.arrow.right")
                }
            }
            Button(role: .destructive, action: onClose) { Label("关闭", systemImage: "xmark") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text(verbatim: programStatus.map { "\($0.appName) \($0.statusLabel)" } ?? ""))
        .accessibilityAddTraits(activity == .active ? [.isButton, .isSelected] : .isButton)
    }

    /// 终端里程序（Claude Code、Codex……）的状态；文件浏览没有。
    private var programStatus: ProgramStatusRecord? {
        if case .terminal(let t) = tab { return t.programStatus }
        return nil
    }

    /// 状态点：程序有状态时说程序（含义与配色同 mac 的标签），否则说连接——终端看 SSH 会话，文件浏览看 SFTP 会话。
    private var stateDot: (color: Color, pulse: Bool) {
        if let programStatus { return (Self.color(for: programStatus.tone, accent: accent), false) }
        switch tab {
        case .terminal(let t):
            switch t.controller.state {
            case .connected: return t.controller.isReconnecting ? (M.warning, true) : (M.success, false)
            case .connecting: return (M.warning, true)
            case .failed: return (M.danger, false)
            case .disconnected, .idle: return (M.text4, false)
            }
        case .files(let f):
            switch f.controller.state {
            case .connected: return (M.success, false)
            case .connecting, .idle: return (M.warning, true)
            case .failed: return (M.danger, false)
            }
        }
    }
}

extension WorkspaceTabChip {
    /// 与 mac `ProgramStatusRecord.tabDot` 一一对应：等人处理 = 警示色，运行中 = 强调色，完成 = 成功色，出错 = 危险色。
    static func color(for tone: ProgramStatusTone, accent: Color) -> Color {
        switch tone {
        case .needsAttention: M.warning
        case .working: accent
        case .done: M.success
        case .failed: M.danger
        case .idle: M.text4
        }
    }
}

/// 关标签前的确认。窄屏是底部操作表，宽屏是从这枚标签弹出的 popover（系统不显示「取消」，点外面即取消）。
private struct TabCloseDialog: ViewModifier {
    let tabID: UUID
    @Binding var prompt: MTabClosePrompt?
    let onConfirm: (_ alsoOnMac: Bool) -> Void

    /// 收起动画期间 `prompt` 已清空，标题仍要有字。
    private var title: Text {
        if case .busy(let busy)? = prompt?.kind { return Text(busy.title) }
        return Text("关闭这个标签页？")
    }

    func body(content: Content) -> some View {
        let isPresented = Binding(get: { prompt?.tabID == tabID },
                                  set: { if !$0 { prompt = nil } })
        content.confirmationDialog(title,
                                   isPresented: isPresented,
                                   titleVisibility: .visible,
                                   presenting: prompt) { prompt in
            switch prompt.kind {
            case .remote:
                Button("只在手机上关闭") { onConfirm(false) }
                Button("同时关闭 Mac 上的终端", role: .destructive) { onConfirm(true) }
            case .busy:
                Button("关闭标签页", role: .destructive) { onConfirm(false) }
            }
            Button("取消", role: .cancel) {}
        } message: { prompt in
            switch prompt.kind {
            case .remote(let macName):
                Text("这是「\(macName)」上的终端。只在手机上关闭时，它在 Mac 上照常运行，之后还能再接入。")
            case .busy(let busy):
                Text(busy.message)
            }
        }
    }
}
