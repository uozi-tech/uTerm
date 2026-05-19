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
    var createdAt: Date = Date()
    var sortOrder: Int = 0

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
}
