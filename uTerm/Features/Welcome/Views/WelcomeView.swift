import UDesignKit
import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// Welcome 窗口的内容分区：主机列表、快捷命令库，或「我的 Mac」（去控制别的 Mac）。
nonisolated enum WelcomePane: Hashable, Sendable {
    case hosts
    case quickCommands
    case remoteMacs
}

/// Welcome 窗口：服务器列表 + 增删改 + 连接入口。Spec 3 重写为 toolbar +
/// sidebar + list 三层组合（Termius 风）。
struct WelcomeView: View {
    let startupBehaviorGate: StartupBehaviorGate

    /// `initialPane` / `initialSelection` 只给界面画廊（`UICatalog`）摆初始状态用；App 里走默认值。
    init(startupBehaviorGate: StartupBehaviorGate, initialPane: WelcomePane = .hosts,
         initialSelection: UUID? = nil) {
        self.startupBehaviorGate = startupBehaviorGate
        _pane = State(initialValue: initialPane)
        _selectedProfileID = State(initialValue: initialSelection)
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.modelContext) private var modelContext
    @Environment(HostKeyChallengeRelay.self) private var launchRelay
    @Environment(RemoteMacDirectory.self) private var remoteMacs
    @Query(sort: \ServerProfile.sortOrder) private var allProfiles: [ServerProfile]
    @Query private var groups: [ServerGroup]

    @AppStorage(DefaultsKey.startupBehavior)
    private var startupBehaviorRaw: String = StartupBehavior.welcome.rawValue

    @State private var filter = ServerFilter()
    @State private var pane: WelcomePane = .hosts
    @State private var formRoute: FormRoute?
    @State private var selectedProfileID: UUID?
    @State private var draggingProfileID: UUID?
    @State private var pendingDelete: ServerProfile?
    @State private var newGroupPrompt: NewGroupPrompt?
    @State private var didReconcileGroups = false
    @State private var palette = CommandPaletteModel()
    @State private var isDropTargeted = false

    private struct NewGroupPrompt: Identifiable {
        let profile: ServerProfile
        var id: UUID { profile.id }
    }

