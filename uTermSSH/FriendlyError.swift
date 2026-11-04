import Foundation
import NIOCore

/// 把底层错误（POSIX `errno` / `NIOCore.IOError` / `NSError`）翻译成面向用户的中文
/// 描述，杜绝把「未能完成操作（NIOCore.IOError 错误1）」「Error Domain=… Code=48」这类
/// 技术串直接抛给用户。
///
/// 关键坑：`NIOCore.IOError` **不是** `POSIXError`、桥接 `NSError` 的 domain 也不是
/// `NSPOSIXErrorDomain`、且不带 `LocalizedError` —— 其 `localizedDescription` 只会是通用的
/// 「未能完成操作（NIOCore.IOError 错误N）」（这里的 N 是 Swift→NSError 的默认 code，
/// **不是** errno）。要拿到真正的 errno 必须直接读 `errnoCode`。详见 [[port-forwarding-feature]]。
nonisolated enum FriendlyError {

    /// 面向用户的中文描述。优先级：精选 errno 含义 → 干净的系统描述 → 通用兜底。
    /// **保证**不会返回含 “IOError 错误N” / “Error Domain” 之类技术噪音的字符串。
    static func describe(
        _ error: Error,
        fallback: String = String(localized: "操作未能完成，请稍后重试")
    ) -> String {
        if let code = posixErrno(of: error), let msg = message(forErrno: code) {
            return msg
        }
        if let channelError = error as? ChannelError {
            return describe(channelError)
        }
        let raw = (error as NSError).localizedDescription
        if isTechnicalNoise(raw) {
            // 即便不在精选表，也尽量带上中性的错误码信息，而不是误导性的「错误1」。
            if let code = posixErrno(of: error) {
                return String(localized: "操作未能完成（系统错误码 \(code)）")
            }
            return fallback
        }
        // 描述本身是人类可读的（如服务器返回的拒绝原因），原样返回。
        return raw
    }

    /// `NIOCore.ChannelError` 是不带 `LocalizedError` 的枚举：桥接后的文案是「未能完成操作
    /// （NIOCore.ChannelError 错误 N）」，N 是 case 序号（带载荷的 case 排前面，所以
    /// `connectTimeout` 恰好是 0），无法定位。这里给出可读、可定位的中文。
    static func describe(_ error: ChannelError) -> String {
        switch error {
        case .connectTimeout(let amount):
            let seconds = Double(amount.nanoseconds) / 1_000_000_000
            let shown = seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
            return String(localized: "登录阶段超时：\(shown) 秒内未完成握手与认证（ChannelError.connectTimeout）")
        case .ioOnClosedChannel:
            return String(localized: "连接已关闭（ChannelError.ioOnClosedChannel）")
        case .alreadyClosed:
            return String(localized: "连接已关闭（ChannelError.alreadyClosed）")
        case .eof:
            return String(localized: "对方已关闭连接（ChannelError.eof）")
        default:
            // 其余 case 走 NIO 自己的 description（如 "Connect pending"），附类型名便于定位。
            return "\(error)（NIOCore.ChannelError）"
        }
    }

    /// 从任意 `Error` 提取 POSIX `errno`：覆盖 `POSIXError` / `NIOCore.IOError` /
    /// `NSError(domain: NSPOSIXErrorDomain)`。返回 nil = 该错误不携带 POSIX errno。
    static func posixErrno(of error: Error) -> Int32? {
        if let posix = error as? POSIXError { return posix.code.rawValue }
        if let io = error as? IOError { return io.errnoCode }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return Int32(ns.code) }
        return nil
    }

    /// `errno` → 中文含义（覆盖网络 / 连接 / 文件 IO 常见集）。返回 nil = 不在精选表。
    static func message(forErrno code: Int32) -> String? {
        switch code {
        // —— 绑定 / 连接 ——
        case EADDRINUSE:    return String(localized: "端口已被占用")
        case EADDRNOTAVAIL: return String(localized: "无法绑定该地址（地址不属于本机）")
        case EACCES:        return String(localized: "权限不足（端口可能需要管理员权限）")
        case EPERM:         return String(localized: "操作被系统拒绝（端口低于 1024 需管理员权限，或被沙盒限制）")
        case ECONNREFUSED:  return String(localized: "目标拒绝连接（服务可能未启动或端口不对）")
        case ETIMEDOUT:     return String(localized: "连接超时")
        case EHOSTUNREACH:  return String(localized: "无法连接到目标主机（路由不可达）")
        case ENETUNREACH:   return String(localized: "网络不可达")
        case EHOSTDOWN:     return String(localized: "目标主机已关闭")
        case ENETDOWN:      return String(localized: "本机网络已断开")
        // —— 连接中断 ——
        case ECONNRESET:    return String(localized: "连接被对方重置")
        case ECONNABORTED:  return String(localized: "连接被中断")
        case EPIPE:         return String(localized: "连接已断开")
        case ENOTCONN:      return String(localized: "尚未建立连接")
        // —— 文件 / IO ——
        case ENOENT:        return String(localized: "文件或路径不存在")
        case EISDIR:        return String(localized: "目标是一个目录")
        case ENOTDIR:       return String(localized: "路径中包含非目录项")
        case EEXIST:        return String(localized: "目标已存在")
        case ENOSPC:        return String(localized: "磁盘空间不足")
        case EROFS:         return String(localized: "目标为只读，无法写入")
        case EMFILE, ENFILE:return String(localized: "打开的文件过多，请稍后重试")
        // —— 通用 ——
        case EAGAIN:        return String(localized: "资源暂时不可用，请重试")
        case ECANCELED:     return String(localized: "操作已取消")
        default:            return nil
        }
    }

    /// 判定一条 `localizedDescription` 是否「技术噪音」——不该直接给用户看：
    /// NIO/NSError 桥接兜底文案（含 IOError / NIOCore / Error Domain / “错误N”/“error N”）。
    private static func isTechnicalNoise(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("ioerror")
            || t.contains("niocore")
            || t.contains("error domain")
            || t.contains("couldn't be completed")
            || t.range(of: #"错误\s*\d+"#, options: .regularExpression) != nil
            || t.range(of: #"error\s+\d+"#, options: .regularExpression) != nil
    }
}
