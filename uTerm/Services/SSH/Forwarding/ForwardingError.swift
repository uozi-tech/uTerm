import Foundation
import NIOCore

/// 转发失败的归类 —— 决定 UI 行的恢复操作（改端口 / 重试）。
nonisolated enum ForwardingErrorKind: String, Sendable, Equatable {
    /// 本地 `bind` EADDRINUSE：监听端口被占用 → 「改端口」。
    case conflict
    /// 目标连不上（refused / timeout / no-route）→ 「重试」。
    case unreachable
    /// 远端拒绝绑定 / 开通道（需 GatewayPorts、管理员禁止）→ 「重试」。
    case denied
    /// 认证失败 → 「重试」（重新征询凭据由上层处理）。
    case auth
    /// 兜底未知错误。
    case unknown
}

/// 一条转发隧道的失败信息。`message` 已本地化、且**以规则自身名字开头**（对齐设计稿）。
nonisolated struct ForwardingError: Error, Sendable, Equatable {
    let kind: ForwardingErrorKind
    /// 本地化文案，以 `rule.name` 开头。
    let message: String

    init(kind: ForwardingErrorKind, message: String) {
        self.kind = kind
        self.message = message
    }

    /// 把任意 `Error` 归类成 `ForwardingError`。
    ///
    /// 优先按强类型 `POSIXError` 的 `errno` 判定（最可靠），再回退到
    /// `NSPOSIXErrorDomain` 的 `code`，最后退化到对 `localizedDescription`
    /// 做大小写无关的子串匹配（覆盖 NIO/Citadel 把底层错误包成文本的情形）。
    ///
    /// 文案统一用 `rule.name` 前缀 + 归类原因，便于 UI 行直接展示。
    static func classify(_ error: Error, rule: ForwardingRuleSnapshot) -> ForwardingError {
        let kind = classifyKind(error)
        let reason: String
        switch kind {
        case .conflict:
            reason = String(localized: "监听端口 \(rule.listenPort) 已被占用")
        case .unreachable:
            reason = String(localized: "目标地址无法连接")
        case .denied:
            // EACCES/EPERM 在本地监听侧（-L/-D）= 本机 bind 权限问题（特权端口 <1024 或
            // App Sandbox），在远端侧（-R）= 服务器拒绝绑定。按规则方向给对症文案，避免对
            // 本地转发误报「需要 GatewayPorts」。
            if rule.kind == .remote {
                reason = String(localized: "远端拒绝建立转发（可能需要服务器开启 GatewayPorts）")
            } else {
                reason = String(localized: "本地端口 \(rule.listenPort) 绑定被拒绝（端口低于 1024 需管理员权限，建议改用 ≥1024 的端口）")
            }
        case .auth:
            reason = String(localized: "认证失败")
        case .unknown:
            reason = error.localizedDescription
        }
        return ForwardingError(kind: kind, message: "\(rule.name)：\(reason)")
    }

    /// 看门狗判死（底层 SSH 传输已断）的专用文案。kind 取 `.unreachable`：
    /// 非 conflict → UI 行的恢复操作是「重试」，重试经 coordinator 重建连接。
    static func connectionLost(rule: ForwardingRuleSnapshot) -> ForwardingError {
        ForwardingError(kind: .unreachable,
                        message: "\(rule.name)：\(String(localized: "SSH 连接已断开"))")
    }

    // MARK: - 私有归类

    private static func classifyKind(_ error: Error) -> ForwardingErrorKind {
        // 1. 强类型 POSIXError —— 最可靠。
        if let posix = error as? POSIXError {
            if let k = kind(forErrno: posix.code.rawValue) { return k }
        }
        // 1b. NIOCore.IOError —— NIO 的 bind/listen/connect 失败真正抛出的类型。它**不是**
        //     `POSIXError`，桥接成 `NSError` 的 domain 也不是 `NSPOSIXErrorDomain`，且不带
        //     `LocalizedError` ——`localizedDescription` 只会是通用的「未能完成操作
        //     （NIOCore.IOError 错误1）」(这里的 1 是 Swift→NSError 的默认 code，**不是**
        //     errno)。必须直接读 `errnoCode` 才能归类，否则 EADDRINUSE/EACCES/EPERM 等本可
        //     恢复的错误会全部落到 `.unknown`，对用户显示成无意义的「错误1」。
        if let io = error as? IOError {
            if let k = kind(forErrno: io.errnoCode) { return k }
        }
        // 2. NSError(domain: NSPOSIXErrorDomain) —— NIO 常这么包 bind/connect 失败。
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain {
            if let k = kind(forErrno: Int32(ns.code)) { return k }
        }
        // 3. 文本子串匹配（大小写无关）—— 覆盖 Citadel/NIOSSH 的文本化错误。
        let text = error.localizedDescription.lowercased()
        if text.contains("address already in use") || text.contains("eaddrinuse") {
            return .conflict
        }
        if text.contains("connection refused")
            || text.contains("no route to host")
            || text.contains("timed out") || text.contains("timeout")
            || text.contains("network is unreachable")
            || text.contains("host is down") {
            return .unreachable
        }
        if text.contains("authenticationfailed")
            || text.contains("allauthenticationoptionsfailed")
            || text.contains("authentication failed")
            || text.contains("permission denied (publickey")
            || text.contains("permission denied (password")
            || text.contains("permission denied (keyboard-interactive") {
            return .auth
        }
        if text.contains("channelcreationfailed")
            || text.contains("administratively prohibited")
            || (text.contains("forwarding") && (text.contains("disabled") || text.contains("denied")))
            || text.contains("permission denied")
            || text.contains("unauthorized") {
            return .denied
        }
        return .unknown
    }

    /// 把 errno 映射成归类。返回 nil 表示该 errno 不在已知集合内。
    private static func kind(forErrno code: Int32) -> ForwardingErrorKind? {
        switch code {
        case EADDRINUSE:
            return .conflict
        case ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH, EHOSTDOWN:
            return .unreachable
        case EACCES, EPERM:
            return .denied
        default:
            return nil
        }
    }
}