    private enum FormRoute: Identifiable {
        case new
        case edit(ServerProfile)
        case duplicate(ServerProfile)
        var id: String {
            switch self {
            case .new:                  return "new"
            case .edit(let p):          return p.id.uuidString
            case .duplicate(let p):     return "dup-\(p.id.uuidString)"
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

    private var canReorderVisibleProfiles: Bool {
        #if DEBUG
        guard TweaksModel.shared.welcomeSource == .real else { return false }
        #endif
        guard filter.query.isEmpty else { return false }
        switch filter.section {
        case .group, .ungrouped:
            return true
        case .allHosts, .pinned, .recent:
            return false
        }
    }

    private var canDragVisibleProfiles: Bool {
        #if DEBUG
        guard TweaksModel.shared.welcomeSource == .real else { return false }
        #endif
        return true
    }

    private var existingGroups: [String] { ServerGrouping.existingNames(displayProfiles) }

    var body: some View {
        VStack(spacing: 0) {
            WelcomeTitleBar()
            WelcomeToolbar(
                query: $filter.query,
                onNewLocalShell: { openWindow.newLocalShellAskingFirst() },
                onNewServer: { formRoute = .new })
                .overlay(alignment: .bottom) { Rectangle().fill(UD.border).frame(height: 1) }
            HStack(spacing: 0) {
                // 欢迎窗口整窗一块卡面色（不用「灰画布 + 白卡」：标题栏、工具栏、侧栏全坐在
                // 灰画布上时整窗一半是灰的，用户要求去灰）。区块只用同底色的 1pt 线分：
                // 工具栏下一条横线，侧栏 | 主机列表 | 详情两条竖线。
                WelcomeSidebar(profiles: displayProfiles,
                               filter: $filter,
                               pane: $pane,
                               draggingProfileID: $draggingProfileID,
                               paletteActive: palette.isPresented,
                               onDropProfileToGroup: moveProfileToGroup)
                    .frame(width: 224)
                    .overlay(alignment: .trailing) { Rectangle().fill(UD.border).frame(width: 1) }
                bodyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        // 自绘扁平窗口 chrome（透明系统标题栏 + full-size content + 不透明卡面底）。
        // .ignoresSafeArea(.top) 把自绘标题栏顶进系统标题栏区，否则 macOS 仍在上面画
        // 系统暗夜标题栏盖住自绘 header。与 SFTPWindowView 结构一致。
        .ignoresSafeArea(.container, edges: .top)
        .background(UD.panel)
        .background(WorkspaceWindowChrome(serverName: "uTerm", background: WS.panelNSColor))
        // 主机列表键盘导航：↑↓ 移动选中、⌘↑↓ 首末、⌘E 编辑、⌘⌫ 删除。装在窗口级本地
        // 监听里（无需先点中列表）；sheet / 命令面板打开时自动让位（见 handleListKey）。
        .background(WelcomeKeyboardMonitor(handle: handleListKey).frame(width: 0, height: 0))
        .disablesInitialAutoFocus()  // 不要开屏自动聚焦搜索框（macOS 默认会选中第一个文本框）
        .commandPalette(model: palette) { welcomeCommandItems() }
        .sheet(item: $formRoute) { route in
            switch route {
            case .new:
                ServerFormView(editing: nil)
            case .edit(let p):
                ServerFormView(editing: p)
            case .duplicate(let p):
                ServerFormView(editing: nil, duplicating: p)
            }
        }
        .sheet(item: $newGroupPrompt) { prompt in
            NewGroupPromptSheet(profileName: prompt.profile.name) { name in
                assignNewGroup(named: name, to: prompt.profile)
                newGroupPrompt = nil
            }
        }
        .confirmationDialog(
            "删除主机？",
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
            guard startupBehaviorGate.claim() else { return }
            await applyStartupBehavior()
        }
        .task {
            guard !didReconcileGroups else { return }
            didReconcileGroups = true
            GroupStore(context: modelContext).reconcile()
        }
        // 应用级自启序列用 launchRelay 起隧道；首连未知主机需要信任弹窗。Welcome 在默认
        // 启动模式下常驻可见，是启动期最稳的弹窗宿主（全局转发窗口启动时尚未打开）。
        // .sheet(item:) 仅在有 pendingChallenge 时才弹，与新建表单 sheet 不冲突。
        .hostKeySheet(launchRelay)
        // 打开了 uterm://pair 邀请链接：切到「我的 Mac」，由面板接走邀请弹出确认框。
        .onChange(of: remoteMacs.pendingInvitation, initial: true) { _, invitation in
            if invitation != nil { pane = .remoteMacs }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleConfigDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(UD.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .overlay(alignment: .bottom) {
                        Text("松开以导入 SSH 配置")
                            .font(UD.caption).foregroundStyle(UD.accent)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(UD.panel, in: Capsule())
                            .padding(.bottom, 24)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if pane == .quickCommands {
            QuickCommandList(hosts: displayProfiles)
        } else if pane == .remoteMacs {
            RemoteMacsPane()
        } else if displayProfiles.isEmpty {
            EmptyServersState(onNewServer: { formRoute = .new })
        } else {
            ServerList(profiles: visibleProfiles,
                       query: filter.query,
                       selectedID: $selectedProfileID,
                       draggingProfileID: $draggingProfileID,
                       onOpen: { openServer($0) },
                       onContextAction: handleContextAction,
                       existingGroups: existingGroups,
                       groupColors: ServerGroupTint.colors(for: groups),
                       rowDragEnabled: canDragVisibleProfiles,
                       reorderEnabled: canReorderVisibleProfiles,
                       onMove: moveVisibleProfile)
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
            // 冷启动是打开邀请链接带起来的：欢迎窗口要留着给它确认。
            guard remoteMacs.pendingInvitation == nil else { return }
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

    // MARK: 键盘导航

    /// 窗口级 keyDown 回调（见 `WelcomeKeyboardMonitor`）。返回 true = 消费该事件。
    ///
    /// 仅在「主机列表」面板、列表非空、且命令面板未开时接管 ↑↓ / ⌘↑↓ / ⌘E / ⌘⌫；其余
    /// 一律放行（return false），把 ↩ / ⌘↩（HostDetailPanel 按钮）、命令面板、文本输入等
    /// 交回系统。sheet（编辑/新分组）是独立子窗口，monitor 的 `event.window === key` 判定
    /// 已把它们排除，这里无需再判。
    private func handleListKey(_ event: NSEvent) -> Bool {
        guard !palette.isPresented else { return false }     // 面板开着时让它自己处理上下键
        guard pane == .hosts else { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isTextEditing = event.window?.firstResponder is NSText
        guard let action = WelcomeKeymap.listAction(
            keyCode: event.keyCode,
            chars: event.charactersIgnoringModifiers?.lowercased() ?? "",
            command: mods.contains(.command),
            option: mods.contains(.option),
            control: mods.contains(.control),
            isTextEditing: isTextEditing
        ) else { return false }

        let list = visibleProfiles
        guard !list.isEmpty else { return false }

        switch action {
        case .prev, .next, .first, .last:
            moveSelection(action, in: list)
        case .edit:
            guard let p = currentSelectedProfile(in: list) else { return false }
            formRoute = .edit(p)
        case .delete:
            guard let p = currentSelectedProfile(in: list) else { return false }
            pendingDelete = p
        case .duplicate:
            guard let p = currentSelectedProfile(in: list) else { return false }
            formRoute = .duplicate(p)
        }
        return true
    }

    private func currentSelectedProfile(in list: [ServerProfile]) -> ServerProfile? {
        if let id = selectedProfileID, let p = list.first(where: { $0.id == id }) { return p }
        return list.first
    }

    /// 在当前可见列表里按动作移动选中项（钳制在两端，不回绕）。无选中时 ↑/↓ 落到首/末。
    private func moveSelection(_ action: WelcomeListKey, in list: [ServerProfile]) {
        guard let id = selectedProfileID, let idx = list.firstIndex(where: { $0.id == id }) else {
            selectedProfileID = (action == .last ? list.last : list.first)?.id
            return
        }
        let newIdx: Int
        switch action {
        case .prev:  newIdx = max(0, idx - 1)
        case .next:  newIdx = min(list.count - 1, idx + 1)
        case .first: newIdx = 0
        case .last:  newIdx = list.count - 1
        case .edit, .delete, .duplicate: return
        }
        selectedProfileID = list[newIdx].id
    }

    // MARK: actions

    /// Welcome 窗口的命令项：主机（连接=开工作区窗）/ 新建主机 / 新建本机终端 / 设置深链。
    @MainActor
    private func welcomeCommandItems() -> [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []
        for p in allProfiles {
            let id = p.id
            let name = p.name.isEmpty ? p.host : p.name
            items.append(CommandPaletteItem(
                id: "host.\(id.uuidString)", kind: .host,
                title: name, detail: "\(p.username)@\(p.host)",
                hint: "连接", group: p.group) {
                    openServer(p)
                })
        }
        items.append(CommandPaletteItem(
            id: "cmd.newHost", kind: .command,
            title: "新建主机…", detail: "添加一台主机", hint: "⌘N", group: nil) {
                formRoute = .new
            })
        items.append(CommandPaletteItem(
            id: "cmd.newLocalShell", kind: .command,
            title: "新建本机终端", detail: "在这台 Mac 上开一个 shell", hint: "⇧⌘N", group: nil) {
                openWindow.newLocalShellAskingFirst()
            })
        items.append(CommandPaletteItem(
            id: "cmd.manageGroups", kind: .command,
            title: "管理分组…", detail: "新建 / 重命名 / 删除分组", hint: "↵", group: nil) {
                openWindow(id: "groups")
            })
        items.append(CommandPaletteItem(
            id: "cmd.importConfig", kind: .command,
            title: "导入 ~/.ssh/config", detail: "从本地 SSH config 批量导入", hint: "↵", group: nil) {
                openWindow(id: "import")
            })
        items.append(CommandPaletteItem(
            id: "cmd.globalForwarding", kind: .command,
            title: "全局端口转发…", detail: "跨主机管理端口转发，可随 uTerm 启动", hint: "↵", group: nil) {
                openWindow(id: "global-forwarding")
            })
        items.append(contentsOf: commandPaletteSettingsItems(openSettings: { openWindow(id: SettingsWindow.id) }))
        items.append(contentsOf: commandPaletteAccentItems())
        return items
    }

    /// 拖入 config 文件或 ~/.ssh 目录 → 拷进容器 staging → 解析 → 经 ImportInbox 打开向导到 review。
    /// 受理返回 true（实际处理异步）。沙箱：在源 URL 安全作用域内拷贝，之后只读容器内拷贝件。
    private func handleConfigDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }) else { return false }

        // 主线程先快照现有名字 + openWindow 动作，避免在后台回调里碰 @Query / 捕获整个 View。
        let existingNames = Set(allProfiles.map(\.name))
        let open = openWindow

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = Self.fileURL(from: item) else { Self.failDrop("loadItem 未解出 fileURL"); return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("uTerm-ssh-import", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                let staged = try SSHConfigDropStaging.stage(source: url, intoRoot: root)
                guard let located = SSHConfigDropStaging.locateConfig(in: staged) else {
                    try? FileManager.default.removeItem(at: root); Self.failDrop("locateConfig 失败/无 config"); return
                }
                let text = try String(contentsOf: located.config, encoding: .utf8)
                let hosts = parseSSHConfig(text)
                guard !hosts.isEmpty else {
                    try? FileManager.default.removeItem(at: root); Self.failDrop("config 未解析出 Host"); return
                }
                let dir = located.dir
                Task { @MainActor in
                    let rows = SSHConfigImporter.plan(hosts, existingNames: existingNames)
                    ImportInbox.shared.enqueue(.init(rows: rows, dir: dir, stagingRoot: root))
                    open(id: "import")
                }
            } catch {
                try? FileManager.default.removeItem(at: root)
                Self.failDrop("\(error)")
            }
        }
        return true
    }

    /// loadItem 回调里把 item 解成 fileURL：可能是 URL，或 URL 的 dataRepresentation（非 bookmark）。
    /// nonisolated：在 loadItem 的后台线程上调用，不能跨进主 actor。
    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }

    /// 拖放导入失败：记日志 + 提示音（在后台线程调用，故 nonisolated）。
    nonisolated private static func failDrop(_ reason: String) {
        // 包进 Task { @MainActor in }：日志与 NSSound.beep() 都要在主线程执行。
        Task { @MainActor in
            AppLogger.error("SSH config 拖放导入失败：\(reason)", category: "import")
            NSSound.beep()
        }
    }

    private func openServer(_ profile: ServerProfile) {
        #if DEBUG
        // Mock / 空态下的行为对应假数据，拦截以免弹出无法解析的工作区窗口或误写真库。
        if TweaksModel.shared.welcomeSource != .real { return }
        #endif
        ServerWindowOpener.connect(profile, context: modelContext, openWindow: openWindow)
    }

    /// 打开 SFTP 文件浏览窗口。`.openSFTP` 动作与「仅 SFTP」主机的连接重定向共用此入口。
    private func openSFTP(_ profile: ServerProfile) {
        profile.lastConnectedAt = Date()
        try? modelContext.save()
        openWindow(value: SFTPWindowID(id: UUID(), serverID: profile.id))
    }

    /// 在终端中打开（「终端 ⇄ Agent」两态的终端窗口）：有终端窗口就作为新标签送进最近
    /// 活跃的那个，没有才新开 —— 不再一台主机一个窗口。
    private func openTerminalWindow(_ profile: ServerProfile) {
        profile.lastConnectedAt = Date()
        try? modelContext.save()
        if TerminalWindowRouter.shared.openInExistingWindow(serverID: profile.id) { return }
        openWindow(value: TerminalWindowID(id: UUID(), serverID: profile.id))
    }

    private func handleContextAction(_ action: ServerList.ContextAction,
                                      _ profile: ServerProfile) {
        #if DEBUG
        if TweaksModel.shared.welcomeSource != .real { return }
        #endif
        switch action {
        case .connect:
            openServer(profile)
        case .openTerminalWindow:
            openTerminalWindow(profile)
        case .openSFTP:
            openSFTP(profile)
        case .togglePin:
            profile.isPinned.toggle()
            try? modelContext.save()
        case .edit:
            formRoute = .edit(profile)
        case .moveToGroup(let g):
            profile.group = g
            if let g { GroupStore(context: modelContext).ensure(name: g) }
            try? modelContext.save()
        case .newGroup:
            newGroupPrompt = NewGroupPrompt(profile: profile)
        case .duplicate:
            formRoute = .duplicate(profile)
        case .delete:
            pendingDelete = profile
        }
    }

    private func assignNewGroup(named rawName: String, to profile: ServerProfile) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            profile.group = name
            GroupStore(context: modelContext).ensure(name: name)
            try? modelContext.save()
        }
    }

    private func moveVisibleProfile(from sourceID: UUID, to targetID: UUID) {
        guard canReorderVisibleProfiles else { return }
        var order = visibleProfiles
        guard let fromIdx = order.firstIndex(where: { $0.id == sourceID }),
              let toIdx = order.firstIndex(where: { $0.id == targetID }),
              fromIdx != toIdx else { return }
        let moved = order.remove(at: fromIdx)
        order.insert(moved, at: min(toIdx, order.count))
        selectedProfileID = sourceID
        withAnimation(.easeInOut(duration: 0.18)) {
            ServerProfileStore(context: modelContext).reorderVisible(order, within: displayProfiles)
        }
    }

    private func moveProfileToGroup(_ profileID: UUID, _ groupName: String?) {
        #if DEBUG
        if TweaksModel.shared.welcomeSource != .real { return }
        #endif
        guard let profile = allProfiles.first(where: { $0.id == profileID }) else { return }
        selectedProfileID = profileID
        withAnimation(.easeInOut(duration: 0.18)) {
            handleContextAction(.moveToGroup(groupName), profile)
        }
    }

    private func deleteProfile(_ profile: ServerProfile) {
        // 钥匙串 secrets / 端口转发规则 / 跳板机悬空引用的清理见 `ServerProfileStore.delete`。
        let deletedID = profile.id
        ServerProfileStore(context: modelContext).delete(profile)
        if selectedProfileID == deletedID { selectedProfileID = nil }
    }
}

private struct NewGroupPromptSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profileName: String
    let onSubmit: (String) -> Void

    @State private var name = ""

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("新分组")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(UD.text)
                Text("为「\(profileName)」指定一个新分组名：")
                    .font(UD.caption)
                    .foregroundStyle(UD.text3)
            }

            UDTextField(placeholder: "分组名", text: $name)
                .onSubmit(submit)

            HStack(spacing: 8) {
                Spacer()
                UDButton(title: "取消", style: .secondary) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                UDButton(title: "确定", style: .primary, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(22)
        .frame(width: 360)
        .background(UD.bg)
        .onExitCommand {
            dismiss()
        }
    }

    private func submit() {
        guard canSubmit else { return }
        onSubmit(trimmedName)
    }
}

/// Welcome 窗口自绘扁平标题栏（对齐设计稿 `u-window.jsx` 的 `TitleBar`）：左侧让位
/// 窗口红绿灯（~68pt），随后 "uTerm" 标识。与整窗同为卡面色，无分隔线。
/// 替代 macOS 系统标题栏 —— 后者在暗夜下是更浅的系统灰，盖在设计稿底色 UD.bg 之上。
/// `WindowDragHandle` 既画实色底又充当窗口拖动手柄（红绿灯更靠前、点击不落到手柄）。
struct WelcomeTitleBar: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            // 让位窗口红绿灯：系统红绿灯簇约占 ~x13–72，左对齐文字须躲到其右侧。
            // 对齐设计稿 u-window.jsx TitleBar（14px 内边距 + 52px 灯 + 16px 间隙 ≈ 82）。
            Color.clear.frame(width: 84)
            Text("uTerm")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(UD.text2)
                .allowsHitTesting(false)   // 纯展示，不截走标题栏双击 / 拖动
            Spacer()
            // 全局转发入口：标题栏右侧 icon（按钮覆于 WindowDragHandle 之上，独立接收点击）。
            UDIconButton(systemImage: "arrow.left.arrow.right") {
                openWindow(id: "global-forwarding")
            }
            .help("全局端口转发")
            .padding(.trailing, 8)
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(WindowDragHandle(fill: WS.panelNSColor))
    }
}
