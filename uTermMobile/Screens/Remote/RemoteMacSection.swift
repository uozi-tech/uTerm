import SwiftData
import SwiftUI

/// 主机页的「我的 Mac」：同一局域网里开着远控的 Mac。点一台进入 `RemoteMacSheet`。
struct RemoteMacSection: View {
    /// 可选：样式画廊、探针等直接渲染主机页的地方不注入它，那时整块不显示。
    @Environment(RemoteMacDirectory.self) private var injected: RemoteMacDirectory?
    @Environment(MobileStore.self) private var store: MobileStore?
    @State private var selected: RemoteMacDirectory.Mac?

    var body: some View {
        if let directory = injected {
            group(directory)
        }
    }

    private func group(_ directory: RemoteMacDirectory) -> some View {
        MInsetGroup(header: "我的 Mac", footer: footer(directory)) {
            if !directory.isActivated {
                MInsetRow(icon: "mac", label: "控制我的 Mac 上的终端",
                          sub: "同一 Wi-Fi 下使用", chevron: true, last: true) {
                    directory.activate()
                }
            } else if directory.macs.isEmpty {
                MInsetRow(icon: "mac", label: "正在查找 Mac…",
                          sub: "在 Mac 的 uTerm 里打开 设置 › 高级 › 远程控制", last: true)
            } else {
                ForEach(directory.macs) { mac in
                    MInsetRow(icon: "mac", label: mac.name,
                              value: directory.isPaired(mac) ? "已配对" : "未配对",
                              chevron: true, last: mac.id == directory.macs.last?.id) {
                        selected = mac
                    }
                }
            }
        }
        .onAppear {
            if directory.isActivated { directory.startBrowsing() }
            #if DEBUG
            // 调试：启动参数 `-RemoteDebugOpenDesktop YES`（配合 `-RemoteDebugEndpoint`）直接打开第一台 Mac 的屏幕，
            // 模拟器联调远程桌面时不用手点。
            if UserDefaults.standard.bool(forKey: "RemoteDebugOpenDesktop"), let mac = directory.macs.first,
               let store, store.remoteDesktop == nil {
                store.remoteDesktop = MRemoteDesktopRequest(client: directory.client(for: mac))
            }
            #endif
        }
        .sheet(item: $selected, onDismiss: { directory.refreshPaired() }) { mac in
            RemoteMacSheet(client: directory.client(for: mac))
        }
    }

    private func footer(_ directory: RemoteMacDirectory) -> String? {
        directory.isActivated ? nil : "首次使用会请求「本地网络」权限，用于发现局域网里的 Mac。"
    }
}

/// 一台 Mac：首次连接走配对（两端核对 6 位码，在 Mac 上点「允许」），之后列出 Mac 上的终端。
struct RemoteMacSheet: View {
    let client: RemoteMacClient
    @Environment(MobileStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\ServerProfile.sortOrder)]) private var hosts: [ServerProfile]
    @State private var missingHost: RemoteSessionInfo?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.vertical, 16)
            }
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
        .task { await client.connect() }
        .alert("这台主机还没同步到本机", isPresented: Binding(get: { missingHost != nil },
                                                        set: { if !$0 { missingHost = nil } })) {
            Button("好", role: .cancel) { missingHost = nil }
        } message: {
            Text("「\(missingHost?.serverName ?? "")」在 Mac 上有，但这部手机上还没有。等 iCloud 或局域网同步完成后再试。")
        }
    }

    @ViewBuilder private var content: some View {
        switch client.state {
        case .idle, .connecting:
            statusRow(icon: "refresh", text: "正在连接 \(client.macName)…")
        case .awaitingApproval(let code):
            pairing(code)
        case .failed(let message):
            MInsetGroup {
                MInsetRow(icon: "warn", iconColor: M.danger, label: "连接失败", sub: message, last: false)
                MInsetRow(icon: "refresh", label: "重试", chevron: true, last: true) {
                    Task { await client.connect() }
                }
            }
        case .connected:
            sessions
        }
    }

    private func statusRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(text).font(M.sans(14)).foregroundStyle(M.text2)
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
            Text("Mac 上会弹出同样的 6 位数字。一致再点「允许」；不一致说明连接被人截获，请拒绝。")
                .font(M.sans(13)).foregroundStyle(M.text3)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            ProgressView().padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    @ViewBuilder private var sessions: some View {
        MInsetGroup(header: "屏幕", footer: client.supportsDesktop ? nil : "Mac 上的 uTerm 版本太旧，不支持远程桌面。请先把 Mac 上的 uTerm 更新到最新版。") {
            if client.supportsDesktop {
                MInsetRow(icon: "display", label: "查看并控制屏幕", sub: "像触控板一样操作 Mac 的鼠标与键盘",
                          chevron: true, last: true) {
                    openDesktop()
                }
            } else {
                MInsetRow(icon: "display", iconColor: M.text3, label: "查看并控制屏幕", sub: "请更新 Mac 上的 uTerm", last: true)
            }
        }
        MInsetGroup(header: "Mac 上的终端",
                    footer: "接入后终端按这部手机的尺寸运行，Mac 上那个窗格会标出「正在接管」，断开后恢复。") {
            if client.sessions.isEmpty {
                MInsetRow(icon: "term", label: "Mac 上没有已连接的终端", sub: "在 Mac 上打开一个终端后会出现在这里", last: true)
            } else {
                ForEach(client.sessions) { session in
                    MInsetRow(icon: "term", label: session.title, sub: subtitle(session),
                              chevron: true, last: session.id == client.sessions.last?.id) {
                        open(session)
                    }
                }
            }
        }
        MInsetGroup {
            MInsetRow(icon: "x", label: "忘记这台 Mac", danger: true, last: true) {
                client.forget()
                dismiss()
            }
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

    private func open(_ session: RemoteSessionInfo) {
        guard let host = hosts.first(where: { $0.id == session.serverID }) else {
            missingHost = session
            return
        }
        dismiss()
        let source = MRemoteSource(client: client, sessionID: session.id)
        // 等面板收起再开，避免连接中页与收起动画叠在一起。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            store.openRemoteTerminal(host, source: source)
        }
    }
}
