import SwiftUI
import SwiftData
import AppKit

/// Welcome 窗口：服务器列表 + 增删改 + 连接入口。Spec 3 重写为 toolbar +
/// sidebar + list 三层组合（Termius 风）。
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]

    @State private var filter = ServerFilter()
    @State private var formRoute: FormRoute?
    @State private var selectedProfileID: UUID?
    @State private var pendingDelete: ServerProfile?

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
        VStack(spacing: 0) {
            WelcomeToolbar(query: $filter.query, onNewServer: { formRoute = .new })
            HStack(spacing: 0) {
                WelcomeSidebar(profiles: allProfiles, filter: $filter)
                    .frame(width: 200)
                bodyContent
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(AppTheme.Palette.bgBase)
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
        // 沿用现有 ServerListView 的删除语义：清 keychain secrets + jumpHost。
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
