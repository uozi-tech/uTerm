import Foundation
import NIOCore
@preconcurrency import NIOSSH

/// 用一把 `RSASHA512PrivateKey` 做 publickey 认证的客户端委托。
/// 单次提交：首次给出 offer；再次被调用（= 服务器已拒）则失败。
nonisolated final class RSASHA512AuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let key: RSASHA512PrivateKey
    private var offered = false

    init(username: String, components: RSAKeyComponents) throws {
        self.username = username
        self.key = try RSASHA512PrivateKey(components: components)
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !offered else {
            // 第二次调用 = 服务器拒绝了上次 offer，无更多可试。
            nextChallengePromise.fail(USSHKitInternalError.authenticationFailed(
                "认证失败：服务器拒绝了 RSA 公钥"))
            return
        }
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(USSHKitInternalError.authenticationFailed(
                "服务器不支持公钥认证"))
            return
        }
        offered = true
        let offer = NIOSSHUserAuthenticationOffer(
            username: username,
            serviceName: "",
            offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(custom: key))))
        nextChallengePromise.succeed(offer)
    }
}
