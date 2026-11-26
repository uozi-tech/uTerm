import SwiftUI

/// 主机页的「我的 Mac」：配对过的 Mac，在线的点进 `RemoteMacSheet`；下面「附近的 Mac」列局域网里还没配对、
/// 登记在同一个 iCloud 账户里的，点了同样进 `RemoteMacSheet`，先在 Mac 上输入这里显示的 6 位码。
/// 不在这个账户里的 Mac 不自动列出来：从「扫码配对」进去，扫它的二维码，或在那一页里点「附近的其他 Mac」挑一台。
struct RemoteMacSection: View {
    /// 可选：样式画廊、探针等直接渲染主机页的地方不注入它，那时整块不显示。
    @Environment(RemoteMacDirectory.self) private var injected: RemoteMacDirectory?
    @Environment(MobileStore.self) private var store: MobileStore?
    @State private var selected: RemoteMacDirectory.Mac?
    @State private var scanning = false
    /// 在扫码页的「附近的其他 Mac」里挑的那台：扫码页收起之后打开它的配对页。
    @State private var pendingNearby: RemoteMacDirectory.Mac?
    @State private var diagnosing: RemoteMacDirectory.Mac?
    @Environment(\.mAccent) private var accent

    var body: some View {
        if let directory = injected {
            group(directory)
        }
    }

