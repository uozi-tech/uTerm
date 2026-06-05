import SwiftUI
import SwiftData
import AppKit

/// Welcome 窗口：服务器列表 + 增删改 + 连接入口。Spec 3 重写为 toolbar +
/// sidebar + list 三层组合（Termius 风）。
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

    /// Tweaks 调试覆盖后的显示数据源（DEBUG）。Release 恒等于真实 `allProfiles`，
    /// 不引入任何行为变化。
    private var displayProfiles: [ServerProfile] {
        #if DEBUG
        TweaksModel.shared.resolvedProfiles(real: allProfiles)
        #else
        allProfiles
        #endif
    }

    /// 主列表显示用：直接走 filter。
    ///
    /// 跳板机现在是「引用一台已有服务器」（`jumpHost` 指向真实 profile），被引用者
    /// 本身仍是正常服务器，应保持可见 —— 故不再隐藏被引用的 profile。
    private var visibleProfiles: [ServerProfile] {
        filter.apply(to: displayProfiles)
    }

    private var existingGroups: [String] {
        Set(displayProfiles.compactMap { p -> String? in
            let g = p.group ?? ""
            return g.isEmpty ? nil : g
        }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            WelcomeToolbar(query: $filter.query, onNewServer: { formRoute = .new })
            HStack(spacing: 0) {
                WelcomeSidebar(profiles: displayProfiles, filter: $filter)
                    .frame(width: 224)
                bodyContent
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .background(UD.panel)
        .disablesInitialAutoFocus()  // 不要开屏自动聚焦搜索框（macOS 默认会选中第一个文本框）
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
        if displayProfiles.isEmpty {
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
        return WorkspaceWindowID(serverID: profile.id)
    }

    // MARK: actions

    private func openServer(_ profile: ServerProfile) {
        #if DEBUG
        // Mock / 空态下的行为对应假数据，拦截以免弹出无法解析的工作区窗口或误写真库。
        if TweaksModel.shared.welcomeSource != .real { return }
        #endif
        profile.lastConnectedAt = Date()
        try? modelContext.save()
        openWindow(value: WorkspaceWindowID(serverID: profile.id))
    }

    private func handleContextAction(_ action: ServerList.ContextAction,
                                      _ profile: ServerProfile) {
        #if DEBUG
        if TweaksModel.shared.welcomeSource != .real { return }
        #endif
        switch action {
        case .connect:
            openServer(profile)
        case .openSFTP:
            profile.lastConnectedAt = Date()
            try? modelContext.save()
            openWindow(value: SFTPWindowID(id: UUID(), serverID: profile.id))
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
