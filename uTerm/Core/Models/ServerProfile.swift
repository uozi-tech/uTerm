import Foundation
import SwiftData

/// SSH 认证方式。以原始字符串持久化（SwiftData+CloudKit 对枚举的支持以
/// String rawValue 最稳妥）。
enum AuthMethod: String, CaseIterable, Sendable {
    case password
    case privateKey
}

/// 一台服务器的连接配置。经 SwiftData + CloudKit 跨设备同步。
///
/// 重要约束：为兼容 CloudKit，所有存储属性必须有默认值或为可选，
/// 且不能使用 `@Attribute(.unique)`。本模型不含任何明文密钥 ——
/// 密码 / passphrase / 私钥内容由 `KeychainStore` 按 `id` 关联存储。
@Model
final class ServerProfile {
    var id: UUID = UUID()
    var name: String = ""
    var host: String = ""
    var port: Int = 22
    var username: String = ""
    /// `AuthMethod` 的 rawValue。通过 `authMethod` 计算属性读写。
    var authMethodRaw: String = AuthMethod.password.rawValue
    /// 私钥认证时引用的密钥库 `SSHKey.id`。私钥正文与口令存在该 key 的钟匙串条目下。
    /// 旧数据为 nil —— 连接时 `SSHAuthResolver` 回退到按 `profile.id` 取私钥。
    var keyID: UUID?
    var createdAt: Date = Date()
    var sortOrder: Int = 0

    /// 服务器分组标签（如 "production"、"staging"）。CloudKit 安全：可空。
    var group: String?
    /// 是否置顶显示。默认 false。
    var isPinned: Bool = false
    /// 最近一次成功连接的时间。连接成功后由调用方赋值。
    var lastConnectedAt: Date?

    /// 「仅 SFTP」连接模式：该主机只允许文件浏览 / 传输，禁用终端会话与命令执行。
    /// 默认 false（普通主机）。CloudKit 安全：有默认值。开启后，任何「在工作区打开 /
    /// 连接」的入口都会被重定向到 SFTP 浏览（见 `WelcomeView.openServer`）。
    var sftpOnly: Bool = false

    /// 单跳跳板机配置。自引用可选关系。M1 只用一层，
    /// 嵌套的 `jumpHost?.jumpHost` 不暴露、不连接。
    var jumpHost: ServerProfile?

    init() {}

    var authMethod: AuthMethod {
        get { AuthMethod(rawValue: authMethodRaw) ?? .password }
        set { authMethodRaw = newValue.rawValue }
    }

    /// 展示用的 `用户名@主机` 端点字符串。
    var displayEndpoint: String { "\(username)@\(host)" }

    /// 头像色块里的首字母（两端主机列表共用）。
    var monogram: String { Self.monogram(for: name) }

    /// 名字的第一个可见字符，拉丁字母转大写；名字为空白时退回 `?`。
    nonisolated static func monogram(for name: String) -> String {
        guard let first = name.first(where: { !$0.isWhitespace }) else { return "?" }
        return String(first).uppercased()
    }
}

// MARK: - 展示文案（两端主机列表 / 详情共用）

extension AuthMethod {
    /// 认证方式的展示名：「SSH 密钥」/「密码」。
    nonisolated var label: String {
        switch self {
        case .password: return String(localized: "密码", comment: "SSH 认证方式")
        case .privateKey: return String(localized: "SSH 密钥")
        }
    }
}

extension ServerProfile {
    /// 分组的展示名：nil 与空串都显示「未分组」。
    var groupLabel: String {
        if let group, !group.isEmpty { return group }
        return ServerGrouping.ungroupedLabel
    }

    /// `用户名@主机:端口`。端口用 `String(port)`，避免进 `Text` 时按本地化加千分位（`2,222`）。
    var endpointWithPort: String { "\(username)@\(host):\(String(port))" }
}
