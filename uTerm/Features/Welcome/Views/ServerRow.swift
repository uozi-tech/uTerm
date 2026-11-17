import UAppKitBridge
import UDesignKit
// uTerm/Views/ServerRow.swift
import SwiftUI

enum ServerRowLayout {
    /// Welcome 主列表行内容到选中/焦点背景边界的四周内边距。
    nonisolated static let contentPadding: CGFloat = UD.Space.xl
}

/// Welcome 主列表的单行（设计稿 Variant A · HostRow）。
///
/// 等边内距：主机头像（分组色色块 + 首字母，角标 = 在线状态，见 `HostAvatar`）+
/// 名称（13.5/medium）+ 等宽 endpoint，右侧是「上次连接」相对时间与分组 chip。
/// 选中态用半透明叠底（浅深自适应），不画左侧竖条 —— 选中由更亮的底色 + 右侧详情面板共同表达。
///
/// **渲染成本形态（见 `docs/scroll-perf-findings.md`「欢迎页服务器列表」）**：
/// 这一行曾经整个包在一个 plain `Button` 里、两个 `.help` 常驻、每行现建一个
/// `RelativeDateTimeFormatter`。2000 台档下每行的常驻平台视图与 tooltip 区域
/// 是挂载与 hitTest 的主项。现在三处都收掉了 —— 改动时请守住：
///
/// 1. **不要把行重新包进 `Button`**。鼠标点击由 `ServerList` 的容器级透明层接
///    （`clickToSelect`），无障碍语义靠下面手工补的 `accessibilityAction`
///    （VoiceOver / 全键盘控制走的就是这条路）。
/// 2. **`.help` 只在悬停行挂**（`help(whenHovering:)`）。`NSToolTipManager`
///    每个滚动 tick 全量重算全窗 tooltip 区域，常驻 `.help` 是按行数收费的。
/// 2'. **别把 `.onHover` 加回来**。它同样是按行数收费的：SwiftUI 内部那张 hover
///    区域表按 `.onHover` 个数变长，鼠标位置或几何一变就要过一遍。悬停走
///    `ServerList` 那一个整表跟踪层（`.rowHover(_:id:)`）。
/// 3. **别在行体里现建 `Formatter`**。相对时间走 `UTermFormat.relative`（纯函数，不经 formatter）。
/// 4. **行体不读 `ServerProfile`**，只读 `ServerRowInfo`（见那里）。
///
/// 按「字段值 + 搜索词 + 选中 + 组色」判等（闭包不比），列表重算时没变的行不重算。
struct ServerRow: View, Equatable {
    static func == (lhs: ServerRow, rhs: ServerRow) -> Bool {
        lhs.info == rhs.info && lhs.query == rhs.query && lhs.isSelected == rhs.isSelected
            && lhs.groupColor == rhs.groupColor && lhs.rowHover === rhs.rowHover
    }

    let info: ServerRowInfo
    let query: String
    let isSelected: Bool
    let groupColor: Color?
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    /// 整表一个 tracking area 的悬停跟踪器状态（`ServerList` 持有）。nil 时本行
    /// 退回逐行 `.onHover` —— 探针的改前臂走的就是这条。
    var rowHover: RowHoverState?

    @State private var hover = false

    init(profile: ServerProfile, query: String, isSelected: Bool, groupColor: Color?,
         onTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void, rowHover: RowHoverState? = nil) {
        info = ServerRowInfo(profile)
        self.query = query
        self.isSelected = isSelected
        self.groupColor = groupColor
        self.onTap = onTap
        self.onDoubleTap = onDoubleTap
        self.rowHover = rowHover
    }

