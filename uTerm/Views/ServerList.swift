import SwiftUI

/// 服务器列表（设计稿 Variant A）：左侧主机行 + 右侧滑入的详情面板。
///
/// 纯展示组件，接受已过滤排序后的 profiles。上层（WelcomeView）负责数据过滤 /
/// 排序 / 动作响应。选中某行即在右侧展示 `HostDetailPanel`，填补原本的右侧空白；
/// 当没有有效选中时自动选中第一台可见主机（对齐设计稿默认选中第一行的行为）。
struct ServerList: View {
    let profiles: [ServerProfile]
    let query: String
    @Binding var selectedID: UUID?
    let onOpen: (ServerProfile) -> Void
    let onContextAction: (ContextAction, ServerProfile) -> Void
    let existingGroups: [String]

    enum ContextAction: Equatable {
        case connect
        case openSFTP
        case togglePin
        case copySSH
        case edit
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
                HostDetailPanel(profile: selected, onConnect: { onOpen(selected) })
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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(profiles) { profile in
                        ServerRow(profile: profile,
                                  query: query,
                                  isSelected: selectedID == profile.id,
                                  onTap: { selectedID = profile.id },
                                  onDoubleTap: {
                                      selectedID = profile.id
                                      onContextAction(.connect, profile)
                                  })
                            .contextMenu { contextMenu(for: profile) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        Button("连接") { onContextAction(.connect, profile) }
        Button("在 SFTP 中打开") { onContextAction(.openSFTP, profile) }
        Button(profile.isPinned ? "取消置顶" : "置顶") {
            onContextAction(.togglePin, profile)
        }
        Button("复制 SSH 连接") { onContextAction(.copySSH, profile) }
        Button("编辑…") { onContextAction(.edit, profile) }
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
    }
}
