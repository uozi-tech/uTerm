import Foundation
import NIOCore
import NIOSSH
import USSHKit

/// App 自己的错误类型告诉 `SSHTransportFailure` 怎么归类（这份文件也编进 `uterm-ssh`，那里没有 App 的类型）。
nonisolated protocol SSHFailureClassifying: Error {
    /// 建连失败是不是「重试也不会好」的那种（见 `SSHTransportFailure.isPermanentConnectFailure`）。
    var isPermanentConnectFailure: Bool { get }
    /// 是不是传输层断了；说不准（要看文案）时 nil。
    var transportFailureVerdict: Bool? { get }
}

/// 判定一个错误是否「SSH 传输层已断」—— 底层 TCP/通道已关闭、被重置或网络中断。
/// 供 SFTP / 终端层区分「该自动重连」与「该把错误原样报给用户」（权限、路径
/// 不存在等应用层错误绝不能触发重连，否则会丢掉用户该看到的真实信息）。
///
/// 先按 USSHCore 的类型判（`SSHChannelError` / `SSHClientError` 带着断开原因：本端关的、对端关的、
/// 传输出错、保活判死），再按 NIO `ChannelError`、NIOSSH `tcpShutdown`、POSIX errno；字符串匹配只作兜底，
/// 覆盖错误被多层 `"\(error)"` 字符串化后类型信息已丢失的路径（如 `FileBrowserModel` 的 `.failed(String)` 状态）。
///
/// 注意词序：NIO `ChannelError.ioOnClosedChannel` 的 description 是
/// "I/O on closed channel"（"closed channel"），不是 "channel closed" ——
/// v1.2.3 及以前正是因为兜底词表只写了后者，长时间待机断网后 SFTP 刷新
/// 永远走不到重连分支。
nonisolated enum SSHTransportFailure {

    /// `error` 是否传输层失败（连接已死，重试同一通道不可能成功）。
    static func isTransportFailure(_ error: Error) -> Bool {
        if let verdict = typedVerdict(error) { return verdict }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           Self.transportErrnos.contains(Int32(nsError.code)) {
            return true
        }

        let message = "\(error) \(nsError.localizedDescription)".lowercased()
        return Self.transportMessageFragments.contains { message.contains($0) }
    }

    /// 建连失败是不是「重试也不会好」的那种：服务器拒绝了凭据、主机密钥被拒绝、握手协商不成。
    /// 重连逻辑碰到它就停下，等用户处理（改凭据、确认密钥）后手动重试，不在后台一遍遍地连。
    static func isPermanentConnectFailure(_ error: Error) -> Bool {
        switch error {
        case let error as any SSHFailureClassifying:
            return error.isPermanentConnectFailure
        case let error as USSHKit.SSHConnectionError:
            switch error {
            case .authenticationFailed, .handshakeFailed, .hostKeyRejected, .unsupportedAgentAuthentication:
                return true
            default:
                return false
            }
        case let error as SSHClientError:
            switch error {
            case .authenticationFailed, .authenticationDelegateFailed, .hostKeyRejected,
                 .hostKeyValidationTimeout, .handshakeFailed:
                return true
            case .connectTimeout, .connectFailed, .handshakeTimeout, .connectionClosed:
                return false
            }
        default:
            return false
        }
    }

    /// 能从类型直接下结论时给结论；认不出的类型返回 nil，交给 errno 与字符串兜底。
    private static func typedVerdict(_ error: Error) -> Bool? {
        switch error {
        case let error as SSHChannelError:
            switch error {
            case .connectionClosed(let reason):
                return isNetworkLoss(reason)
            // 只坏了这一条通道 / 服务器拒绝了请求 / 已关的通道还在用：连接本身没事。
            case .openRejected, .channelFailed, .requestRejected, .globalRequestRejected, .channelClosed:
                return false
            // `ping` 之类等回应超时：连接可能半死，由调用方自己的时限判（探活路径另有超时）。
            case .timeout:
                return false
            }
        case let error as SSHClientError:
            switch error {
            case .connectionClosed(let reason):
                return isNetworkLoss(reason)
            case .connectTimeout, .connectFailed, .handshakeTimeout:
                return true
            case .handshakeFailed, .authenticationFailed, .authenticationDelegateFailed,
                 .hostKeyRejected, .hostKeyValidationTimeout:
                return false
            }
        case let error as SFTPError:
            // 通道没了算断；其余是服务端状态、协议违例、本端限制，原样报给用户。
            if case .connectionClosed = error { return true }
            return false
        case is SSHCommandError, is CancellationError:
            return false
        case let error as any SSHFailureClassifying:
            return error.transportFailureVerdict
        case let error as ChannelError:
            switch error {
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed,
                 .eof, .writeHostUnreachable:
                return true
            default:
                return false
            }
        case let error as NIOSSHError:
            return error.type == .tcpShutdown
        case let error as IOError:
            return Self.transportErrnos.contains(error.errnoCode)
        default:
            return nil
        }
    }

    /// 连接为什么断的 → 是不是网络问题。本端关的不算；重新交换密钥时对端换了主机密钥不算（要用户看，不能自动重连）。
    private static func isNetworkLoss(_ reason: SSHDisconnectReason) -> Bool {
        switch reason {
        case .localClose:
            return false
        case .remoteClosed, .keepAliveTimeout:
            return true
        case .transportError(let underlying):
            return !(underlying is SSHHostKeyChangedDuringRekey)
        }
    }

    /// 「连接已死」级别的 POSIX errno。
    private static let transportErrnos: Set<Int32> = [
        ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, ENOTCONN,
        ENETDOWN, ENETUNREACH, ENETRESET, EHOSTUNREACH, EHOSTDOWN, ESHUTDOWN,
    ]

    /// 字符串兜底词表（全小写 contains 匹配）。只管类型已经丢了的错误（被字符串化过的、别的库的）。
    private static let transportMessageFragments: [String] = [
        // NIO ChannelError 的真实 description 词序（"closed channel"）。
        "i/o on closed channel",
        "closed channel",
        "ioonclosedchannel",
        "alreadyclosed",
        // SFTPError.connectionClosed 字符串化（无空格）。
        "connectionclosed",
        // NIOSSH tcpShutdown 字符串化。
        "tcpshutdown",
        // 历史词表保留（其他库 / 系统消息的常见措辞）。
        "channel closed",
        "channel close",
        "connection reset",
        "connection closed",
        "connection lost",
        "broken pipe",
        "network is unreachable",
        "socket is not connected",
        "not connected",
        "transport endpoint is not connected",
    ]
}
