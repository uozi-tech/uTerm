import CryptoKit
import Foundation

// 加入设备组的 CPace 参数与封包（docs/remote-device-group-design.md §7.1「加入」）。
//
// 新设备是 initiator，组员是 responder：
// - 口令：新设备随机生成、只显示在它自己屏幕上的 6 位数字（ASCII）；
// - CI：`"uTerm device-group join v1"` ‖ 新设备 ID（16 字节）；
// - sid：每换一个数就换一个（16 字节随机）；
// - AD：设备 ID ‖ X25519 公钥 ‖ Ed25519 公钥（`RemoteGroupDevice.associatedData`）。两端只认自己喂进
//   `finish` 的那份 AD 里的钥匙，名册里别的字段（名字、机型）不经核对码认证，所以真正记下的条目另外封在
//   入组包（组员 → 新设备）和 `done`（新设备 → 组员）里。

/// 组员封给新设备的入组包：当前的组员名单。用 CPace 会话密钥派生的钥匙封，只有输对了数的这一对算得出。
nonisolated struct RemoteGroupAdmissionPackage: Codable, Equatable, Sendable {
    /// 输码的组员自己（连同它当初怎么进组的）。
    var member: RemoteGroupMember
    /// 它认的其它组员。
    var others: [RemoteGroupMember]
    /// 它记下的移除。新设备拿去就不会被名册里残留的旧 `admit` 骗回已经移除的设备
    /// （钥匙串圈里的人能删掉名册里的 `remove`，组员本机的移除记录删不掉）。
    var removals: [RemoteGroupRemoval]
    /// 新设备自己的加入信息（添加者 = 这台组员）。新设备按它判断后来的 `remove` 是不是冲着这一次加入来的。
    var admission: RemoteGroupAdmission
}

nonisolated enum RemoteGroupJoinCrypto {
    static let codeLength = 6
    static let channelLabel = "uTerm device-group join v1"
    static let packageLabel = "uTerm device-group admission v1"
    static let entryLabel = "uTerm device-group done v1"

    // MARK: 码与 sid

    /// 均匀的 6 位数：拒绝采样，2^32 里最后不满一百万的那段不要。
    static func newCode() -> String {
        let limit: UInt32 = 4_294_000_000
        while true {
            let value = randomBytes(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if value < limit { return String(format: "%06u", value % 1_000_000) }
        }
    }

    static func newSessionID() -> Data {
        randomBytes(RemoteGroupFormat.sessionIDLength)
    }

    /// 只留 ASCII 数字（空格、短横都去掉），正好 6 位才算。
    static func normalizedCode(_ text: String) -> String? {
        let digits = String(text.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) })
        return digits.count == codeLength ? digits : nil
    }

    /// 系统 CSPRNG（CryptoKit 生成随机钥匙走的就是它）。
    private static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // MARK: CPace

    static func channelIdentifier(candidate: UUID) -> Data {
        Data(channelLabel.utf8) + RemoteGroupFormat.uuidBytes(candidate)
    }

    /// 一端的 CPace。`local` 是本端的条目，它的 AD 随消息明文发出。
    static func session(_ role: CPaceSession.Role, code: String, candidate: UUID, sid: Data,
                        local: RemoteGroupDevice) throws -> CPaceSession {
        try CPaceSession(role: role, password: Data(code.utf8), channelIdentifier: channelIdentifier(candidate: candidate),
                         sessionID: sid, associatedData: local.associatedData)
    }

    /// 组员要存下的、新设备该回的 Ta。
    ///
    /// `CPaceKeys` 只给 `verifyPeerConfirmation`，不给期望值本身；组员输完码要等新设备回话，中间 App 可能
    /// 重启，内存里的 `CPaceKeys` 就没了。这里用 `CPace` 的同一套原语按 draft §10.4 重算，再拿
    /// `verifyPeerConfirmation` 核一遍，确保算的就是它心里的那个值。存的是标签不是 ISK：标签不能当钥匙用。
    static func expectedCandidateConfirmation(keys: CPaceKeys, sid: Data, join: RemoteGroupJoin) throws -> Data {
        let tag = CPace.confirmationTag(macKey: CPace.macKey(sid: sid, isk: keys.isk), share: join.share,
                                        associatedData: join.device.associatedData)
        guard keys.verifyPeerConfirmation(tag) else { throw CPaceError.invalidShare }
        return tag
    }

    static func packageKey(_ keys: CPaceKeys) -> SymmetricKey {
        keys.deriveKey(info: Data(packageLabel.utf8))
    }

    /// 组员要存下的、开 `done` 里条目用的钥匙（与 Ta 一样，App 重启后还要用）。
    static func entryKey(_ keys: CPaceKeys) -> SymmetricKey {
        keys.deriveKey(info: Data(entryLabel.utf8))
    }

    // MARK: 封包

    static func sealPackage(_ package: RemoteGroupAdmissionPackage, key: SymmetricKey, sid: Data, candidate: UUID,
                            member: UUID) throws -> Data {
        try seal(package, key: key, label: packageLabel, sid: sid, candidate: candidate, member: member)
    }

    static func openPackage(_ box: Data, key: SymmetricKey, sid: Data, candidate: UUID,
                            member: UUID) -> RemoteGroupAdmissionPackage? {
        open(RemoteGroupAdmissionPackage.self, box, key: key, label: packageLabel, sid: sid, candidate: candidate,
             member: member)
    }

    static func sealEntry(_ device: RemoteGroupDevice, key: SymmetricKey, sid: Data, candidate: UUID,
                          member: UUID) throws -> Data {
        try seal(device, key: key, label: entryLabel, sid: sid, candidate: candidate, member: member)
    }

    static func openEntry(_ box: Data, key: SymmetricKey, sid: Data, candidate: UUID, member: UUID) -> RemoteGroupDevice? {
        open(RemoteGroupDevice.self, box, key: key, label: entryLabel, sid: sid, candidate: candidate, member: member)
    }

    /// 绑定用途、这一轮的 sid、新设备与组员：封好的东西搬不到别的轮次、别的设备对上。
    private static func additionalData(label: String, sid: Data, candidate: UUID, member: UUID) -> Data {
        var canonical = RemoteGroupCanonical(label: label)
        canonical.append(sid)
        canonical.append(candidate)
        canonical.append(member)
        return canonical.bytes
    }

    private static func seal<Value: Encodable>(_ value: Value, key: SymmetricKey, label: String, sid: Data,
                                               candidate: UUID, member: UUID) throws -> Data {
        let plain = try RemoteGroupFormat.encoder().encode(value)
        let aad = additionalData(label: label, sid: sid, candidate: candidate, member: member)
        return try ChaChaPoly.seal(plain, using: key, authenticating: aad).combined
    }

    private static func open<Value: Decodable>(_ type: Value.Type, _ box: Data, key: SymmetricKey, label: String,
                                               sid: Data, candidate: UUID, member: UUID) -> Value? {
        let aad = additionalData(label: label, sid: sid, candidate: candidate, member: member)
        guard let sealed = try? ChaChaPoly.SealedBox(combined: box),
              let plain = try? ChaChaPoly.open(sealed, using: key, authenticating: aad) else { return nil }
        return try? RemoteGroupFormat.decoder().decode(type, from: plain)
    }

    /// 比较耗时与内容无关。
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
