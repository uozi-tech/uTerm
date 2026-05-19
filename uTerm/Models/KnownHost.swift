import Foundation
import SwiftData

/// 一台已通过 TOFU 信任的服务器主机密钥记录。经 SwiftData + CloudKit 同步。
///
/// 兼容 CloudKit：所有存储属性带默认值，不使用 `@Attribute(.unique)`。
/// `host` + `port` 在逻辑上唯一定位一台主机；去重由 `HostKeyVerifier` 在代码层完成。
@Model
final class KnownHost {
    var id: UUID = UUID()
    var host: String = ""
    var port: Int = 22
    /// NIOSSH 主机密钥算法名，如 `ssh-ed25519` / `rsa-sha2-256`。
    var keyTypeRaw: String = ""
    /// 服务器公钥的 SSH 线格式序列化字节。
    var keyBlob: Data = Data()
    /// SHA256 指纹（`SHA256:<base64>`），仅用于向用户展示。
    var fingerprint: String = ""
    var firstTrustedAt: Date = Date()

    init() {}
}
