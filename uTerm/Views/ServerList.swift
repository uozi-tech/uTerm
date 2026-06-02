import SwiftUI

/// 服务器列表：纯展示组件，接受已过滤排序后的 profiles，渲染行 + 右键菜单。
/// 上层（WelcomeView）负责数据过滤 / 排序 / 动作响应。
struct ServerList: View {
    let profiles: [ServerProfile]
    let query: String
    @Binding var selectedID: UUID?
    let onOpen: (ServerProfile) -> Void
    let onContextAction: (ContextAction, ServerProfile) -> Void
    let existingGroups: [String]

    enum ContextAction: Equatable {
        case connect
        case togglePin
        case copySSH
        case edit
        case moveToGroup(String?)    // nil → 未分组
        case newGroup
        case delete
    }

    var body: some View {
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

    @ViewBuilder
    private func contextMenu(for profile: ServerProfile) -> some View {
        Button("连接") { onContextAction(.connect, profile) }
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