    private func group(_ directory: RemoteMacDirectory) -> some View {
        VStack(spacing: 12) {
            MInsetGroup(header: String(localized: "我的 Mac"), headerTrailing: AnyView(scanButton)) {
                if !directory.isActivated {
                    MInsetRow(icon: "mac", label: String(localized: "控制我的 Mac 上的终端"), chevron: true, last: true) {
                        directory.activate()
                    }
                } else if directory.macs.isEmpty {
                    MInsetRow(icon: "mac", label: String(localized: "还没有配对的 Mac"),
                              sub: directory.nearbyMacs.isEmpty
                                  ? String(localized: "在登录同一个 iCloud 账户的 Mac 上打开「远程控制」，或扫 Mac 上的二维码")
                                  : String(localized: "在下面选一台开始配对"),
                              last: true)
                } else {
                    ForEach(directory.macs) { mac in
                        macRow(mac, last: mac.id == directory.macs.last?.id)
                    }
                }
            }
            if directory.isActivated, !directory.nearbyMacs.isEmpty {
                MInsetGroup(header: String(localized: "附近的 Mac"),
                            footer: String(localized: "同一局域网里、和这台设备登录同一个 iCloud 账户、还没配对的 Mac。点一下，在 Mac 上输入这里显示的 6 位数即可配对。")) {
                    ForEach(directory.nearbyMacs) { mac in
                        MInsetRow(icon: "mac", label: mac.name, value: String(localized: "配对"), chevron: true,
                                  last: mac.id == directory.nearbyMacs.last?.id) {
                            selected = mac
                        }
                    }
                }
            }
        }
        // 可见期间按间隔问中继谁在线；切到别的标签页、进终端就不再问（省电，见 `keepLiveStatusFresh`）。
        .task { await directory.keepLiveStatusFresh() }
        .onAppear {
            if directory.isActivated { directory.startBrowsing() }
            openPendingIfOnline(directory)
            #if DEBUG
            // 调试：启动参数 `-RemoteDebugOpenDesktop YES`（配合 `-RemoteDebugEndpoint`）直接打开第一台 Mac 的屏幕，
            // 模拟器联调远程桌面时不用手点。
            if UserDefaults.standard.bool(forKey: DefaultsKey.remoteDebugOpenDesktop), let mac = directory.macs.first,
               let store, store.remoteDesktop == nil {
                store.remoteDesktop = MRemoteDesktopRequest(client: directory.client(for: mac))
            }
            #endif
        }
        .sheet(item: $selected, onDismiss: { directory.refreshPaired() }) { mac in
            RemoteMacSheet(client: directory.client(for: mac)) { directory.forget(mac) }
        }
        .sheet(item: $diagnosing) { mac in
            NavigationStack {
                RemoteNetworkDiagnosticsScreen(preferredMacID: mac.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("关闭") { diagnosing = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $scanning, onDismiss: {
            guard let mac = pendingNearby else { return }
            pendingNearby = nil
            selected = mac
        }) {
            RemotePairingScanner(onScanned: { invitation in
                scanning = false
                guard let mac = try? directory.pair(with: invitation) else { return }
                directory.pendingOpenMacID = mac.id
                openPendingIfOnline(directory)
            }, onRelayConfig: { config in
                scanning = false
                directory.importRelayConfig(config)
            }, nearby: directory, onNearby: { mac in
                // 先收起扫码页，等它的收起动画走完再弹配对页（两个 sheet 不能同时换）。
                scanning = false
                pendingNearby = mac
            })
        }
        .onChange(of: directory.macs) { _, _ in openPendingIfOnline(directory) }
        .onChange(of: directory.pendingOpenMacID) { _, _ in openPendingIfOnline(directory) }
    }

    /// 刚凭邀请（扫码或链接）配上的 Mac：一上线（局域网或中继）就自动打开，用掉邀请完成配对。
    private func openPendingIfOnline(_ directory: RemoteMacDirectory) {
        guard let id = directory.pendingOpenMacID, selected == nil,
              let mac = directory.macs.first(where: { $0.id == id }), mac.isOnline else { return }
        directory.pendingOpenMacID = nil
        selected = mac
    }

    /// 不自动出现的 Mac（不在同一局域网，或不在本机的 iCloud 账户里）：扫它「设置 › 远程控制」里的二维码配对；
    /// 扫码页里另有「附近的其他 Mac」，列同一局域网里不在这个账户里的 Mac。
    private var scanButton: some View {
        Button { scanning = true } label: {
            Label("扫码配对", systemImage: "qrcode.viewfinder")
                .font(M.sans(13, weight: .medium))
                .foregroundStyle(accent)
        }
        .buttonStyle(.borderless)
    }

    /// 局域网里在就不写（最常见、不用提醒），否则写走哪条路（`RemoteMacDirectory.Mac.reachabilityLabel`）。
    private func rowValue(_ mac: RemoteMacDirectory.Mac) -> String? {
        mac.endpoint != nil ? nil : mac.reachabilityLabel(.path)
    }

    private func macRow(_ mac: RemoteMacDirectory.Mac, last: Bool) -> some View {
        MInsetRow(icon: "mac", iconColor: mac.isOnline ? nil : M.text3, label: mac.name,
                  value: rowValue(mac), chevron: mac.isOnline, last: last,
                  onTap: mac.isOnline ? { selected = mac } : nil)
            .mContextMenu(preview: RoundedRectangle(cornerRadius: MRadius.list)) {
                if mac.isOnRelay {
                    Button { diagnosing = mac } label: { Label("网络诊断", systemImage: "stethoscope") }
                }
            }
    }
}

/// 一台 Mac：首次连接走配对（这里显示 6 位码，在 Mac 上输入），之后列出 Mac 上的终端。
struct RemoteMacSheet: View {
    let client: RemoteMacClient
    /// 「忘记这台 Mac」：由目录做（拉黑、丢掉客户端）。没给时只让客户端自己撤销信任。
    var onForget: (() -> Void)? = nil
    @Environment(MobileStore.self) private var store
    @Environment(MobileWorkspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var openingShell = false
    @State private var shellError: String?
    @State private var workspaceChoices: RemoteLocalWorkspaces?
    @State private var pendingClose: RemoteSessionInfo?
    /// 进了「窗口模式」那一页（列 Mac 上的窗口，点一个直接只看它）。
    @State private var choosingWindow = false

    var body: some View {
        NavigationStack {
            content
            .background(M.canvas)
            .navigationDestination(isPresented: $choosingWindow) {
                MacWindowListPage(client: client) { openDesktop(window: $0) }
            }
            .navigationTitle(client.macName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(M.canvas)
        .task { await client.connectInteractively() }
        .alert("无法新建终端", isPresented: Binding(get: { shellError != nil },
                                                   set: { if !$0 { shellError = nil } })) {
            Button("好", role: .cancel) { shellError = nil }
        } message: {
            Text(shellError ?? "")
        }
        .alert("关闭「\(pendingClose?.displayTitle ?? "")」？",
               isPresented: Binding(get: { pendingClose != nil }, set: { if !$0 { pendingClose = nil } }),
               presenting: pendingClose) { session in
            Button("关闭", role: .destructive) { client.closeSessionOnMac(session.id) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这个终端会在「\(client.macName)」上关闭，里面正在运行的程序也会结束。")
        }
    }

    /// 正在连（含失败后自动重试中）。
    private var connectingRow: some View {
        scrolling {
            statusRow(icon: "refresh", text: client.connectProgress?.title ?? "", detail: client.connectProgress?.detail)
        }
    }

    @ViewBuilder private var content: some View {
        switch client.state {
        case .idle, .connecting:
            connectingRow
        case .failed where client.isAutoRetrying:
            connectingRow
        case .awaitingApproval(let code):
            scrolling { pairing(code) }
        case .failed(let message):
            scrolling {
                MInsetGroup(footer: client.failureContext) {
                    MInsetRow(icon: "warn", iconColor: M.danger, label: String(localized: "连接失败"), sub: message, last: false)
                    MInsetRow(icon: "refresh", label: String(localized: "重试"), chevron: true, last: true) {
                        Task { await client.connectInteractively() }
                    }
                }
            }
        case .connected:
            sessions
                .safeAreaInset(edge: .top, spacing: 0) { pathBadge }
        }
    }

    /// 这条连接走哪条路、延迟多少。中继上卡顿时用户一眼能看出原因。
    @ViewBuilder private var pathBadge: some View {
        if let path = client.path {
            HStack(spacing: 6) {
                Text(path.label)
                if let millis = client.roundTripMillis { Text("\(millis) ms") }
            }
            .font(M.sans(12))
            .foregroundStyle(M.text3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }

    private func scrolling(@ViewBuilder _ content: () -> some View) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) { content() }
                .padding(.vertical, 16)
        }
    }

    private func statusRow(icon: String, text: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ProgressView()
                Text(text).font(M.sans(14)).foregroundStyle(M.text2)
            }
            if let detail {
                Text(detail).font(M.sans(12)).foregroundStyle(M.text3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func pairing(_ code: String) -> some View {
        VStack(spacing: 14) {
            Text(RemotePairingCopy.controllerTitle(client.macName)).font(M.sans(18, weight: .bold)).foregroundStyle(M.text)
                .multilineTextAlignment(.center)
            Text(RemotePairingCode.grouped(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(M.text)
            Text(RemotePairingCopy.controllerDetail)
                .font(M.sans(13)).foregroundStyle(M.text3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            ProgressView().padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // List 而不是 MInsetGroup：swipeActions 只在 List 里生效。
    private var sessions: some View {
        List {
            section(String(localized: "这台 Mac"),
                    footer: client.supportsLocalShell
                        ? String(localized: "在 Mac 上打开你的登录 shell，并在 Mac 上弹出对应的终端窗口；断开后终端仍留在 Mac 上，可以接着用。")
                        : String(localized: "Mac 上的 uTerm 版本过旧，无法新建终端。将其更新到最新版本后即可使用。")) {
                if client.supportsLocalShell {
                    MInsetRow(icon: "term", label: openingShell ? String(localized: "正在打开…") : String(localized: "新建终端"),
                              sub: String(localized: "Mac 本机的 shell"), chevron: !openingShell, last: true) {
                        guard !openingShell else { return }
                        Task { await chooseWorkspace() }
                    }
                    .macWorkspaceDialog($workspaceChoices) { directory in
                        Task { await openLocalShell(directory: directory) }
                    }
                } else {
                    MInsetRow(icon: "term", iconColor: M.text3, label: String(localized: "新建终端"), sub: String(localized: "需要更新 Mac 上的 uTerm"), last: true)
                }
            }
            section(String(localized: "屏幕", comment: "Mac 面板分组：远程桌面"),
                    footer: client.supportsDesktop ? nil : String(localized: "Mac 上的 uTerm 版本过旧，不支持远程桌面。将其更新到最新版本后即可使用。")) {
                if client.supportsDesktop {
                    // 分隔线交给 List（`last: true` 关掉行自带的）。
                    MInsetRow(icon: "display", label: String(localized: "查看并控制屏幕"), sub: String(localized: "像触控板一样操作 Mac 的鼠标与键盘"),
                              chevron: true, last: true) {
                        openDesktop()
                    }
                    if client.supportsDesktopWindows {
                        MInsetRow(icon: "window", label: String(localized: "窗口模式"), sub: String(localized: "只看一个窗口，并调成适合这里的大小"),
                                  chevron: true, last: true) {
                            choosingWindow = true
                        }
                    }
                } else {
                    MInsetRow(icon: "display", iconColor: M.text3, label: String(localized: "查看并控制屏幕"), sub: String(localized: "需要更新 Mac 上的 uTerm"), last: true)
                }
            }
            section(String(localized: "文件", comment: "Mac 面板分组：浏览文件"), footer: client.supportsFiles
                        ? String(localized: "从主目录开始浏览这台 Mac 上的文件，可以上传、下载、改名和删除。Mac 不用打开 SSH。")
                        : String(localized: "Mac 上的 uTerm 版本过旧，不支持浏览文件。将其更新到最新版本后即可使用。")) {
                if client.supportsFiles {
                    MInsetRow(icon: "folder", label: String(localized: "浏览文件"), sub: String(localized: "Mac 上的文件"), chevron: true, last: true) {
                        openFiles()
                    }
                } else {
                    MInsetRow(icon: "folder", iconColor: M.text3, label: String(localized: "浏览文件"), sub: String(localized: "需要更新 Mac 上的 uTerm"), last: true)
                }
            }
            section(String(localized: "Mac 上的终端"),
                    footer: String(localized: "点任意一个都会接管这台 Mac 上的全部终端，各开一个标签页，之后 Mac 上新开或关闭终端，手机上的标签页也跟着变，直到点「断开全部终端」。接管期间它们按这台手机的尺寸运行，Mac 上的窗格会标出「正在接管」，断开后恢复。")) {
                if client.sessions.isEmpty {
                    MInsetRow(icon: "term", label: String(localized: "Mac 上没有已连接的终端"), sub: String(localized: "在 Mac 上打开一个终端后会出现在这里"), last: true)
                } else {
                    // Mac 的 Code 标签页收成一行（里面的会话接管后也是手机上的一个 Code 标签页），排在它在 Mac 上的位置。
                    let rows = RemoteMacSessionRow.rows(sessions: client.sessions, codeTab: client.codeTabs?.mirrored())
                    ForEach(rows) { row in
                        // 分隔线交给 List（`last: true` 关掉行自带的），滑动时才会跟着行走。
                        switch row {
                        case .session(let session):
                            MInsetRow(icon: "term", label: session.displayTitle, sub: subtitle(session),
                                      chevron: true, last: true) {
                                takeOver(focus: session.id)
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: false) { closeAction(session) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { closeAction(session) }
                        case .codeTab(let info, let sessions):
                            // 一个会话都没有时接管落在别的终端上；整台 Mac 一个终端都没有就不能点。
                            let focus = row.focus ?? client.sessions.first?.id
                            MInsetRow(icon: "code", label: "Code", sub: codeSubtitle(info, sessions: sessions),
                                      chevron: focus != nil, last: true,
                                      onTap: focus.map { focus in { takeOver(focus: focus) } })
                        }
                    }
                }
                if workspace.followedClients.contains(where: { $0 === client }) {
                    let taken = workspace.remoteTabIDs(of: client)
                    MInsetRow(icon: "x", label: String(localized: "断开全部终端"),
                              sub: taken.isEmpty ? String(localized: "不再自动接入这台 Mac 新开的终端")
                                  : String(localized: "关闭手机上的 \(taken.count) 个标签页，Mac 上的终端继续运行"),
                              last: true) {
                        endTakeover()
                    }
                }
            }
            section(nil, footer: nil) {
                MInsetRow(icon: "x", label: String(localized: "忘记这台 Mac"), danger: true, last: true) {
                    endTakeover()
                    if let onForget { onForget() } else { client.forget() }
                    dismiss()
                }
            }
        }
        .scrollContentBackground(.hidden)
        .animation(.default, value: client.sessions.map(\.id))
    }

    private func section(_ header: String?, footer: String?, @ViewBuilder rows: () -> some View) -> some View {
        Section {
            rows()
                .listRowInsets(EdgeInsets())
                .listRowBackground(M.card)
        } header: {
            if let header { Text(header) }
        } footer: {
            if let footer { Text(footer) }
        }
    }

    /// 老 Mac 不认 `closeSession`（收到会断开整条连接），那时不给这个动作。
    /// 不用 role: .destructive：那会在确认之前就把行乐观地划走。
    @ViewBuilder private func closeAction(_ session: RemoteSessionInfo) -> some View {
        if client.supportsCloseSession {
            Button { pendingClose = session } label: { Image(systemName: "trash") }
                .tint(M.danger)
                .accessibilityLabel("删除")
        }
    }

    private func subtitle(_ session: RemoteSessionInfo) -> String {
        var parts = [session.serverName]
        if let controller = session.controlledBy { parts.append(String(localized: "\(controller) 正在接管")) }
        return parts.joined(separator: " · ")
    }

    /// Code 那一行：哪台主机、几个会话在跑、谁在接管（里面任一个被接管就写）。
    private func codeSubtitle(_ info: RemoteCodeTabInfo, sessions: [RemoteSessionInfo]) -> String {
        var parts = [info.serverName]
        let listed = Set(sessions.map(\.id))
        let running = info.runs.filter { $0.endedAt == nil && listed.contains($0.session) }.count
        if running > 0 {
            parts.append(String(localized: "\(running) 个会话正在运行", comment: "Code 标签页收起的侧栏上：在跑的会话个数"))
        }
        if let controller = sessions.lazy.compactMap(\.controlledBy).first {
            parts.append(String(localized: "\(controller) 正在接管"))
        }
        return parts.joined(separator: " · ")
    }

    /// `window`：直接只看这个窗口（不先开整个屏幕）。窗口要按画布的大小调，得等全屏页排好版才知道，所以不提前开流。
    private func openDesktop(window: UInt32? = nil) {
        let tapped = ContinuousClock.now
        let session = window == nil ? Self.startDesktopEarly(client: client, tappedAt: tapped) : nil
        dismiss()
        let client = self.client
        // 同终端：等面板收起再盖全屏，避免两个转场叠在一起。知道要多大时流已经在开了（`startDesktopEarly`）。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openRemoteDesktop(MRemoteDesktopRequest(client: client, tappedAt: tapped, session: session, windowID: window))
        }
    }

    /// 这块屏幕开过屏、记得要多大：点按钮就开流，不等面板收起、全屏页排版（见 `RemoteDesktopRequestSizeMemory`）。
    private static func startDesktopEarly(client: RemoteMacClient, tappedAt: ContinuousClock.Instant)
        -> RemoteDesktopSession? {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.keyWindow else { return nil }
        let scale = window.screen.scale
        guard let size = RemoteDesktopRequestSizeMemory.load(screen: window.bounds.size, scale: scale) else { return nil }
        let session = RemoteDesktopSession(client: client, maxWidth: size.width, maxHeight: size.height,
                                           pointScale: RemoteDesktopRequestSize.pointScale(displayScale: scale))
        session.openRequestedAt = tappedAt
        Task { await session.start() }
        return session
    }

    private func openFiles() {
        dismiss()
        let client = self.client
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openRemoteFiles(client)
        }
    }

    private func endTakeover() {
        store.teardownTabIDs = workspace.endTakeover(of: client)
    }

    private func takeOver(focus: UUID) {
        dismiss()
        let client = self.client
        // 等面板收起再开，避免连接中页与收起动画叠在一起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.takeOver(client, focus: focus)
        }
    }

    /// Mac 有最近的工作区就先问开在哪，没有就直接开。
    private func chooseWorkspace() async {
        openingShell = true
        let plan = await client.newShellPlan()
        openingShell = false
        switch plan {
        case .ask(let workspaces): workspaceChoices = workspaces
        case .openDirectly: await openLocalShell(directory: nil)
        }
    }

    private func openLocalShell(directory: String?) async {
        openingShell = true
        defer { openingShell = false }
        do {
            let sessionID = try await client.openLocalShell(directory: directory)
            takeOver(focus: sessionID)
        } catch {
            shellError = error.localizedDescription
        }
    }
}

extension RemoteMacClient {
    /// 远控标签的 `ServerProfile`（标题、连接中页的名字）：**不入库**的临时对象，只描述 Mac 上那个终端。
    /// 传输不读它的连接参数，所以不要求这台服务器已同步到手机；Mac 本机 shell 没有服务器，用这台 Mac 代表。
    /// 「最近连接」这类记账已按 `modelContext == nil` 跳过。
    /// 文件标签挂的临时主机：只用来显示名字，不入库。
    var filesTabHost: ServerProfile {
        let host = ServerProfile()
        host.id = RemoteConstants.localShellServerID
        host.name = macName
        host.host = String(localized: "本机")
        return host
    }

    func tabHost(for sessionID: UUID) -> ServerProfile {
        let host = ServerProfile()
        if let session = sessions.first(where: { $0.id == sessionID }),
           session.serverID != RemoteConstants.localShellServerID {
            host.id = session.serverID
            host.name = session.title
            host.host = session.serverName
        } else {
            host.id = RemoteConstants.localShellServerID
            host.name = macName
            host.host = String(localized: "本机")
        }
        return host
    }
}

/// 新建终端抽屉里的「这台 Mac 的本机终端」：每台配对过的 Mac 一行，点一下在 Mac 上开一个新的登录 shell。
/// Mac 面板里的「窗口模式」页：进来时向 Mac 要一次窗口列表（下拉再要一次），点一行直接只看那个窗口。
struct MacWindowListPage: View {
    let client: RemoteMacClient
    let onOpen: (UInt32) -> Void

    @AppStorage(DefaultsKey.remoteDesktopFitWindow) private var fitsWindow = true
    @AppStorage(DefaultsKey.remoteDesktopWindowTextScale) private var textScale = RemoteDesktopWindowFit.defaultTextScale
    @AppStorage(DefaultsKey.remoteDesktopWindowTouchMode) private var touchMode = false
    @AppStorage(DefaultsKey.remoteDesktopWindowKeepFront) private var keepsFront = false
    @AppStorage(DefaultsKey.remoteDesktopWindowIndependentInput) private var independentInput = true
    @State private var windows: [RemoteDesktopWindowSummary] = []
    @State private var note: String?
    @State private var loading = true

    var body: some View {
        List {
            Section {
                if loading, windows.isEmpty {
                    MInsetRow(icon: "window", iconColor: M.text3, label: String(localized: "正在读取窗口…"), last: true)
                } else if windows.isEmpty {
                    MInsetRow(icon: "window", iconColor: M.text3,
                              label: note ?? String(localized: "那台 Mac 上此刻没有可以单独看的窗口。"), wraps: true, last: true)
                } else {
                    ForEach(windows, id: \.id) { window in
                        MInsetRow(icon: "window", label: window.menuTitle, sub: window.menuDetail, subMono: false,
                                  chevron: true, last: true) {
                            onOpen(window.id)
                        }
                    }
                }
            } header: {
                Text("Mac 上的窗口")
            } footer: {
                if let note, !windows.isEmpty { Text(verbatim: note) }
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(M.card)
            Section {
                Toggle("把窗口调成这里的大小", isOn: $fitsWindow)
                if fitsWindow {
                    RemoteWindowTextScalePicker(selection: $textScale)
                }
            } footer: {
                Text("Mac 上的窗口会改成适合这里的大小，里面的内容重新排版。「最清晰」时 Mac 的像素和这里的像素一一对应，画面最利、字最小；「标准」时字和在 Mac 上一样大；字越大，窗口里排得下的内容越少。看完后窗口恢复原来的大小。")
            }
            .listRowBackground(M.card)
            if client.supportsDesktopWindowFront {
                Section {
                    Toggle("看着时保持在最前", isOn: $keepsFront)
                } footer: {
                    Text("被别的窗口盖住、或者它的 App 退到后面时，Mac 不再让这个窗口重绘，动画会停在最后一帧。打开后，看着的这段时间 Mac 会一直把它提到最前；坐在 Mac 前用别的 App 的人会被打断。")
                }
                .listRowBackground(M.card)
            }
            if client.supportsDesktopWindowInput {
                Section {
                    Toggle("独立键鼠", isOn: $independentInput)
                } footer: {
                    Text("鼠标和键盘直接发给这个窗口：Mac 上的指针不动，窗口被别的窗口盖住也能操作，坐在 Mac 前的人可以同时用自己的键鼠。个别 App 不响应这样发来的操作，遇到时关掉。")
                }
                .listRowBackground(M.card)
            }
            Section {
                Toggle("触摸屏模式", isOn: $touchMode)
            } footer: {
                Text("点哪里就是哪里，不显示鼠标指针：单指拖动滚动内容，按住再拖是拖拽，双指轻点是右键。关着时像触控板一样移动指针。")
            }
            .listRowBackground(M.card)
        }
        .scrollContentBackground(.hidden)
        .background(M.canvas)
        .navigationTitle("窗口模式")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await client.desktopWindows()
            windows = list.windows
            note = list.message
        } catch {
            note = error.localizedDescription
        }
    }
}

struct MacTerminalRows: View {
    let directory: RemoteMacDirectory
    let onOpen: (RemoteMacClient, UUID) -> Void

    @Environment(\.mAccent) private var accent
    @State private var openingMac: String?
    @State private var shellError: String?
    @State private var choosingMac: String?
    @State private var workspaceChoices: RemoteLocalWorkspaces?

    var body: some View {
        ForEach(directory.pairedMacs) { mac in
            row(mac)
        }
        .onAppear {
            if directory.isActivated { directory.startBrowsing() }
        }
        // 每一行可见期间让在线状态保持新鲜（Mac 下线了能及时从抽屉里消失）。一行都没有时，
        // 抽屉打开那一刻读 `pairedMacs` 会补问一次中继。
        .task { await directory.keepLiveStatusFresh() }
        .alert("无法新建终端", isPresented: Binding(get: { shellError != nil },
                                                   set: { if !$0 { shellError = nil } })) {
            Button("好", role: .cancel) { shellError = nil }
        } message: {
            Text(shellError ?? "")
        }
    }

    private func row(_ mac: RemoteMacDirectory.Mac) -> some View {
        Button { chooseWorkspace(mac) } label: {
            HStack(spacing: 12) {
                MIcon(name: "mac", size: 18, color: accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: MRadius.md))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                    Text(openingMac == mac.id ? "正在打开…" : "Mac 本机的 shell")
                        .font(M.sans(12)).foregroundStyle(M.text3)
                }
                Spacer()
                if openingMac == mac.id {
                    ProgressView()
                } else {
                    MIcon(name: "run", size: 14, color: accent, weight: .semibold)
                }
            }
            .padding(14)
            .background(M.card)
            .clipShape(RoundedRectangle(cornerRadius: MRadius.card))
        }
        .buttonStyle(MPressStyle())
        .disabled(openingMac != nil)
        .macWorkspaceDialog(Binding(get: { choosingMac == mac.id ? workspaceChoices : nil },
                                    set: { workspaceChoices = $0 })) { directory in
            open(mac, directory: directory)
        }
    }

    /// Mac 有最近的工作区就先问开在哪，没有就直接开。要先连上 Mac 才知道，所以这段时间也显示「正在打开…」。
    private func chooseWorkspace(_ mac: RemoteMacDirectory.Mac) {
        openingMac = mac.id
        Task {
            let plan = await directory.client(for: mac).newShellPlan()
            openingMac = nil
            switch plan {
            case .ask(let workspaces):
                choosingMac = mac.id
                workspaceChoices = workspaces
            case .openDirectly:
                open(mac, directory: nil)
            }
        }
    }

    private func open(_ mac: RemoteMacDirectory.Mac, directory shellDirectory: String?) {
        let client = directory.client(for: mac)
        openingMac = mac.id
        Task {
            defer { openingMac = nil }
            do {
                onOpen(client, try await client.openLocalShell(directory: shellDirectory))
            } catch {
                shellError = error.localizedDescription
            }
        }
    }
}
