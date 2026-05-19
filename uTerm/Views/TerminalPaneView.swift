import SwiftUI
import SwiftData

/// 主区终端面板。为选中的 `ServerProfile` 持有一个 `TerminalSession`，
/// 按其 `connectionState` 渲染：连接中 / 失败重试 / 终端 / 断开重连。
struct TerminalPaneView: View {
    let profile: ServerProfile

    @Environment(\.modelContext) private var modelContext
    @State private var session = TerminalSession()
    @State private var isConnecting = false
    @State private var pendingChallenge: HostKeyChallenge?
    @State private var challengeDecision: CheckedContinuation<Bool, Never>?

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
        .sheet(item: $pendingChallenge) { challenge in
            HostKeyPromptView(challenge: challenge) { trusted in
                resolveChallenge(trusted)
            }
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
            // If a host-key prompt was still pending when the pane was torn
            // down, resume its continuation so the awaiting approver (and the
            // SSH handshake behind it) never leaks/hangs.
            resolveChallenge(false)
        }
    }

    /// Single resume path for the host-key `CheckedContinuation`.
    ///
    /// Both the `.sheet`'s `decide` callback and `.onDisappear` route through
    /// here. The read-and-nil of `challengeDecision` happens synchronously
    /// before `resume`, and every caller runs on the MainActor — so whichever
    /// site fires second observes `challengeDecision == nil` and no-ops. This
    /// makes a `CheckedContinuation` double-resume (a hard crash) structurally
    /// impossible.
    private func resolveChallenge(_ trusted: Bool) {
        guard let cont = challengeDecision else { return }
        challengeDecision = nil
        pendingChallenge = nil
        cont.resume(returning: trusted)
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
            let verifier = HostKeyVerifier(modelContainer: modelContext.container)
            // The approver may be invoked from a NIO event-loop thread mid-
            // handshake. It bridges NIO → MainActor by hopping into a
            // `Task { @MainActor in }` to publish the challenge into `@State`
            // (driving the `.sheet`), parks on a `CheckedContinuation` until
            // the user decides, then the sheet callback resumes it — bridging
            // MainActor → back to the NIO-context caller.
            let approver: @Sendable (HostKeyChallenge) async -> Bool = { challenge in
                await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                    Task { @MainActor in
                        // If a previous challenge is still parked in the single
                        // `challengeDecision` slot (overlapping approver call),
                        // resume it with rejection before overwriting it — an
                        // orphaned continuation would otherwise hang its NIO
                        // handshake forever.
                        if let stale = challengeDecision {
                            stale.resume(returning: false)
                        }
                        challengeDecision = cont
                        pendingChallenge = challenge
                    }
                }
            }
            let connection = SSHConnection(
                profile: SSHConnection.ProfileSnapshot(profile),
                auth: auth, jumpHostAuth: jumpAuth,
                hostKeyVerifier: verifier,
                hostKeyApprover: approver)
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
