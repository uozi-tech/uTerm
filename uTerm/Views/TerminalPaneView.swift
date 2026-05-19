import SwiftUI

/// 主区终端面板。为选中的 `ServerProfile` 持有一个 `TerminalSession`，
/// 按其 `connectionState` 渲染：连接中 / 失败重试 / 终端 / 断开重连。
struct TerminalPaneView: View {
    let profile: ServerProfile

    @State private var session = TerminalSession()
    @State private var isConnecting = false

    var body: some View {
        Group {
            switch session.connectionState {
            case .idle, .connecting:
                ProgressView("正在连接 \(profile.name)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                TerminalHostView(terminalView: session.terminalView)
            case .failed(let message):
                stateView(systemImage: "exclamationmark.triangle",
                          title: "连接失败", detail: message, action: "重试")
            case .disconnected:
                stateView(systemImage: "bolt.horizontal.circle",
                          title: "连接已断开", detail: "", action: "重新连接")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: profile.id) {
            // profile 变化（选中另一台服务器）→ 重建会话并连接。
            await startConnection()
        }
        .onDisappear {
            // The `.id(profile.id)` on this view (in ContentView) makes a
            // server switch destroy this pane and ARC-release `session`.
            // Tear it down deterministically here instead of relying on
            // dealloc ordering: `dispose()` is @MainActor + synchronous, so
            // it severs the SwiftTerm `unowned(unsafe)` delegate before ARC
            // releases the session; `close()` is async, so capture the
            // session and close the SSH backend in a detached Task rather
            // than waiting for `SSHConnection.deinit`.
            let s = session
            s.dispose()
            Task { await s.close() }
        }
    }

    @ViewBuilder
    private func stateView(systemImage: String, title: String,
                           detail: String, action: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
            }
            Button(action) { Task { await startConnection() } }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func startConnection() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

        await session.close()
        session = TerminalSession()
        let keychain = KeychainStore()
        do {
            let auth = try resolveAuth(for: profile, keychain: keychain)
            var jumpAuth: ResolvedAuth?
            if let jump = profile.jumpHost {
                jumpAuth = try resolveAuth(for: jump, keychain: keychain)
            }
            let connection = SSHConnection(profile: profile, auth: auth, jumpHostAuth: jumpAuth)
            await session.connect(using: connection)
        } catch {
            session.markFailed("\(error)")
        }
    }

    private func resolveAuth(for profile: ServerProfile, keychain: KeychainStore) throws -> ResolvedAuth {
        try SSHAuthResolver.resolve(
            profile: profile,
            password: try? keychain.load(profileID: profile.id, kind: .password),
            privateKey: try? keychain.load(profileID: profile.id, kind: .privateKey),
            passphrase: try? keychain.load(profileID: profile.id, kind: .passphrase)
        )
    }
}
