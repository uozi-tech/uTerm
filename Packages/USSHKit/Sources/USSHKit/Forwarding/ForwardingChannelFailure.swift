import Foundation
import NIOSSH

/// direct-tcpip 开通道失败的归类结果，供上层把「NIOSSH.NIOSSHError错误1」这类
/// 原始错误翻译成用户能看懂的话（转发被拒 / 目标不可达 / 超时）。
///
/// 归类依据：
/// - `ForwardingTimeoutError` → `.timeout`（我们自己的开通道超时保护先到 ——
///   对端 CHANNEL_OPEN 全程无响应，典型为白名单/安全组把包丢在半路）；
/// - `NIOSSHError.channelSetupRejected` → 按 RFC 4254 的 reason code 细分：
///   1 = SSH_OPEN_ADMINISTRATIVELY_PROHIBITED（sshd 拒绝转发，常见
///   `AllowTcpForwarding no`），2 = SSH_OPEN_CONNECT_FAILED（跳板机自己连
///   目标失败：拒绝/不可达/解析失败）。reason code 只存在于 NIOSSHError 的
///   诊断文本（`"Reason: <code> <desc>"`）里，没有公开访问器，故从
///   `String(describing:)` 解析 —— 解析不动时退化为 `.other`，不影响正确性。
public nonisolated struct SSHForwardingChannelFailure: Sendable {
    public enum Kind: Sendable, Equatable {
        /// 开通道请求发出后对端始终无响应（本地超时保护触发）。
        case timeout
        /// 对端 sshd 明确拒绝（administratively prohibited）。
        case administrativelyProhibited
        /// 跳板机尝试连接目标失败（connect failed：拒绝/不可达/解析失败）。
        case connectFailed
        /// 其他（含解析不出 reason code 的拒绝）。
        case other
    }

    public let kind: Kind
    /// 原始错误文本，供日志与排查。
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public init(classifying error: Error) {
        if error is ForwardingTimeoutError {
            self.init(kind: .timeout, detail: (error as? LocalizedError)?.errorDescription ?? "\(error)")
            return
        }
        if let sshError = error as? NIOSSHError, sshError.type == .channelSetupRejected {
            let description = String(describing: sshError)
            self.init(kind: Self.rejectionKind(fromDiagnostics: description), detail: description)
            return
        }
        self.init(kind: .other, detail: String(describing: error))
    }

    /// 从 NIOSSHError 的诊断文本（`"… Reason: <code> <desc>"`）解析 RFC 4254
    /// reason code。解析失败返回 `.other`。
    static func rejectionKind(fromDiagnostics description: String) -> Kind {
        guard let range = description.range(of: "Reason: ") else { return .other }
        let code = description[range.upperBound...].prefix(while: \.isNumber)
        switch code {
        case "1": return .administrativelyProhibited
        case "2": return .connectFailed
        default: return .other
        }
    }

    /// 面向用户的失败原因（中文，与 USSHKit 既有错误文案一致）。
    public func userMessage(targetHost: String, targetPort: Int) -> String {
        let target = "\(targetHost):\(targetPort)"
        switch kind {
        case .timeout:
            return "跳板机连不上目标 \(target)：开通道超时（多为目标的白名单/安全组未放行跳板机）"
        case .administrativelyProhibited:
            return "跳板机拒绝端口转发（sshd 可能配置了 AllowTcpForwarding no）"
        case .connectFailed:
            return "跳板机无法连接目标 \(target)（连接被拒绝或地址不可达）"
        case .other:
            return "转发到 \(target) 的通道打开失败：\(detail)"
        }
    }
}
