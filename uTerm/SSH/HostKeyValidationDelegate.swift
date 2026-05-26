import Foundation
import Crypto
import NIOCore
import NIOSSH

// MARK: - 确认的 NIOSSH / Citadel host-key API（来自 checkout 源码核对）
//
// 1) NIOSSHClientServerAuthenticationDelegate 协议方法：
//      func validateHostKey(hostKey: NIOSSHPublicKey,
//                           validationCompletePromise: EventLoopPromise<Void>)
//    接受 = `promise.succeed(())`；拒绝 = `promise.fail(error)`。
//    （另有带默认实现的 `validateHostCertificate(...)`，默认转调 `validateHostKey`，
//     本类无需覆盖。）
//
// 2) NIOSSHPublicKey 序列化：`public func write(to buffer: inout ByteBuffer) -> Int`
//    （内部 `buffer.writeSSHHostKey(_:)`）写出 SSH wire-format 公钥 blob ——
//    形如 `string(key-type) || key-material`，与 OpenSSH known_hosts 第三字段
//    base64 解码后的字节一致。key-type / 算法名经 `String(openSSHPublicKey:)`
//    取得："algorithm-id base64-key"，首段即算法名（如 `ssh-ed25519`）。
//
// 3) Citadel `SSHHostKeyValidator` 是 `struct ... : NIOSSHClientServerAuthenticationDelegate, Sendable`，
//    `static func custom(_ validator: NIOSSHClientServerAuthenticationDelegate) -> SSHHostKeyValidator`
//    接受任意遵从该协议的值。因 `SSHHostKeyValidator` 是 `Sendable` 且把
//    delegate 存进其内部 `Method` 枚举，传入的 delegate 也必须是 `Sendable` ——
//    本类因此声明为 `Sendable`（捕获项 host/port/verifier/approver 均 `Sendable`）。
//
// 4) EventLoopPromise 跨线程完成：NIOSSH 的 promise `succeed/fail` 是线程安全的，
//    可从 delegate 内部启动的 `Task` 直接完成，无需 hop 回 event loop。

/// 主机密钥验证过程中产生的错误。
enum HostKeyError: Error, LocalizedError {
    /// 用户在征询中拒绝了未知 / 不匹配的主机密钥（.ask 策略下用户取消 sheet）。
    case rejectedByUser
    /// `.strict` 策略下未知 / 不匹配的主机密钥被自动拒绝（无 sheet）。
    case rejectedByStrictPolicy

    var errorDescription: String? {
        switch self {
        case .rejectedByUser:
            return "主机密钥验证被用户拒绝"
        case .rejectedByStrictPolicy:
            return "主机密钥验证失败：严格策略拒绝未知 / 不匹配的密钥"
        }
    }
}

/// 把 `NIOSSHPublicKey` 序列化为 `(blob, keyType, fingerprint)`。
///
/// - `blob`：SSH wire-format 公钥字节（`NIOSSHPublicKey.write(to:)` 的输出），
///   与 `KnownHost.keyBlob` 存储格式一致。
/// - `keyType`：算法名（如 `ssh-ed25519`、`ecdsa-sha2-nistp256`）。
/// - `fingerprint`：`"SHA256:" + base64(SHA256(blob))`，去掉 `=` 填充 ——
///   与 OpenSSH `ssh-keygen -lf` 显示的指纹格式一致。
enum HostKeySerialization {
    nonisolated static func serialize(_ key: NIOSSHPublicKey) -> (blob: Data, keyType: String, fingerprint: String) {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let blob = Data(buffer.readableBytesView)

        // `String(openSSHPublicKey:)` -> "algorithm-id base64-key"，取首段为算法名。
        let openSSH = String(openSSHPublicKey: key)
        let keyType = openSSH.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""

        let digest = SHA256.hash(data: blob)
        let base64 = Data(digest).base64EncodedString()
        let fingerprint = "SHA256:" + base64.replacingOccurrences(of: "=", with: "")

        return (blob: blob, keyType: keyType, fingerprint: fingerprint)
    }
}

