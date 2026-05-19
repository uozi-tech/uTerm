import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [ServerProfile]
    @State private var workspace = WorkspaceModel()
    @State private var didRestore = false
    @State private var showingServerPicker = false
    @State private var showingFiles = false

    var body: some View {
        NavigationSplitView {
            ServerListView(onOpenServer: openServer)
                .frame(minWidth: 200)
        } detail: {
            WorkspaceView(workspace: workspace,
                          onNewTab: { showingServerPicker = true },
                          onOpenServerInNewTab: openServerInNewTab)
                .navigationTitle(workspace.activeTab?.title ?? "uTerm")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            showingServerPicker = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .help("新建标签")
                    }
                    ToolbarItem(placement: .principal) {
                        if let tab = workspace.activeTab {
                            HStack(spacing: 6) {
                                Text(tab.title).font(.headline)
                                if let pane = tab.focusedPane {
                                    ConnectionStatusBadge(state: pane.session.connectionState,
                                                          showsLabel: false)
                                }
                            }
                        }
                    }
                    ToolbarItem {
                        Button {
                            showingFiles.toggle()
                        } label: {
                            Image(systemName: "sidebar.right")
                        }
                        .help("文件管理器")
                    }
                }
                .inspector(isPresented: $showingFiles) {
                    Group {
                        if let tab = workspace.activeTab,
                           let serverID = activeServerID(tab),
                           let profile = profiles.first(where: { $0.id == serverID }) {
                            FileBrowserView(profile: profile)
                        } else {
                            ContentUnavailableView("未选择服务器", systemImage: "folder")
                        }
                    }
                    .inspectorColumnWidth(min: 240, ideal: 320, max: 480)
                }
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

    private func activeServerID(_ tab: TabModel) -> UUID? {
        (tab.focusedPane ?? tab.panes.values.first)?.serverProfileID
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
                        Text(profile.displayEndpoint)
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
