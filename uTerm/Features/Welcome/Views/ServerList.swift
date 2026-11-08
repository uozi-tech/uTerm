import UAppKitBridge
import UDesignKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ServerListLayout {
    /// Welcome 主列表行贴齐列表列边界；行自身负责内容内距。
    nonisolated static let contentPadding: CGFloat = 0
    nonisolated static let rowSpacing: CGFloat = 0
}

/// 服务器列表（设计稿 Variant A）：左侧主机行 + 右侧滑入的详情面板。
///
/// 纯展示组件，接受已过滤排序后的 profiles。上层（WelcomeView）负责数据过滤 /
/// 排序 / 动作响应。选中某行即在右侧展示 `HostDetailPanel`，填补原本的右侧空白；
/// 当没有有效选中时自动选中第一台可见主机（对齐设计稿默认选中第一行的行为）。
struct ServerList: View {
    let profiles: [ServerProfile]
    let query: String
    @Binding var selectedID: UUID?
    @Binding var draggingProfileID: UUID?
    let onOpen: (ServerProfile) -> Void
    let onContextAction: (ContextAction, ServerProfile) -> Void
    let existingGroups: [String]
    /// 组名 → 组色，由上层用 `ServerGroupTint.colors(for:)` 一趟解析好；行体只查表。
    let groupColors: [String: Color]
    var rowDragEnabled = true
    var reorderEnabled = false
    /// 选中变化时把目标行滚进可视区。默认开（产品行为），关掉是**探针的归因臂**：
    /// `ServerListSelectionScrollProbeTests` 拿「同一份 `ServerList`，只少这一次
    /// `scrollTo`（滚动改由探针用 `NSClipView.scroll(to:)` 手滚同样的距离）」当分母，
    /// 闸门才能写成同轮比值而不是绝对毫秒
    /// （uTable playbook §二·4：绝对基准换台机器就是假红）。
    /// 归因臂必须是产品代码本身 —— 复刻件的读数只能做同构对比，不能给真实屏定罪
    /// （playbook §二·五）。用 `#if DEBUG` 的静态开关代替它反而更差：两臂要在同一个
    /// 进程里交错跑，全局可变状态会互相污染，而且 Release 配置下探针就没法跑了。
    var scrollsSelectionIntoView = true
    var onMove: (_ sourceID: UUID, _ targetID: UUID) -> Void = { _, _ in }

    enum ContextAction: Equatable {
        case connect
        case openTerminalWindow
        case openSFTP
        case togglePin
        case edit
        case duplicate
        case moveToGroup(String?)    // nil → 未分组
        case newGroup
        case delete
    }

    /// 整表一个 tracking area 的悬停跟踪器状态。行不再各装 `.onHover`
    /// （见 `UAppKitBridge/RowHoverTracker.swift`）。
    @State private var rowHover = RowHoverState()

