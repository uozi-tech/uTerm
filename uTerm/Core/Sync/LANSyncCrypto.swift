import CryptoKit
import Foundation

/// LAN sync messages are encrypted after the clear-text ephemeral-key handshake.
/// The pairing code authenticates the derived session without ever travelling on
/// the wire, while X25519 keeps the six-digit code from being the data key.
nonisolated struct LANSyncCryptoSession: Sendable {
    struct Hello: Codable, Sendable {
        let version: Int
        let sessionID: UUID
        let deviceID: String
        let deviceName: String
        let ephemeralPublicKey: Data
    }

    struct Envelope: Codable, Sendable {
        let sessionID: UUID
        let sequence: UInt64
        let messageType: String
        let nonce: Data
        let ciphertext: Data
    }

    enum Direction: String, Sendable {
        case senderToReceiver
        case receiverToSender
    }

    let sessionID: UUID
    let hello: Hello
    private let privateKey: Curve25519.KeyAgreement.PrivateKey
    private let pairingCode: String
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?

    init(sessionID: UUID = UUID(), deviceID: String, deviceName: String,
         pairingCode: String) {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        self.sessionID = sessionID
        self.privateKey = privateKey
        self.pairingCode = pairingCode
        self.hello = Hello(version: LANSyncConstants.protocolVersion,
                           sessionID: sessionID,
                           deviceID: deviceID,
                           deviceName: deviceName,
                           ephemeralPublicKey: privateKey.publicKey.rawRepresentation)
    }

    private init(hello: Hello, privateKey: Curve25519.KeyAgreement.PrivateKey,
                 pairingCode: String) {
        self.sessionID = hello.sessionID
        self.hello = hello
        self.privateKey = privateKey
        self.pairingCode = pairingCode
    }

    func respondingSession(to remote: Hello, deviceID: String, deviceName: String,
                           pairingCode: String) throws -> LANSyncCryptoSession {
        guard remote.version == LANSyncConstants.protocolVersion else {
            throw LANSyncTransportError.protocolMismatch
        }
        guard remote.sessionID == sessionID else {
            throw LANSyncTransportError.invalidMessage
        }
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remote.ephemeralPublicKey)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        var result = LANSyncCryptoSession(
            hello: Hello(version: LANSyncConstants.protocolVersion,
                         sessionID: remote.sessionID,
                         deviceID: deviceID,
                         deviceName: deviceName,
                         ephemeralPublicKey: privateKey.publicKey.rawRepresentation),
            privateKey: privateKey,
            pairingCode: pairingCode)
        try result.deriveKeys(remoteKey: remoteKey, initiator: false)
        return result
    }

    mutating func establish(with remote: Hello, initiator: Bool) throws {
        guard remote.version == LANSyncConstants.protocolVersion,
              remote.sessionID == sessionID else {
            throw LANSyncTransportError.protocolMismatch
        }
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: remote.ephemeralPublicKey)
        try deriveKeys(remoteKey: remoteKey, initiator: initiator)
    }

    func encrypted<T: Encodable>(_ value: T, messageType: String,
                                 sequence: UInt64, encoder: JSONEncoder) throws -> Data {
        guard let sendKey else { throw LANSyncTransportError.handshakeRequired }
        let plaintext = try encoder.encode(value)
        let nonce = ChaChaPoly.Nonce()
        let aad = Self.aad(sessionID: sessionID, sequence: sequence, messageType: messageType)
        let sealed = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        let envelope = Envelope(sessionID: sessionID, sequence: sequence, messageType: messageType,
                                nonce: Data(nonce), ciphertext: sealed.ciphertext + sealed.tag)
        return try encoder.encode(envelope)
    }

    func decrypted<T: Decodable>(_ data: Data, as type: T.Type,
                                 encoder: JSONEncoder, decoder: JSONDecoder) throws -> T {
        let plaintext = try decryptedBytes(data)
        return try decoder.decode(type, from: plaintext.bytes)
    }

    func decryptedBytes(_ data: Data) throws -> (messageType: String, sequence: UInt64, bytes: Data) {
        guard let receiveKey else { throw LANSyncTransportError.handshakeRequired }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.sessionID == sessionID else { throw LANSyncTransportError.invalidMessage }
        let nonce = try ChaChaPoly.Nonce(data: envelope.nonce)
        let aad = Self.aad(sessionID: sessionID, sequence: envelope.sequence,
                           messageType: envelope.messageType)
        guard envelope.ciphertext.count >= 16 else { throw LANSyncTransportError.invalidMessage }
        let bodyEnd = envelope.ciphertext.count - 16
        let box = try ChaChaPoly.SealedBox(nonce: nonce,
                                           ciphertext: envelope.ciphertext[..<bodyEnd],
                                           tag: envelope.ciphertext[bodyEnd...])
        return (envelope.messageType, envelope.sequence,
                try ChaChaPoly.open(box, using: receiveKey, authenticating: aad))
    }

    private mutating func deriveKeys(remoteKey: Curve25519.KeyAgreement.PublicKey,
                                     initiator: Bool) throws {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let salt = SHA256.hash(data: Data(pairingCode.utf8))
        let info = Data("uTerm LAN sync v3 \(sessionID.uuidString)".utf8)
        let localDirection = initiator ? Direction.senderToReceiver : Direction.receiverToSender
        let remoteDirection = initiator ? Direction.receiverToSender : Direction.senderToReceiver
        sendKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(salt),
                                                  sharedInfo: info + Data(localDirection.rawValue.utf8),
                                                  outputByteCount: 32)
        receiveKey = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(salt),
                                                     sharedInfo: info + Data(remoteDirection.rawValue.utf8),
                                                     outputByteCount: 32)
    }

    private static func aad(sessionID: UUID, sequence: UInt64, messageType: String) -> Data {
        Data("\(sessionID.uuidString)|\(sequence)|\(messageType)".utf8)
    }
}
