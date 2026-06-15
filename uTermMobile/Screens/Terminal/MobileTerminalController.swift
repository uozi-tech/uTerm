import SwiftUI
import SwiftData
import SwiftTerm
import Observation

/// 一个 iOS 终端会话的运行时控制器：持有 `SSHConnection`（复用 macOS 端
/// `TerminalBackend` 实现），把入站字节喂给 SwiftTerm 的 `TerminalView`，并把
/// 键盘输入 / 尺寸变化回送后端。`@MainActor` —— 直接安全触碰 SwiftData 模型与 UI。
@MainActor
@Observable
final class MobileTerminalController {
    enum State: Equatable {
        case idle, connecting, connected, failed(String), closed
    }

    var state: State = .idle
    var title: String = ""

    @ObservationIgnored private(set) weak var terminalView: SwiftTerm.TerminalView?
    @ObservationIgnored private var connection: SSHConnection?
    @ObservationIgnored private var outputTask: Task<Void, Never>?
    @ObservationIgnored private var exitTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    func attach(_ view: SwiftTerm.TerminalView) {
        terminalView = view
    }

    /// 关闭会话前先收起键盘——否则视图随转场移除后键盘还会残留几百毫秒。
    func resignKeyboard() {
        _ = terminalView?.resignFirstResponder()
    }

    /// 切到该会话标签时让其终端重新成为第一响应者（弹回键盘）。
    func focusKeyboard() {
        _ = terminalView?.becomeFirstResponder()
    }

    /// 用一台主机建连并开 PTY。重复调用无副作用（已建连过则忽略）。
    /// `relay` 把首次连接 / 密钥变化的 host-key 挑战交给用户裁决（替代盲信 TOFU）。
    func start(profile: ServerProfile, container: ModelContainer, relay: HostKeyChallengeRelay) {
        guard !started else { return }
        started = true
        title = profile.name
        state = .connecting

        let snapshot = SSHConnection.ProfileSnapshot(profile)
        let keychain = KeychainStore()
        let auth: ResolvedAuth
        do {
            auth = try SSHAuthResolver.resolve(profile: profile, keychain: keychain)
        } catch {
            state = .failed("认证材料解析失败：\(error.localizedDescription)")
            return
        }
        var jumpAuth: ResolvedAuth?
        if let jump = profile.jumpHost {
            jumpAuth = try? SSHAuthResolver.resolve(profile: jump, keychain: keychain)
        }
        let verifier = HostKeyVerifier(modelContainer: container)
        // 首次连接 / 密钥变化时弹出信任确认；信任后由 verifier 写入 known-hosts。
        let conn = SSHConnection(profile: snapshot, auth: auth, jumpHostAuth: jumpAuth,
                                 hostKeyVerifier: verifier, hostKeyApprover: relay.makeApprover())
        connection = conn

        let outStream = conn.outputStream
        let exitStream = conn.exitStream
        let pid = profile.persistentModelID

        outputTask = Task { [weak self] in
            for await chunk in outStream {
                await MainActor.run { self?.terminalView?.feed(byteArray: ArraySlice(chunk)) }
            }
        }
        exitTask = Task { [weak self] in
            for await _ in exitStream {
                await MainActor.run {
                    if case .failed = self?.state { } else { self?.state = .closed }
                }
                break
            }
        }

        Task { [weak self] in
            do {
                try await conn.connect()
                await MainActor.run {
                    self?.state = .connected
                    if let profile = container.mainContext.model(for: pid) as? ServerProfile {
                        profile.lastConnectedAt = Date()
                        try? container.mainContext.save()
                    }
                }
            } catch {
                await MainActor.run { self?.state = .failed(error.localizedDescription) }
            }
        }
    }

    func write(_ data: Data) {
        guard let connection else { return }
        Task { await connection.write(data) }
    }

    func sendText(_ text: String) {
        write(Data(text.utf8))
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard let connection else { return }
        Task { await connection.resize(cols: cols, rows: rows) }
    }

    func close() {
        outputTask?.cancel(); exitTask?.cancel()
        let conn = connection
        Task { await conn?.close() }
        connection = nil
        state = .closed
    }

    deinit {
        outputTask?.cancel(); exitTask?.cancel()
    }
}
