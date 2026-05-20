import Crypto
@preconcurrency import Citadel

/// 已解析的私钥，与 Citadel 的 `SSHAuthenticationMethod` 解耦。
nonisolated enum ParsedPrivateKey {
    case rsa(Insecure.RSA.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    /// 映射成 Citadel 认证方法。
    func authenticationMethod(username: String) -> SSHAuthenticationMethod {
        switch self {
        case .rsa(let key):     return .rsa(username: username, privateKey: key)
        case .ed25519(let key): return .ed25519(username: username, privateKey: key)
        case .p256(let key):    return .p256(username: username, privateKey: key)
        case .p384(let key):    return .p384(username: username, privateKey: key)
        case .p521(let key):    return .p521(username: username, privateKey: key)
        }
    }
}
