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
    let groupColorHexes: [String: String]
    var rowDragEnabled = true
    var reorderEnabled = false
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

    private var selectedProfile: ServerProfile? {
        guard let selectedID else { return nil }
        return profiles.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
            if let selected = selectedProfile {
                HostDetailPanel(profile: selected,
                                onConnect: { onOpen(selected) },
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
                                      groupColor: ServerGroupBadgeTint.color(for: profile.group,
                                                                             in: groupColorHexes),
                                      onTap: { selectedID = profile.id },
                                      onDoubleTap: {
                                          selectedID = profile.id
                                          onContextAction(.connect, profile)
                                      })
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
                    .padding(ServerListLayout.contentPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // 键盘上下移动选中行时把它滚进可视区（无 anchor = 最小滚动，已可见则不动，
                // 不打扰鼠标点击已可见行的场景）。
                .onChange(of: selectedID) { _, id in
                    guard let id else { return }
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
            Button("连接") { onContextAction(.connect, profile) }
                .keyboardShortcut(.return, modifiers: [])
            Button("在终端窗口打开") { onContextAction(.openTerminalWindow, profile) }
        }
        // 普通主机 SFTP = ⌘↩；「仅 SFTP」主机 SFTP 是主操作 = ↩（对齐 HostDetailPanel）。
        Button("在 SFTP 中打开") { onContextAction(.openSFTP, profile) }
            .keyboardShortcut(.return, modifiers: profile.sftpOnly ? [] : .command)
        Button(profile.isPinned ? "取消置顶" : "置顶") {
            onContextAction(.togglePin, profile)
        }
        Button("编辑…") { onContextAction(.edit, profile) }
            .keyboardShortcut("e", modifiers: .command)
        Button("复制为新服务器…") { onContextAction(.duplicate, profile) }
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
