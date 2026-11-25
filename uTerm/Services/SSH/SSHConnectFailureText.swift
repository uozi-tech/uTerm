import Darwin
import Foundation
import USSHKit

/// 连不上的时候说清楚是哪一种：拒绝连接、主机不可达、超时、在 SSH 握手前就被断开……
///
/// USSHKit 把底层的建连错误收成 `.connectFailed(String)`，正文是底层错误的原话（NIO 的
/// `connect(descriptor:addr:size:): Connection refused (errno: 61)` 之类）。原话说不清楚，「被对方重置」
/// 更像是「连接断了」——用户对一台已经关掉的服务器点重试，看到的却像是连上又断了（实机：开着代理 TUN 时，
/// 连不上的地址也是先被代理接下、随即断开）。这里按两样不随语言变化的东西归类：NIO 错误里带的 errno 编号，
/// 以及 USSHKit 自己给「握手前对方关闭」的那一句（`SSHDisconnectReason.remoteClosed.userDescription`）。
/// 认不出的原样返回，不猜。
nonisolated enum SSHConnectFailureText {

    enum Kind: Equatable {
        /// 目标拒绝了连接：那个端口上没有程序在监听。
        case refused
        /// TCP 连上了，但在 SSH 握手完成之前就被对方断开（重置或关闭）。
        case closedBeforeHandshake
        case timedOut
        case hostUnreachable
        case networkUnreachable
    }

    /// `.connectFailed` 的正文 → 归类。认不出为 nil。
    static func kind(of detail: String) -> Kind? {
        if detail == SSHDisconnectReason.remoteClosed.userDescription { return .closedBeforeHandshake }
        guard let code = errno(in: detail) else { return nil }
        switch code {
        case ECONNREFUSED: return .refused
        case ECONNRESET, ECONNABORTED, EPIPE: return .closedBeforeHandshake
        case ETIMEDOUT: return .timedOut
        case EHOSTUNREACH, EHOSTDOWN: return .hostUnreachable
        case ENETUNREACH, ENETDOWN: return .networkUnreachable
        default: return nil
        }
    }

    /// 改写成说清原因的一句；认不出的原样返回。
    static func refine(_ detail: String, host: String, port: Int) -> String {
        guard let kind = kind(of: detail) else { return detail }
        let endpoint = address(host: host, port: port)
        switch kind {
        case .refused:
            return String(localized: "\(endpoint) 拒绝了连接：那里没有在运行的 SSH 服务（服务器可能已关闭，或端口不对）")
        case .closedBeforeHandshake:
            return String(localized: "\(endpoint) 在 SSH 握手前就断开了连接，没有收到 SSH 服务的回应：服务器可能没在运行（开着代理或 VPN 时，连不上的主机也会这样表现）")
        case .timedOut:
            return String(localized: "连接 \(endpoint) 超时：对方没有回应（主机可能已关机、地址不对，或被防火墙拦住）")
        case .hostUnreachable:
            return String(localized: "无法到达 \(endpoint)：主机不可达")
        case .networkUnreachable:
            return String(localized: "网络不可达，连不到 \(endpoint)")
        }
    }

    /// NIO `IOError` 的描述里带的 errno（`… (errno: 61)`），取最后一个。
    static func errno(in text: String) -> Int32? {
        guard let range = text.range(of: #"\(errno: (\d+)\)"#, options: [.regularExpression, .backwards]) else {
            return nil
        }
        let digits = text[range].filter(\.isNumber)
        return Int32(digits)
    }

    /// `host:port`，IPv6 字面量加方括号。
    static func address(host: String, port: Int) -> String {
        let bracketed = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(bracketed):\(String(port))"
    }
}

/// 终端连不上时给人看的那句话（两端的终端共用）。
///
/// 用户点「重新连接」/「重试」之后同样连不上，开头说「仍然连不上」，让人知道这是重试的结果、不是又断了一次；
/// 后面跟着这一次的原因（拒绝连接、不可达、超时、认证、主机密钥、连接方式变弱……各有各的说法）。
nonisolated enum TerminalConnectFailure {
    static func message(for error: any Error, retrying: Bool) -> String {
        guard retrying else { return error.localizedDescription }
        return String(localized: "仍然连不上：\(reason(of: error))")
    }

    /// 去掉「SSH 连接失败：」这层前缀后的原因（重试的那句已经说了连不上）。
    static func reason(of error: any Error) -> String {
        switch error {
        case SSHConnection.SSHConnectionError.connectFailed(let message),
             SSHConnection.SSHConnectionError.handshakeFailed(let message):
            return message
        default:
            return error.localizedDescription
        }
    }
}
