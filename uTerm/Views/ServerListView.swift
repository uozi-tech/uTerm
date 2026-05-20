import SwiftUI
import SwiftData

/// 侧栏：保存的服务器列表。选中即向上回调发起连接。
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]

    let onOpenServer: (ServerProfile) -> Void

    /// 表单 sheet 的两种用途。用 `.sheet(item:)` 驱动 —— 值直接传入闭包参数，
    /// 避免 `isPresented` + 独立 `@State` 在同一渲染事务里读到过期（nil）的 profile。
    private enum FormRoute: Identifiable {
        case new
        case edit(ServerProfile)

        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let profile): return profile.id.uuidString
            }
        }
    }

    @State private var formRoute: FormRoute?

    /// 只显示顶层服务器 —— 作为某台服务器跳板机的 profile 不单独列出。
    private var topLevelProfiles: [ServerProfile] {
        let jumpIDs = Set(allProfiles.compactMap { $0.jumpHost?.id })
        return allProfiles.filter { !jumpIDs.contains($0.id) }
    }

    var body: some View {
        List {
            ForEach(topLevelProfiles) { profile in
                Label {
                    VStack(alignment: .leading) {
                        Text(profile.name).font(.body)
                        Text(profile.displayEndpoint)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpenServer(profile) }
                .contextMenu {
                    Button("编辑") { formRoute = .edit(profile) }
                    Button("删除", role: .destructive) { delete(profile) }
                }
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem {
                Button {
                    formRoute = .new
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建服务器")
            }
        }
        .sheet(item: $formRoute) { route in
            switch route {
            case .new:
                ServerFormView(editing: nil)
            case .edit(let profile):
                ServerFormView(editing: profile)
            }
        }
    }

    private func delete(_ profile: ServerProfile) {
        let keychain = KeychainStore()
        for kind in [SecretKind.password, .passphrase, .privateKey] {
            try? keychain.delete(profileID: profile.id, kind: kind)
            if let jump = profile.jumpHost {
                try? keychain.delete(profileID: jump.id, kind: kind)
            }
        }
        if let jump = profile.jumpHost { modelContext.delete(jump) }
        modelContext.delete(profile)
        try? modelContext.save()
    }
}
