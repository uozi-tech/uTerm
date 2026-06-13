import Foundation
import Citadel
import NIOCore
import NIOSSH

/// 判定一个错误是否「SSH 传输层已断」—— 底层 TCP/通道已关闭、被重置或网络中断。
/// 供 SFTP / 终端层区分「该自动重连」与「该把错误原样报给用户」（权限、路径
/// 不存在等应用层错误绝不能触发重连，否则会丢掉用户该看到的真实信息）。
///
/// 优先按错误类型精确匹配（NIO `ChannelError`、NIOSSH `tcpShutdown`、Citadel
/// `SFTPError.connectionClosed`、POSIX errno）；字符串匹配只作兜底，覆盖错误被
/// 多层 `"\(error)"` 字符串化后类型信息已丢失的路径（如 `FileBrowserModel` 的
/// `.failed(String)` 状态）。
///
/// 注意词序：NIO `ChannelError.ioOnClosedChannel` 的 description 是
/// "I/O on closed channel"（"closed channel"），不是 "channel closed" ——
/// v1.2.3 及以前正是因为兜底词表只写了后者，长时间待机断网后 SFTP 刷新
/// 永远走不到重连分支。
nonisolated enum SSHTransportFailure {

    /// `error` 是否传输层失败（连接已死，重试同一通道不可能成功）。
    static func isTransportFailure(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .outputClosed, .inputClosed,
                 .eof, .writeHostUnreachable:
                return true
            default:
                return false
            }
        }
        if let sshError = error as? NIOSSHError {
            return sshError.type == .tcpShutdown
        }
        if let sftpError = error as? SFTPError {
            if case .connectionClosed = sftpError { return true }
            return false
        }
        if let ioError = error as? IOError {
            return Self.transportErrnos.contains(ioError.errnoCode)
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           Self.transportErrnos.contains(Int32(nsError.code)) {
            return true
        }

        let message = "\(error) \(nsError.localizedDescription)".lowercased()
        return Self.transportMessageFragments.contains { message.contains($0) }
    }

    /// 「连接已死」级别的 POSIX errno。
    private static let transportErrnos: Set<Int32> = [
        ECONNRESET, ECONNABORTED, EPIPE, ETIMEDOUT, ENOTCONN,
        ENETDOWN, ENETUNREACH, ENETRESET, EHOSTUNREACH, EHOSTDOWN, ESHUTDOWN,
    ]

    /// 字符串兜底词表（全小写 contains 匹配）。
    private static let transportMessageFragments: [String] = [
        // NIO ChannelError 的真实 description 词序（"closed channel"）。
        "i/o on closed channel",
        "closed channel",
        "ioonclosedchannel",
        "alreadyclosed",
        // Citadel SFTPError.connectionClosed 直接字符串化（无空格）。
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
