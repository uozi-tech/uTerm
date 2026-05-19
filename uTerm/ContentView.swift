import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]
    @State private var workspace = WorkspaceModel()
    @State private var didRestore = false
    @State private var showingServerPicker = false

    var body: some View {
        NavigationSplitView {
            ServerListView(onOpenServer: openServer)
                .frame(minWidth: 200)
        } detail: {
            WorkspaceView(workspace: workspace,
                          onNewTab: { showingServerPicker = true },
                          onOpenServerInNewTab: openServerInNewTab)
                .navigationTitle(workspace.activeTab?.title ?? "uTerm")
        }
        .task {
            guard !didRestore else { return }
            didRestore = true
            if let snapshot = WorkspaceStore().load() {
                workspace = WorkspaceModel(snapshot: snapshot)
            }
        }
        .sheet(isPresented: $showingServerPicker) {
            ServerPickerSheet { profile in
                showingServerPicker = false
                if let profile { openServer(profile) }
            }
        }
    }

    private func openServer(_ profile: ServerProfile) {
        workspace.openServer(profileID: profile.id, title: profile.name)
    }

    private func openServerInNewTab(_ serverID: UUID) {
        let title = profiles.first { $0.id == serverID }?.name ?? "终端"
        workspace.openServer(profileID: serverID, title: title)
    }
}

/// ＋ 新建标签时的服务器选择 sheet。
struct ServerPickerSheet: View {
    let onPick: (ServerProfile?) -> Void
    @Query(sort: \ServerProfile.sortOrder) private var profiles: [ServerProfile]

    var body: some View {
        VStack(spacing: 0) {
            Text("选择服务器").font(.headline).padding()
            List(profiles) { profile in
                Button {
                    onPick(profile)
                } label: {
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text("\(profile.username)@\(profile.host)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            Button("取消") { onPick(nil) }.padding()
        }
        .frame(width: 360, height: 420)
    }
}