    private var selectedProfile: ServerProfile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            if let selected = selectedProfile {
                HostDetailPanel(profile: selected,
                                groupColor: ServerGroupTint.color(for: selected.group, colors: groupColors),
                                onConnect: { onOpen(selected) },
                                onOpenTerminal: { onContextAction(.openTerminalWindow, selected) },
                                onBrowseSFTP: { onContextAction(.openSFTP, selected) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: selectedProfile != nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UD.panel)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: profiles.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    @ViewBuilder
    private var listColumn: some View {
        if profiles.isEmpty {
            noMatchState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: ServerListLayout.rowSpacing) {
                        ForEach(profiles) { profile in
                            ServerRow(profile: profile,
                                      query: query,
                                      isSelected: selectedID == profile.id,
                                      groupColor: ServerGroupTint.color(for: profile.group, colors: groupColors),
                                      onTap: { selectedID = profile.id },
                                      onDoubleTap: {
                                          selectedID = profile.id
                                          onContextAction(.connect, profile)
                                      },
                                      rowHover: rowHover)
                                .id(profile.id)
                                .modifier(ServerRowDragModifier(
                                    dragEnabled: rowDragEnabled,
                                    reorderEnabled: reorderEnabled,
                                    profileID: profile.id,
                                    draggingProfileID: $draggingProfileID,
                                    onMove: onMove
                                ))
                                .contextMenu { contextMenu(for: profile) }
                        }
                    }
                    // 整列表一个透明点击层：第一下按下就选中（零等待），第二下连接。
                    // 行里不能挂 `onTapGesture(count: 2) + onTapGesture` —— SwiftUI
                    // 要等满系统双击间隔才发单击（见 `ClickSelectActivate.swift`）。
                    // **必须挂在 `.padding` 之前**，落点坐标才与行容器同源。
                    .clickToSelect(
                        select: { y, height in
                            guard let i = UniformRowHit.index(atY: y,
                                                              containerHeight: height,
                                                              rowCount: profiles.count)
                            else { return }
                            selectedID = profiles[i].id
                        },
                        activate: { y, height in
                            guard let i = UniformRowHit.index(atY: y,
                                                              containerHeight: height,
                                                              rowCount: profiles.count)
                            else { return }
                            let profile = profiles[i]
                            selectedID = profile.id
                            onContextAction(.connect, profile)
                        })
                    // 整列表一个 tracking area 的悬停跟踪器：落点 → 行号复用点击层
                    // 那套算术（行高由容器高度反推）。行里因此一个 `.onHover` 都没有
                    // —— SwiftUI 内部那张 hover 区域表按 `.onHover` 个数变长，鼠标
                    // 位置或几何一变就要过一遍，命中之后还要写回 `@State`、让那一行
                    // 重求 body。
                    // **挂在 `.scrollHoverGate()` 里面**：闸门是靠环境传下来的，
                    // 跟踪器要读它才知道现在在不在滚。
                    .rowHoverTracker(rowHover, geometry: .uniform(rowCount: profiles.count) {
                        profiles[$0].id
                    })
                    // 滚动期间停更悬停（光标没动、内容在它底下滚过去，那一行不该
                    // 跟着亮）；停下 150ms 后跟踪器补算一次。
                    // 见 `UAppKitBridge/ScrollHoverGate.swift`。
                    .scrollHoverGate()
                    .padding(ServerListLayout.contentPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 键盘上下移动选中行时把它滚进可视区（无 anchor = 最小滚动，已可见则不动，
                // 不打扰鼠标点击已可见行的场景）。
                //
                // ## 这里是 uTable `753575d` 的同形态，但**量过了，动画不是账**
                //
                // `LazyVStack` + 程序性 `scrollTo` + `withAnimation` 三件套正是
                // playbook §七 判据 1 点名的形状。2026-09-08 用
                // `ServerListSelectionScrollProbeTests` 把它复现了一遍
                // （2000 台 / 60 组，连续 200 次换选中行 + 20 次搜索过滤切换，
                // 两臂各两轮交替）：
                //
                // | 2000 台 · 一次「换选中行 + 布局」 | p50 | p95 | max | 3s 心跳 |
                // |---|---|---|---|---|
                // | 带 `withAnimation`（现状） | 34.97 / 36.69ms | 91.21 / 56.19ms | 98 / 61ms | 242 / 246 拍 |
                // | 去掉 `withAnimation` | 39.11 / 39.79ms | 63.91 / 64.25ms | 67 / 67ms | 245 / 251 拍 |
                // | 连 `scrollTo` 一起去掉（完全不滚） | **6.59ms** | **9.16ms** | **11ms** | **333 拍** |
                //
                // 两条结论，都跟去之前的先验相反：
                // 1. **753575d 那个失效模式在这里不发生**：没有单次 3s+ 的布局事务，
                //    心跳 242~251 拍（掉死的话是个位数），NSView 不随规模涨
                //    （§七 第四条：判「回不回收」只看扫完之后数 NSView）。
                // 2. **去掉动画不是收益**：p50 反而 35 → 39ms，100 台真实档也从
                //    6.2 → 8.6ms；只有尾部收紧一点。真正的账在 `scrollTo` 本身。
                //
                // 「完全不滚」那一行里混着整屏重绘的账。把分母换成**手滚同样的距离**
                // （`NSClipView.scroll(to:)`）之后，纯 `scrollTo` 的税是：
                // 2000 台 66ms vs 33ms（2.0~2.3×，`LazyVStack` 为一次定位摸行的钱），
                // **100 台真实档 15.5ms vs 16.8ms —— 不收税**（0.88~0.98×）。
                //
                // 所以动画**留着**（它是键盘导航的设计语义），闸门改成钉后果：
                // 结构判据（落点、NSView 数、文档高对行数）+ 同轮两臂比值，
                // 绝对毫秒只打印。真要再往下，要动的是 2000 行档 `scrollTo` 那 2.2 倍，
                // 不是这 0.12 秒补间。
                .onChange(of: selectedID) { _, id in
                    guard scrollsSelectionIntoView, let id else { return }
                    withAnimation(.easeInOut(duration: 0.12)) { proxy.scrollTo(id) }
                }
            }
        }
    }

    /// 搜索 / 过滤后无命中时的轻量空态（区别于「完全没有服务器」的大空态）。
    private var noMatchState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(UD.text3)
            Text("没有匹配的主机")
                .font(.system(size: 12))
                .foregroundStyle(UD.text3)
            if !query.isEmpty {
                Text("「\(query)」无结果")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(UD.text3.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 选中校验：当前选中仍在可见列表里则保持；否则落到第一台（空列表则清空）。
    private func selectFirstIfNeeded() {
        if let selectedID, profiles.contains(where: { $0.id == selectedID }) { return }
        selectedID = profiles.first?.id
    }

    @ViewBuilder
    private func contextMenu(for profile: ServerProfile) -> some View {
        // keyboardShortcut 让菜单项右侧显示键位提示（↩ / ⌘↩ / ⌘E / ⌘⌫），与列表全局
        // 快捷键一致。菜单内容惰性构建，不会注册成常驻 key equivalent；⌘E/⌘⌫ 又被
        // WelcomeView 的本地监听抢先消费，故不存在重复触发。
        // 「仅 SFTP」主机禁用终端会话，隐藏「连接」，仅保留 SFTP 浏览入口。
        if !profile.sftpOnly {
            Button("在工作区打开") { onContextAction(.connect, profile) }
                .keyboardShortcut(.return, modifiers: [])
            Button("在终端中打开") { onContextAction(.openTerminalWindow, profile) }
                .keyboardShortcut(.return, modifiers: .option)
        }
        // 普通主机 SFTP = ⌘↩；「仅 SFTP」主机 SFTP 是主操作 = ↩（对齐 HostDetailPanel）。
        Button("在 SFTP 中打开") { onContextAction(.openSFTP, profile) }
            .keyboardShortcut(.return, modifiers: profile.sftpOnly ? [] : .command)
        Button(profile.isPinned ? "取消置顶" : "置顶") {
            onContextAction(.togglePin, profile)
        }
        Button("编辑…") { onContextAction(.edit, profile) }
            .keyboardShortcut("e", modifiers: .command)
        Button("复制为新主机…") { onContextAction(.duplicate, profile) }
            .keyboardShortcut("d", modifiers: .command)
        Menu("移动到分组") {
            ForEach(existingGroups, id: \.self) { g in
                Button(g) { onContextAction(.moveToGroup(g), profile) }
            }
            if !existingGroups.isEmpty { Divider() }
            Button("未分组") { onContextAction(.moveToGroup(nil), profile) }
            Button("新分组…") { onContextAction(.newGroup, profile) }
        }
        Divider()
        Button("删除…", role: .destructive) {
            onContextAction(.delete, profile)
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }
}

private struct ServerRowDragModifier: ViewModifier {
    let dragEnabled: Bool
    let reorderEnabled: Bool
    let profileID: UUID
    @Binding var draggingProfileID: UUID?
    let onMove: (_ sourceID: UUID, _ targetID: UUID) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if !dragEnabled {
            content
        } else if reorderEnabled {
            draggable(content)
                .onDrop(of: [.text], delegate: ServerRowReorderDropDelegate(
                    targetID: profileID,
                    draggingProfileID: $draggingProfileID,
                    onMove: onMove
                ))
        } else {
            draggable(content)
        }
    }

    private func draggable(_ content: Content) -> some View {
        content.onDrag {
            draggingProfileID = profileID
            return NSItemProvider(object: "profile" as NSString)
        }
    }
}

private struct ServerRowReorderDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggingProfileID: UUID?
    let onMove: (_ sourceID: UUID, _ targetID: UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggingProfileID, sourceID != targetID else { return }
        onMove(sourceID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProfileID = nil
        return true
    }
}
