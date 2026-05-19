import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 侧栏：保存的服务器列表。选中即向上回调发起连接。
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]

    let onOpenServer: (ServerProfile) -> Void

    @State private var showingForm = false
    @State private var editingProfile: ServerProfile?

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
                        Text("\(profile.username)@\(profile.host)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "server.rack")
                }
                .contentShape(Rectangle())
                .onTapGesture { onOpenServer(profile) }
                .onDrag { NSItemProvider(object: profile.id.uuidString as NSString) }
                .contextMenu {
                    Button("编辑") { editingProfile = profile; showingForm = true }
                    Button("删除", role: .destructive) { delete(profile) }
                }
            }
        }
        .navigationTitle("服务器")
        .toolbar {
            ToolbarItem {
                Button {
                    editingProfile = nil
                    showingForm = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("新建服务器")
            }
        }
        .sheet(isPresented: $showingForm) {
            ServerFormView(editing: editingProfile)
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
