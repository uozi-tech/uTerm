import SwiftUI

/// 主机页的「我的 Mac」：配对过的 Mac，在线的点进 `RemoteMacSheet`；下面「附近的 Mac」列局域网里还没配对的，
/// 点了同样进 `RemoteMacSheet`，先在 Mac 上核对 6 位码并点「允许」。不在同一局域网的 Mac 扫它的二维码配对。
struct RemoteMacSection: View {
    /// 可选：样式画廊、探针等直接渲染主机页的地方不注入它，那时整块不显示。
    @Environment(RemoteMacDirectory.self) private var injected: RemoteMacDirectory?
    @Environment(MobileStore.self) private var store: MobileStore?
    @State private var selected: RemoteMacDirectory.Mac?
    @State private var scanning = false
    @State private var diagnosing: RemoteMacDirectory.Mac?
    @Environment(\.mAccent) private var accent

    var body: some View {
        if let directory = injected {
            group(directory)
        }
    }

    private func group(_ directory: RemoteMacDirectory) -> some View {
        VStack(spacing: 12) {
            MInsetGroup(header: "我的 Mac", headerTrailing: AnyView(scanButton)) {
                if !directory.isActivated {
                    MInsetRow(icon: "mac", label: "控制我的 Mac 上的终端", chevron: true, last: true) {
                        directory.activate()
                    }
                } else if directory.macs.isEmpty {
                    MInsetRow(icon: "mac", label: "还没有配对的 Mac",
                              sub: directory.nearbyMacs.isEmpty ? "在 Mac 上打开「远程控制」，或扫 Mac 上的二维码" : "在下面选一台开始配对",
                              last: true)
                } else {
                    ForEach(directory.macs) { mac in
                        macRow(mac, last: mac.id == directory.macs.last?.id)
                    }
                }
            }
            if directory.isActivated, !directory.nearbyMacs.isEmpty {
                MInsetGroup(header: "附近的 Mac",
                            footer: "同一局域网里打开了远程控制、还没和这台手机配对的 Mac。点一下，在 Mac 上核对数字并点「允许」即可配对。") {
                    ForEach(directory.nearbyMacs) { mac in
                        MInsetRow(icon: "mac", label: mac.name, value: "配对", chevron: true,
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
        .sheet(isPresented: $scanning) {
            RemotePairingScanner(onScanned: { invitation in
                scanning = false
                guard let mac = try? directory.pair(with: invitation) else { return }
                directory.pendingOpenMacID = mac.id
                openPendingIfOnline(directory)
            }, onRelayConfig: { config in
                scanning = false
                directory.importRelayConfig(config)
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

    /// 不在同一局域网的 Mac：扫它「设置 › 远程控制」里的二维码配对。
    private var scanButton: some View {
        Button { scanning = true } label: {
            Label("扫码配对", systemImage: "qrcode.viewfinder")
                .font(M.sans(13, weight: .medium))
                .foregroundStyle(accent)
        }
        .buttonStyle(.borderless)
    }

    private func rowValue(_ mac: RemoteMacDirectory.Mac) -> String? {
        if !mac.isOnline { return "不在线" }
        return mac.endpoint == nil ? "公网" : nil
    }

    private func macRow(_ mac: RemoteMacDirectory.Mac, last: Bool) -> some View {
        MInsetRow(icon: "mac", iconColor: mac.isOnline ? nil : M.text3, label: mac.name,
                  value: rowValue(mac), chevron: mac.isOnline, last: last,
                  onTap: mac.isOnline ? { selected = mac } : nil)
            .mContextMenu {
                if mac.isOnRelay {
                    Button { diagnosing = mac } label: { Label("网络诊断", systemImage: "stethoscope") }
                }
            }
    }
}

/// 一台 Mac：首次连接走配对（两端核对 6 位码，在 Mac 上点「允许」），之后列出 Mac 上的终端。
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

    var body: some View {
        NavigationStack {
            content
            .background(M.canvas)
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

    @ViewBuilder private var content: some View {
        switch client.state {
        case .idle, .connecting:
            scrolling {
                statusRow(icon: "refresh", text: "正在连接 \(client.macName)…",
                          detail: client.connectStage?.progress)
            }
        case .awaitingApproval(let code):
            scrolling { pairing(code) }
        case .failed(let message) where client.isAutoRetrying:
            scrolling { statusRow(icon: "refresh", text: "连接失败，正在重试…", detail: message) }
        case .failed(let message):
            scrolling {
                MInsetGroup(footer: client.failureContext) {
                    MInsetRow(icon: "warn", iconColor: M.danger, label: "连接失败", sub: message, last: false)
                    MInsetRow(icon: "refresh", label: "重试", chevron: true, last: true) {
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
            Text("在 Mac 上确认配对").font(M.sans(18, weight: .bold)).foregroundStyle(M.text)
            Text("\(code.prefix(3)) \(code.suffix(3))")
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(M.text)
            Text("Mac 上会弹出同样的 6 位数字。一致再点「允许」；不一致说明连接可能被截获，点「拒绝」。")
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
            section("这台 Mac",
                    footer: client.supportsLocalShell
                        ? "在 Mac 上打开你的登录 shell，并在 Mac 上弹出对应的终端窗口；断开后终端仍留在 Mac 上，可以接着用。"
                        : "Mac 上的 uTerm 版本过旧，无法新建终端。将其更新到最新版本后即可使用。") {
                if client.supportsLocalShell {
                    MInsetRow(icon: "term", label: openingShell ? "正在打开…" : "新建终端",
                              sub: "Mac 本机的 shell", chevron: !openingShell, last: true) {
                        guard !openingShell else { return }
                        Task { await chooseWorkspace() }
                    }
                    .macWorkspaceDialog($workspaceChoices) { directory in
                        Task { await openLocalShell(directory: directory) }
                    }
                } else {
                    MInsetRow(icon: "term", iconColor: M.text3, label: "新建终端", sub: "需要更新 Mac 上的 uTerm", last: true)
                }
            }
            section("屏幕", footer: client.supportsDesktop ? nil : "Mac 上的 uTerm 版本过旧，不支持远程桌面。将其更新到最新版本后即可使用。") {
                if client.supportsDesktop {
                    MInsetRow(icon: "display", label: "查看并控制屏幕", sub: "像触控板一样操作 Mac 的鼠标与键盘",
                              chevron: true, last: true) {
                        openDesktop()
                    }
                } else {
                    MInsetRow(icon: "display", iconColor: M.text3, label: "查看并控制屏幕", sub: "需要更新 Mac 上的 uTerm", last: true)
                }
            }
            section("Mac 上的终端",
                    footer: "点任意一个都会接管这台 Mac 上的全部终端，各开一个标签页，之后 Mac 上新开或关闭终端，手机上的标签页也跟着变，直到点「断开全部终端」。接管期间它们按这台手机的尺寸运行，Mac 上的窗格会标出「正在接管」，断开后恢复。") {
                if client.sessions.isEmpty {
                    MInsetRow(icon: "term", label: "Mac 上没有已连接的终端", sub: "在 Mac 上打开一个终端后会出现在这里", last: true)
                } else {
                    ForEach(client.sessions) { session in
                        // 分隔线交给 List（`last: true` 关掉行自带的），滑动时才会跟着行走。
                        MInsetRow(icon: "term", label: session.displayTitle, sub: subtitle(session),
                                  chevron: true, last: true) {
                            takeOver(focus: session.id)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) { closeAction(session) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { closeAction(session) }
                    }
                }
                if workspace.followedClients.contains(where: { $0 === client }) {
                    let taken = workspace.remoteTabIDs(of: client)
                    MInsetRow(icon: "x", label: "断开全部终端",
                              sub: taken.isEmpty ? "不再自动接入这台 Mac 新开的终端"
                                  : "关闭手机上的 \(taken.count) 个标签页，Mac 上的终端继续运行",
                              last: true) {
                        endTakeover()
                    }
                }
            }
            section(nil, footer: nil) {
                MInsetRow(icon: "x", label: "忘记这台 Mac", danger: true, last: true) {
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
        if let controller = session.controlledBy { parts.append("\(controller) 正在接管") }
        return parts.joined(separator: " · ")
    }

    private func openDesktop() {
        dismiss()
        let client = self.client
        // 同终端：等面板收起再盖全屏，避免两个转场叠在一起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.remoteDesktop = MRemoteDesktopRequest(client: client)
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
        let workspaces = await client.localWorkspaces()
        openingShell = false
        if let workspaces, !workspaces.directories.isEmpty {
            workspaceChoices = workspaces
        } else {
            await openLocalShell(directory: nil)
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
            host.host = "本机"
        }
        return host
    }
}

extension View {
    /// 在 Mac 上新开终端前问开在哪。要挂在触发它的行上：宽屏下它是 popover，箭头指向所挂的视图。
    func macWorkspaceDialog(_ choices: Binding<RemoteLocalWorkspaces?>,
                            onPick: @escaping (_ directory: String?) -> Void) -> some View {
        confirmationDialog("在哪个目录打开？",
                           isPresented: Binding(get: { choices.wrappedValue != nil },
                                                set: { if !$0 { choices.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: choices.wrappedValue) { workspaces in
            Button("主目录") { onPick(nil) }
            ForEach(workspaces.directories, id: \.self) { directory in
                Button(RemoteLocalWorkspaces.displayPath(directory, home: workspaces.home)) { onPick(directory) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 新建终端抽屉里的「这台 Mac 的本机终端」：每台配对过的 Mac 一行，点一下在 Mac 上开一个新的登录 shell。
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
            let workspaces = await directory.client(for: mac).localWorkspaces()
            openingMac = nil
            if let workspaces, !workspaces.directories.isEmpty {
                choosingMac = mac.id
                workspaceChoices = workspaces
            } else {
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
