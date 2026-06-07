import Foundation

/// SOCKS5 错误（解析阶段）。
nonisolated enum SOCKS5Error: Error, Equatable, Sendable {
    /// VER 字段不是 0x05。
    case badVersion
    /// CMD 不是 0x01 (CONNECT)。
    case unsupportedCommand
    /// ATYP 不是 0x01/0x03/0x04。
    case badAddressType
}

/// 纯字节的 SOCKS5 握手解析/编码 —— 零网络、零状态，可完整单测。
///
/// 仅实现 `-D`（动态转发）所需的子集：无认证 greeting + CONNECT 命令，
/// 地址类型支持 IPv4 / 域名 / IPv6。BIND / UDP ASSOCIATE 不支持（报
/// `unsupportedCommand`）。
///
/// `ParseResult` 携带 `consumed`（本次解析消费的字节数），调用方据此从
/// 接收缓冲区剔除已解析字节、保留剩余流量数据。
nonisolated enum SOCKS5Handshake {

    /// CONNECT 请求的目标地址。`host` 为点分十进制 IPv4 / 域名 / 冒号 IPv6 文本。
    struct ConnectRequest: Equatable, Sendable {
        let host: String
        let port: Int
    }

    /// 解析结果：成功（含消费字节数）/ 数据不足（等待更多字节）/ 解析失败。
    enum ParseResult<T: Equatable>: Equatable {
        case ok(T, consumed: Int)
        case incomplete
        case failure(SOCKS5Error)
    }

    private static let version: UInt8 = 0x05
    private static let cmdConnect: UInt8 = 0x01
    private static let atypIPv4: UInt8 = 0x01
    private static let atypDomain: UInt8 = 0x03
    private static let atypIPv6: UInt8 = 0x04
    private static let methodNoAuth: UInt8 = 0x00

    /// 解析客户端 greeting：`VER NMETHODS METHODS...`。
    /// 返回 `Bool` = 是否提供了「无认证」(0x00) 方法。VER 必须为 5。
    static func parseGreeting(_ b: [UInt8]) -> ParseResult<Bool> {
        guard b.count >= 2 else { return .incomplete }
        guard b[0] == version else { return .failure(.badVersion) }
        let nMethods = Int(b[1])
        let total = 2 + nMethods
        guard b.count >= total else { return .incomplete }
        let methods = b[2..<total]
        let noAuth = methods.contains(methodNoAuth)
        return .ok(noAuth, consumed: total)
    }

    /// 服务器对 greeting 的应答：`[0x05, 0x00]` 接受（无认证）/ `[0x05, 0xFF]` 拒绝。
    static func greetingReply(accept: Bool) -> [UInt8] {
        [version, accept ? methodNoAuth : 0xFF]
    }

    /// 解析 CONNECT 请求：`VER CMD RSV ATYP DST.ADDR DST.PORT`。
    /// CMD 必须为 1(CONNECT)；ATYP 支持 IPv4(1)/域名(3)/IPv6(4)。
    static func parseConnect(_ b: [UInt8]) -> ParseResult<ConnectRequest> {
        // 固定头 4 字节：VER CMD RSV ATYP。
        guard b.count >= 4 else { return .incomplete }
        guard b[0] == version else { return .failure(.badVersion) }
        guard b[1] == cmdConnect else { return .failure(.unsupportedCommand) }
        // b[2] == RSV，忽略。
        let atyp = b[3]

        let addrStart = 4
        let host: String
        let portStart: Int

        switch atyp {
        case atypIPv4:
            let end = addrStart + 4
            guard b.count >= end else { return .incomplete }
            host = b[addrStart..<end].map(String.init).joined(separator: ".")
            portStart = end

        case atypDomain:
            // 一个长度字节，随后是该长度的域名。
            guard b.count >= addrStart + 1 else { return .incomplete }
            let len = Int(b[addrStart])
            let nameStart = addrStart + 1
            let nameEnd = nameStart + len
            guard b.count >= nameEnd else { return .incomplete }
            host = String(decoding: b[nameStart..<nameEnd], as: UTF8.self)
            portStart = nameEnd

        case atypIPv6:
            let end = addrStart + 16
            guard b.count >= end else { return .incomplete }
            host = formatIPv6(Array(b[addrStart..<end]))
            portStart = end

        default:
            return .failure(.badAddressType)
        }

        // 端口：2 字节大端。
        let portEnd = portStart + 2
        guard b.count >= portEnd else { return .incomplete }
        let port = Int(b[portStart]) << 8 | Int(b[portStart + 1])
        return .ok(ConnectRequest(host: host, port: port), consumed: portEnd)
    }

    /// 对 CONNECT 的应答。成功 `REP=0x00`，失败 `REP=0x01`（general failure）。
    /// 固定回 ATYP=IPv4、BND.ADDR=0.0.0.0、BND.PORT=0（客户端一般忽略）。
    static func connectReply(success: Bool) -> [UInt8] {
        [version, success ? 0x00 : 0x01, 0x00, atypIPv4, 0, 0, 0, 0, 0, 0]
    }

    /// 把 16 字节 IPv6 地址格式化为冒号文本，压缩最长的一段连续零组为 `::`。
    private static func formatIPv6(_ bytes: [UInt8]) -> String {
        var groups: [Int] = []
        var i = 0
        while i < 16 {
            groups.append(Int(bytes[i]) << 8 | Int(bytes[i + 1]))
            i += 2
        }
        // 找最长连续零组区间（长度 >= 2 才压缩）。
        var bestStart = -1, bestLen = 0
        var curStart = -1, curLen = 0
        for (idx, g) in groups.enumerated() {
            if g == 0 {
                if curStart < 0 { curStart = idx; curLen = 0 }
                curLen += 1
                if curLen > bestLen { bestLen = curLen; bestStart = curStart }
            } else {
                curStart = -1; curLen = 0
            }
        }
        if bestLen < 2 {
            return groups.map { String($0, radix: 16) }.joined(separator: ":")
        }
        let head = groups[0..<bestStart].map { String($0, radix: 16) }.joined(separator: ":")
        let tail = groups[(bestStart + bestLen)...].map { String($0, radix: 16) }.joined(separator: ":")
        return "\(head)::\(tail)"
    }
}