/// 针对单个 `host:port` 的主机密钥验证 delegate（遵从 `NIOSSHClientServerAuthenticationDelegate`）。
///
/// 实现 TOFU（trust on first use）：
/// - `.trusted` —— 已记录且密钥一致 → 直接接受。
/// - `.unknown` —— 首次见到该主机 → 征询用户；同意则写入 known-hosts 并接受，
///   拒绝则以 `HostKeyError.rejectedByUser` 失败 promise。
/// - `.mismatch` —— 密钥与已记录的不同（可能是中间人，也可能是服务器重装）→
///   征询用户；同意则覆盖记录并接受，拒绝则失败 promise。
///
/// 验证逻辑（`classify` / `trust` / `approver`）都是 `async`，而协议方法是同步的；
/// 因此在 `validateHostKey` 内启动一个 `Task` 执行异步工作，并从该 `Task` 完成
/// `EventLoopPromise` —— NIOSSH 的 promise 完成是线程安全的，可跨线程调用。
///
/// 本类为 `final class` 且声明 `Sendable`：所有存储属性（host/port/verifier/approver）
/// 均不可变且 `Sendable`，无可变状态，故 `Sendable` 成立无需 `@unchecked`。
///
/// 标 `nonisolated`：项目以 `-default-isolation=MainActor` + `InferIsolatedConformances`
/// 编译，默认会把本类及其协议遵从推断为 `@MainActor` 隔离。但 Citadel 在 NIO
/// event-loop（非主 actor）线程上调用 `validateHostKey`，且 `SSHConnection`
/// actor 在自身隔离域内构造本类 —— 因此本类与其 `NIOSSHClientServerAuthenticationDelegate`
/// 遵从必须是 `nonisolated`。
nonisolated final class HostKeyValidationDelegate: NIOSSHClientServerAuthenticationDelegate, Sendable {

    private let host: String
    private let port: Int
    private let verifier: HostKeyVerifier
    private let approver: @Sendable (HostKeyChallenge) async -> Bool

    /// - Parameters:
    ///   - host: 目标主机名 —— known-hosts 记录与征询的 key。
    ///   - port: 目标端口 —— 与 host 一起构成 known-hosts 记录的 key。
    ///   - verifier: known-hosts 存储 / TOFU 决策的 actor。
    ///   - approver: 征询用户的注入闭包。返回 `true` 表示信任，`false` 表示拒绝。
    init(host: String,
         port: Int,
         verifier: HostKeyVerifier,
         approver: @escaping @Sendable (HostKeyChallenge) async -> Bool) {
        self.host = host
        self.port = port
        self.verifier = verifier
        self.approver = approver
    }

    /// Time budget for a user to decide on a host-key challenge. Generous
    /// enough for a real person to read and act; a backstop, not a UX timer.
    private static let approvalTimeout: Duration = .seconds(180)

    /// 读 UserDefaults `sshHostKeyPolicy`，默认 `.ask`。
    /// 在每次 validateHostKey 内 read 一次——setting 改后下次连接才生效。
    private static func currentPolicy() -> SSHHostKeyPolicy {
        let raw = UserDefaults.standard.string(forKey: "sshHostKeyPolicy")
            ?? SSHHostKeyPolicy.ask.rawValue
        return SSHHostKeyPolicy(rawValue: raw) ?? .ask
    }

    /// Runs the injected `approver` with a hard upper bound.
    ///
    /// If the pane presenting the prompt is torn down between the approver
    /// capturing its `CheckedContinuation` and the MainActor `Task` parking it
    /// in the view's state (or the sheet otherwise never appears), nothing ever
    /// resumes the continuation and the awaiting handshake hangs forever. This
    /// races the approver against a sleep: whichever finishes first wins; a
    /// timeout (sentinel `nil`) is treated as rejection.
    private func approveWithTimeout(_ challenge: HostKeyChallenge) async -> Bool {
        let approver = self.approver
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await approver(challenge) }
            group.addTask {
                try? await Task.sleep(for: Self.approvalTimeout)
                return nil   // timeout sentinel
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? false   // nil (timeout) → reject
        }
    }

    func validateHostKey(hostKey: NIOSSHPublicKey,
                         validationCompletePromise: EventLoopPromise<Void>) {
        let (blob, keyType, fingerprint) = HostKeySerialization.serialize(hostKey)
        let host = self.host
        let port = self.port
        let verifier = self.verifier

        Task {
            // The async decision is computed inside a `do`, and the promise is
            // completed in a `defer` keyed on a sentinel `Result?`. This makes
            // promise completion unskippable: if any future `await` (e.g. the
            // real approver) becomes a cancellation point and the `Task` exits
            // early, `decision` is still `nil` and `defer` fails the promise —
            // the SSH handshake can never hang on an uncompleted promise.
            var decision: Result<Void, Error>? = nil
            defer {
                switch decision {
                case .success:
                    validationCompletePromise.succeed(())
                case .failure(let error):
                    validationCompletePromise.fail(error)
                case nil:
                    // Early exit (cancellation / unexpected throw) — never leave
                    // the promise uncompleted; fail it so the handshake aborts.
                    validationCompletePromise.fail(
                        CancellationError() as Error)
                }
            }

            let classification = await verifier.classify(
                host: host, port: port, keyBlob: blob, fingerprint: fingerprint)

            switch classification {
            case .trusted:
                decision = .success(())

            case .unknown(let fp):
                switch Self.currentPolicy() {
                case .strict:
                    decision = .failure(HostKeyError.rejectedByStrictPolicy)
                case .none:
                    // 静默信任（不安全，UI 已警示）
                    await verifier.trust(host: host, port: port, keyBlob: blob,
                                         keyType: keyType, fingerprint: fp)
                    decision = .success(())
                case .ask:
                    let challenge = HostKeyChallenge(
                        host: host, port: port, kind: .unknown,
                        newFingerprint: fp, oldFingerprint: nil)
                    if await self.approveWithTimeout(challenge) {
                        await verifier.trust(host: host, port: port, keyBlob: blob,
                                             keyType: keyType, fingerprint: fp)
                        decision = .success(())
                    } else {
                        decision = .failure(HostKeyError.rejectedByUser)
                    }
                }

            case .mismatch(let newFp, let oldFp):
                switch Self.currentPolicy() {
                case .strict:
                    decision = .failure(HostKeyError.rejectedByStrictPolicy)
                case .none:
                    // 静默信任 + 覆盖（不安全，UI 已警示）
                    await verifier.trust(host: host, port: port, keyBlob: blob,
                                         keyType: keyType, fingerprint: newFp)
                    decision = .success(())
                case .ask:
                    let challenge = HostKeyChallenge(
                        host: host, port: port, kind: .mismatch,
                        newFingerprint: newFp, oldFingerprint: oldFp)
                    if await self.approveWithTimeout(challenge) {
                        await verifier.trust(host: host, port: port, keyBlob: blob,
                                             keyType: keyType, fingerprint: newFp)
                        decision = .success(())
                    } else {
                        decision = .failure(HostKeyError.rejectedByUser)
                    }
                }
            }
        }
    }
}
