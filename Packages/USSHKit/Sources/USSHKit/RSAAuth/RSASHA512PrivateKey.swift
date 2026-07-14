import Foundation
import NIOSSH

/// `rsa-sha2-512` 的 NIOSSH 自定义私钥。经 `NIOSSHPrivateKey(custom:)` 接入认证。
nonisolated struct RSASHA512PrivateKey: NIOSSHPrivateKeyProtocol {
    static let keyPrefix = "rsa-sha2-512"

    private let signer: RSASHA512Signer
    private let components: RSAKeyComponents

    init(components: RSAKeyComponents) throws {
        self.signer = try RSASHA512Signer(components: components)
        self.components = components
    }

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASHA512PublicKey(modulus: components.modulus, publicExponent: components.publicExponent)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASHA512Signature(rawRepresentation: Data(try signer.sign(data)))
    }
}
