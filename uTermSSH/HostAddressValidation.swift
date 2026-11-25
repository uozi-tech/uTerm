import Foundation

/// 主机地址里「看起来像 IPv4、却不是标准点分四段十进制」的写法。
///
/// 系统解析（`inet_aton` / `getaddrinfo`）接受老式简写：`a.b.c` 把 c 当 16 位、`a.b` 把 b 当 24 位、单个整数当
/// 32 位，还认 `010.0.0.1`（八进制）、`0x0a.0.0.1`（十六进制）。于是少打一段的 `10.31.102` 会被当成
/// `10.31.0.102` 连上另一台机器；而 `256.1.1.1`、`1.2.3.4.5` 这种解析不了的会被当成域名去查——开着代理 TUN
/// 时任何名字都能解析出一个假 IP，看起来像在连、其实连的是代理。所以这类地址一律当场判成「不是有效的 IP 地址」，
/// 不交给系统解析。
///
/// 判定只看形状：按点分段，**每一段**都是数字（或 `0x` 开头的十六进制）才算「像 IPv4」。任何一段带字母（域名、
/// `ec2-1-2-3-4.compute.amazonaws.com`、`1.2.3.4.nip.io`）都交给域名规则，这里不管；含 `:` 或方括号的是 IPv6
/// 字面量 / 带端口的写法，按原来的规则处理。顶级域不会是纯数字，所以全数字的点分名字不可能是合法域名。
nonisolated enum HostAddressValidation {

    /// 像 IPv4 却不合法（段数不是 4、某段超过 255、多位的段带前导 0、十六进制、单个整数、多余的点）。
    /// 空串、域名、IPv6、合法的点分四段都返回 false。
    static func isInvalidIPv4(_ raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(":"), !host.contains("["), !host.contains("]") else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        let numericLike = labels.allSatisfy { $0.isEmpty || isDecimal($0) || isHex($0) }
        guard numericLike, labels.contains(where: { !$0.isEmpty }) else { return false }
        return !isDottedQuad(labels)
    }

    /// 给人看的一句（表单里的 inline 报错、连接失败时的说明都用它）。
    static func message(for host: String) -> String {
        let shown = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(localized: "「\(shown)」不是有效的 IP 地址：IPv4 地址要写成用点隔开的四段 0–255 的数字，例如 192.168.1.10。",
                      bundle: SSHHelperBundle.localization)
    }

    /// 连接前的检查：目标与跳板机的地址。不合法就抛 `InvalidHostAddressError`，不交给系统解析。
    static func validate(host: String, jumpHost: String?) throws {
        if isInvalidIPv4(host) { throw InvalidHostAddressError(host: host, isJumpHost: false) }
        if let jumpHost, isInvalidIPv4(jumpHost) { throw InvalidHostAddressError(host: jumpHost, isJumpHost: true) }
    }

    /// 标准写法：恰好四段，每段 0–255 的十进制，多位的不带前导 0。
    private static func isDottedQuad(_ labels: [Substring]) -> Bool {
        guard labels.count == 4 else { return false }
        return labels.allSatisfy { label in
            guard isDecimal(label), label.count <= 3, label == "0" || label.first != "0",
                  let value = Int(label) else { return false }
            return value <= 255
        }
    }

    private static func isDecimal(_ label: Substring) -> Bool {
        !label.isEmpty && label.utf8.allSatisfy { (0x30...0x39).contains($0) }
    }

    private static func isHex(_ label: Substring) -> Bool {
        let bytes = Array(label.utf8)
        guard bytes.count >= 2, bytes[0] == 0x30, bytes[1] == 0x78 || bytes[1] == 0x58 else { return false }
        return bytes.dropFirst(2).allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }
    }
}

/// 主机（或跳板机）地址像 IPv4 却不合法，连接前就拦下了（见 `HostAddressValidation`）。
/// 是填错了地址，重试不会好：重连逻辑停下来等用户改。
nonisolated struct InvalidHostAddressError: LocalizedError, SSHFailureClassifying, Equatable {
    let host: String
    let isJumpHost: Bool

    var errorDescription: String? {
        let detail = HostAddressValidation.message(for: host)
        guard isJumpHost else { return detail }
        return String(localized: "跳板机地址有误：\(detail)", bundle: SSHHelperBundle.localization)
    }

    var isPermanentConnectFailure: Bool { true }
    var transportFailureVerdict: Bool? { false }
}
