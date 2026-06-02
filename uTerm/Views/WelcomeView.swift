import SwiftUI
import SwiftData
import AppKit

/// Welcome 窗口：服务器列表 + 增删改 + 连接入口。当前结构为
/// `NavigationSplitView` + `.searchable` + native `.toolbar`。
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]

    @AppStorage("startupBehavior")
    private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue

    @State private var filter = ServerFilter()
    @State private var formRoute: FormRoute?
    @State private var selectedProfileID: UUID?
    @State private var pendingDelete: ServerProfile?
    @State private var didApplyStartupBehavior = false

    private enum FormRoute: Identifiable {
        case new
        case edit(ServerProfile)
        var id: String {
            switch self {
            case .new:                  return "new"
            case .edit(let p):          return p.id.uuidString
            }
        }
    }

    /// 主列表显示用：去掉作为某 profile 跳板的 profile，再走 filter。
    private var visibleProfiles: [ServerProfile] {
        let jumpIDs = Set(allProfiles.compactMap { $0.jumpHost?.id })
        let topLevel = allProfiles.filter { !jumpIDs.contains($0.id) }
        return filter.apply(to: topLevel)
    }

    private var existingGroups: [String] {
        Set(allProfiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            WelcomeSidebar(profiles: allProfiles, filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            bodyContent
        }
        .navigationTitle("uTerm")
        .searchable(text: $filter.query, prompt: "搜索 name / host / group…")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { formRoute = .new } label: {
                    Label("新建", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .sheet(item: $formRoute) { route in
            switch route {
            case .new:
                ServerFormView(editing: nil)
            case .edit(let p):
                ServerFormView(editing: p)
            }
        }
        .confirmationDialog(
            "删除服务器？",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete) { p in
                Button("删除", role: .destructive) {
                    deleteProfile(p)
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) {}
            } message: { p in
                Text("「\(p.name)」将被删除。此操作无法撤销。")
            }
        .task {
            // Spec 02: 启动协调钩子。WelcomeView 是 app 启动时 SwiftUI 实例化的
            // 第一个 view（Welcome 窗有 .defaultLaunchBehavior 默认 .presented），
            // 是最稳定的启动钩。.restore 和 .lastHost 模式下 Welcome 闪一下
            // 后由 dismissWindow 关掉自己。
            guard !didApplyStartupBehavior else { return }
            didApplyStartupBehavior = true
            await applyStartupBehavior()
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        if allProfiles.isEmpty {
            EmptyServersState(onNewServer: { formRoute = .new })
        } else {
            ServerList(profiles: visibleProfiles,
                       query: filter.query,
                       selectedID: $selectedProfileID,
                       onOpen: { openServer($0) },
                       onContextAction: handleContextAction,
                       existingGroups: existingGroups)
        }
    }

    // MARK: startup coordination (spec 02)

    @MainActor
    private func applyStartupBehavior() async {
        let behavior = StartupBehavior(rawValue: startupBehaviorRaw) ?? .welcome
        switch behavior {
        case .welcome:
            break  // 保留 Welcome 窗
        case .restore:
            dismissWindow(id: "welcome")
        case .lastHost:
            if let id = fetchLastHostWindowID() {
                openWindow(value: id)
            }
            dismissWindow(id: "welcome")
        }
    }

    private func fetchLastHostWindowID() -> WorkspaceWindowID? {
        var descriptor = FetchDescriptor<ServerProfile>(
            predicate: #Predicate { $0.lastConnectedAt != nil },
            sortBy: [SortDescriptor(\.lastConnectedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1
        guard let profile = try? modelContext.fetch(descriptor).first else { return nil }
        return WorkspaceWindowID(id: UUID(), serverID: profile.id)
    }

    // MARK: actions

    private func openServer(_ profile: ServerProfile) {
        profile.lastConnectedAt = Date()
        try? modelContext.save()
        openWindow(value: WorkspaceWindowID(id: UUID(), serverID: profile.id))
    }

    private func handleContextAction(_ action: ServerList.ContextAction,
                                      _ profile: ServerProfile) {
        switch action {
        case .connect:
            openServer(profile)
        case .togglePin:
            profile.isPinned.toggle()
            try? modelContext.save()
        case .copySSH:
            let port = profile.port == 22 ? "" : " -p \(profile.port)"
            let ssh = "ssh \(profile.username)@\(profile.host)\(port)"
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ssh, forType: .string)
        case .edit:
            formRoute = .edit(profile)
        case .moveToGroup(let g):
            profile.group = g
            try? modelContext.save()
        case .newGroup:
            promptForNewGroup(for: profile)
        case .delete:
            pendingDelete = profile
        }
    }

    private func promptForNewGroup(for profile: ServerProfile) {
        let alert = NSAlert()
        alert.messageText = "新分组"
        alert.informativeText = "为「\(profile.name)」指定一个新分组名："
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "分组名"
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                profile.group = name
                try? modelContext.save()
            }
        }
    }

    private func deleteProfile(_ profile: ServerProfile) {
        // 删除语义：清 keychain secrets + jumpHost。
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
        if selectedProfileID == profile.id { selectedProfileID = nil }
    }
}