    var body: some View {
        HStack(spacing: 12) {
            HostAvatar(monogram: info.monogram,
                       tint: groupColor,
                       reachability: info.reachabilityKey.map(HostReachabilityMonitor.shared.entry(for:)))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(HighlightedText.attributed(info.name, highlighting: query))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(UD.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(whenHovering: hover, info.name)
                    if info.isPinned {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(UD.warning)
                    }
                }
                Text(HighlightedText.attributed(info.displayEndpoint, highlighting: query))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(whenHovering: hover, info.displayEndpoint)
            }

            Spacer(minLength: 6)

            Text(UTermFormat.relative(info.lastConnectedAt))
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .lineLimit(1)

            UDGroupChip(groupLabel, tint: groupColor)
        }
        .padding(ServerRowLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        // **本行不装 `.onHover`**：SwiftUI 内部那张 hover 区域表按 `.onHover` 个数
        // 变长，鼠标位置或几何一变就要过一遍 —— 按行数收费。悬停改由 `ServerList`
        // 挂在 `LazyVStack` 上的**一个**跟踪层按行高算出来
        // （`UAppKitBridge/RowHoverTracker.swift`），滚动期间由 `ScrollHoverGate`
        // 停更、停下补算一次。
        .rowHover(rowHover, id: info.id) { hover = $0 }
        // 在线角标：只在行可见期间登记探测，滚出屏幕 task 取消即注销（见 `HostReachabilityMonitor`）。
        .watchesReachability(of: info.reachabilityKey)
        // 鼠标单击 / 双击**不在这里**接 —— 两个 `onTapGesture` 链式会让 SwiftUI
        // 等满系统双击间隔才发单击（实测选中要 390~510ms）。改由 `ServerList`
        // 在整个 `LazyVStack` 上挂一个透明 AppKit 层，按 `NSEvent.clickCount`
        // 分派：第一下按下即选中、第二下即连接（见 `ClickSelectActivate.swift`）。
        // 行本身仍保留 `onTap` / `onDoubleTap`，它们是下面 AX 动作的落点。
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(info.name)，\(info.displayEndpoint)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        // 行不再是 `Button`，AX 的默认动作（VoiceOver ⌃⌥space / 全键盘控制）
        // 必须手工补回，否则整份列表在辅助功能下按不动。
        .accessibilityAction { onTap() }
        .accessibilityAction(named: Text("打开")) { onDoubleTap() }
    }

    private var groupLabel: String { info.groupLabel }

    /// 选中 > hover > 透明。用 `Color.primary` 透明叠底，浅色下变深、深色下变浅，
    /// 与设计稿的 white-alpha 叠底等效且自适应外观设置。
    /// 选中 / 悬停：铺满整行的中性灰（黑 6% / 2.8%）。试过强调色淡底的内缩圆角块，
    /// 用户要求用回原来的配色、四周不留白。
    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.06) }
        if hover { return Color.primary.opacity(0.028) }
        return .clear
    }
}

/// 一行要画的字段，在父视图建行时从 `ServerProfile` 抄一份值。
///
/// 行体不直接读 SwiftData 对象：iCloud 合并数据时 SwiftData 对每台主机都发「跳板机变了」，凡是读过这台主机
/// 任何一个字段的视图都跟着重算，不管读的是哪个字段、值变没变（iOS 主机页回前台的头 1.4 秒里 22 张卡重算
/// 480 次，2026-11-16 Duo 实测，同一个模型）。抄成值以后，列表照样会被叫醒重算一遍，行按这份值判等，
/// 没变就不重算。
struct ServerRowInfo: Equatable {
    let id: UUID
    let name: String
    let displayEndpoint: String
    let monogram: String
    let groupLabel: String
    let isPinned: Bool
    let lastConnectedAt: Date?
    /// 在线探测的端点；走跳板机 / 没填地址时为 nil，不探也不画角标。
    let reachabilityKey: HostEndpointKey?

    init(_ profile: ServerProfile) {
        id = profile.id
        name = profile.name
        displayEndpoint = profile.displayEndpoint
        monogram = profile.monogram
        groupLabel = profile.groupLabel
        isPinned = profile.isPinned
        lastConnectedAt = profile.lastConnectedAt
        reachabilityKey = HostEndpointKey(profile)
    }
}
