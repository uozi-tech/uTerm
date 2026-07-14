import Crypto
@preconcurrency import Citadel

/// 已解析的私钥，与 Citadel 的 `SSHAuthenticationMethod` 解耦。
nonisolated enum ParsedPrivateKey {
    case rsa(RSAKeyComponents)
    case legacyOpenSSHRSA(Insecure.RSA.PrivateKey)
    case ed25519(Curve25519.Signing.PrivateKey)
    case p256(P256.Signing.PrivateKey)
    case p384(P384.Signing.PrivateKey)
    case p521(P521.Signing.PrivateKey)

    /// 映射成 Citadel 认证方法。RSA（PEM）走自定义 rsa-sha2-512 委托。
    func authenticationMethod(username: String) throws -> SSHAuthenticationMethod {
        switch self {
        case .rsa(let components):
            let delegate = try RSASHA512AuthDelegate(username: username, components: components)
            return .custom(delegate)
        case .legacyOpenSSHRSA(let key):
            return .rsa(username: username, privateKey: key)
        case .ed25519(let key): return .ed25519(username: username, privateKey: key)
        case .p256(let key):    return .p256(username: username, privateKey: key)
        case .p384(let key):    return .p384(username: username, privateKey: key)
        case .p521(let key):    return .p521(username: username, privateKey: key)
        }
    }
}
