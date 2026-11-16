import CryptoKit
import Foundation

// 设备组的名册：iCloud 钥匙串 service `com.uozi.uTerm.remote.group`。方案见 docs/remote-device-group-design.md，
// §7.1 是规格。
//
// 名册只是传话的通道：钥匙串圈里谁都能写、谁都能删任何一条（读 `loadAll` 时连 account 都拿不到，
// 记录放在哪个 account 下也不可信）。所以每种记录各有各的验法，验不过的当没有：
// - `device`：只用来列出「你的其它设备」，不影响谁是组员；
// - `join` / `answer` / `done`：靠新设备屏幕上的一次性码（CPace，`RemoteGroupJoinCrypto`）；
// - `admit` / `remove`：靠 Ed25519 签名，而且签名者必须是本机此刻认的组员（`RemoteGroupMembership`）。
// 被控的远控进程不读这份名册。

/// 记录里各字段的定长。
nonisolated enum RemoteGroupFormat {
    /// X25519 公钥、Ed25519 公钥都是 32 字节。
    static let keyLength = 32
    /// 每次加入的 sid。
    static let sessionIDLength = 16
    /// CPace 的公开分量 Y。
    static let shareLength = CPace.fieldSize
    /// CPace 的确认标签（HMAC-SHA512）。
    static let tagLength = 64
    /// Ed25519 签名。
    static let signatureLength = 64

    static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    /// 名册与本机状态的 JSON 一律用这一对（日期按 1970 起的秒数，与旧名册相同）。
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// 设备组里要比先后、要签名的时间：毫秒整数。
///
/// 不直接用 `Date`：`Date` 经 JSON（1970 秒数的浮点）来回一趟可能差一个 ulp，「移除时间 ≥ 加入时间」
/// 这种判断就会随机翻转，签名里的字节也对不上。
nonisolated struct RemoteGroupTime: Codable, Comparable, Hashable, Sendable {
    var milliseconds: Int64

    static let distantPast = RemoteGroupTime(milliseconds: .min)

    init(milliseconds: Int64) {
        self.milliseconds = milliseconds
    }

    init(_ date: Date) {
        let value = (date.timeIntervalSince1970 * 1000).rounded()
        // 只有本机造的时间走这里；非有限值或大到装不下的当 0，免得 Int64 转换直接崩溃。
        milliseconds = value.isFinite && abs(value) < 9e15 ? Int64(value) : 0
    }

    var date: Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// 紧接着的下一毫秒（到顶就停在顶上，不回绕）。
    var next: RemoteGroupTime {
        RemoteGroupTime(milliseconds: milliseconds == .max ? .max : milliseconds + 1)
    }

    static func < (lhs: RemoteGroupTime, rhs: RemoteGroupTime) -> Bool {
        lhs.milliseconds < rhs.milliseconds
    }

    init(from decoder: Decoder) throws {
        milliseconds = try decoder.singleValueContainer().decode(Int64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }
}

/// 一台设备的公开条目：名册里的 `device`，也是 `join`、`answer`、`admit` 里带的那一份。
nonisolated struct RemoteGroupDevice: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// 远控设备 ID（`RemoteLocalDevice.id()`），与握手里报的 `deviceID` 是同一个。
    var id: UUID
    var name: String
    var model: String?
    /// `RemoteDevicePlatform` 的原始值。
    var platform: String?
    /// 远控长期公钥（X25519 原始 32 字节），与握手里报的 `staticKey` 是同一把。
    var publicKey: Data
    /// 组员凭证（Ed25519 公钥，原始 32 字节）。组员名单按这把钥匙认人。
    var signingKey: Data
    var updatedAt: Date

    var isMac: Bool { platform == RemoteDevicePlatform.mac.rawValue }

    /// 副标题里的机型：与名字相同（名字本来就是退回的机型名）就不重复。
    var modelDetail: String? {
        guard let model, model != name else { return nil }
        return model
    }

    var hasValidKeys: Bool {
        publicKey.count == RemoteGroupFormat.keyLength && signingKey.count == RemoteGroupFormat.keyLength
    }

    /// CPace 的 AD：设备 ID ‖ X25519 公钥 ‖ Ed25519 公钥。三段都定长，直接拼没有歧义。
    var associatedData: Data {
        RemoteGroupFormat.uuidBytes(id) + publicKey + signingKey
    }

    /// ID 与两把钥匙都相同：核对码绑定的就是这三项。
    func sameKeys(as other: RemoteGroupDevice) -> Bool {
        id == other.id && publicKey == other.publicKey && signingKey == other.signingKey
    }

    /// 内容相同（不看登记时间）：没变就不重写，免得每次启动都推一次同步。
    func sameIdentity(as other: RemoteGroupDevice) -> Bool {
        sameKeys(as: other) && name == other.name && model == other.model && platform == other.platform
    }
}

/// 一台组员最初是怎么进组的：谁加的、什么时候，带着添加者本人的签名。补签 `admit` 时原样带上，
/// 移除连带按它找「它加进来的设备」。
///
/// 添加者的签名覆盖被加设备的 ID 与两把钥匙、添加者、加入时间：补签的设备改不了「是谁加的」——
/// 它只能写成自己手里有私钥的设备，被偷的组员没法把它加的设备记到别的组员名下、躲过移除连带。
nonisolated struct RemoteGroupAdmission: Codable, Equatable, Hashable, Sendable {
    static let label = "uTerm device-group original-admission v1"

    var admitterID: UUID
    /// 添加者的 Ed25519 公钥。
    var admitterKey: Data
    var admittedAt: RemoteGroupTime
    /// 添加者用 `admitterKey` 对 `signedBytes(for:)` 的签名。
    var signature: Data

    /// 添加者签一份。`admitter` 就是被加的设备自己时，是一直只有自己一台的设备记下的「我是第一台」，
    /// 只在入组包里出现，名册里的 `admit` 不收（见 `RemoteGroupRecord.decode`）。
    static func make(device: RemoteGroupDevice, admitter: RemoteGroupDevice, admittedAt: RemoteGroupTime,
                     key: Curve25519.Signing.PrivateKey) throws -> RemoteGroupAdmission {
        var admission = RemoteGroupAdmission(admitterID: admitter.id, admitterKey: admitter.signingKey,
                                             admittedAt: admittedAt, signature: Data())
        admission.signature = try key.signature(for: admission.signedBytes(deviceID: device.id, publicKey: device.publicKey,
                                                                          signingKey: device.signingKey))
        return admission
    }

    func signedBytes(deviceID: UUID, publicKey: Data, signingKey: Data) -> Data {
        var canonical = RemoteGroupCanonical(label: Self.label)
        canonical.append(deviceID)
        canonical.append(publicKey)
        canonical.append(signingKey)
        canonical.append(admitterID)
        canonical.append(admitterKey)
        canonical.append(admittedAt)
        return canonical.bytes
    }

    /// 签名对得上这台设备（ID 与两把钥匙）、这位添加者。添加者是不是本机认得的设备由 `RemoteGroupMembership` 判。
    func isValid(deviceID: UUID, publicKey: Data, signingKey: Data) -> Bool {
        guard admitterKey.count == RemoteGroupFormat.keyLength, signature.count == RemoteGroupFormat.signatureLength,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: admitterKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes(deviceID: deviceID, publicKey: publicKey,
                                                                signingKey: signingKey))
    }

    func isValid(for device: RemoteGroupDevice) -> Bool {
        isValid(deviceID: device.id, publicKey: device.publicKey, signingKey: device.signingKey)
    }

    /// 被加的设备自己当添加者（第一台）。
    func isSelfAdmission(of signingKey: Data) -> Bool {
        admitterKey == signingKey
    }
}

/// 本机认的一台组员。
nonisolated struct RemoteGroupMember: Codable, Equatable, Sendable {
    var device: RemoteGroupDevice
    var admission: RemoteGroupAdmission
}

/// 本机记下的一次移除（按 Ed25519 公钥记，不过期）。
nonisolated struct RemoteGroupRemoval: Codable, Equatable, Sendable {
    var deviceID: UUID
    /// X25519 公钥：只为核对 `admission` 的签名（签名覆盖设备的两把钥匙）。
    var publicKey: Data
    var signingKey: Data
    var removedAt: RemoteGroupTime
    /// 被移除的设备当初怎么进的组，只在本机确认它当过组员时才有（移除时它在本机的名单里，或者移除记录里
    /// 带的那份由本机认得的添加者签过）。有它，这台设备才算「认得的添加者」，它加过的设备也才在移除连带的
    /// 链条上（`RemoteGroupMembership.Signers`、`RemoteDeviceGroup.devicesAdmitted`）。
    var admission: RemoteGroupAdmission?

    /// 带着的加入信息签名对得上这台设备。
    var hasValidAdmission: Bool {
        admission?.isValid(deviceID: deviceID, publicKey: publicKey, signingKey: signingKey) ?? false
    }
}

// MARK: - 签名

/// 签名的内容：最前面是这种记录的用途标签，之后每个字段依次带 LEB128 长度前缀拼接（`CPace.prependLength`）。
/// 不对 JSON 重新序列化去签：JSON 的键序、数字写法都不唯一，验签的一方重建不出同样的字节。
nonisolated struct RemoteGroupCanonical {
    private(set) var bytes = Data()

    init(label: String) {
        append(Data(label.utf8))
    }

    mutating func append(_ data: Data) {
        bytes += CPace.prependLength(data)
    }

    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }

    /// 先记有没有（一个字节），有再记内容：nil 与空串分得开。
    mutating func appendOptional(_ string: String?) {
        if let string {
            append(Data([1]))
            append(string)
        } else {
            append(Data([0]))
        }
    }

    mutating func append(_ id: UUID) {
        append(RemoteGroupFormat.uuidBytes(id))
    }

    /// 大端 8 字节。
    mutating func append(_ time: RemoteGroupTime) {
        append(withUnsafeBytes(of: time.milliseconds.bigEndian) { Data($0) })
    }

    /// 先记有没有，有再记四个字段。
    mutating func appendOptional(_ admission: RemoteGroupAdmission?) {
        guard let admission else { return append(Data([0])) }
        append(Data([1]))
        append(admission.admitterID)
        append(admission.admitterKey)
        append(admission.admittedAt)
        append(admission.signature)
    }

    mutating func append(_ device: RemoteGroupDevice) {
        append(device.id)
        append(device.name)
        appendOptional(device.model)
        appendOptional(device.platform)
        append(device.publicKey)
        append(device.signingKey)
        append(RemoteGroupTime(device.updatedAt))
    }
}

/// 「D 是组员」。每台认 D 的组员各签一条（补签），保留 D 最初的添加者与加入时间。
nonisolated struct RemoteGroupAdmit: Codable, Equatable, Sendable {
    static let label = "uTerm device-group admit v1"

    var device: RemoteGroupDevice
    var admission: RemoteGroupAdmission
    var signer: UUID
    var signerKey: Data
    /// 签名的时间。签名者造记录时取「现在」与自己进组时间里晚的那个；验的一方只认签名者进组之后签的
    /// （见 `RemoteGroupMembership.Signers`），换过组的设备在旧组签的记录被重放进新组也不算数。
    var signedAt: RemoteGroupTime
    var signature: Data

    var account: String { Self.account(device: device.id, signer: signer) }

    static func account(device: UUID, signer: UUID) -> String {
        "admit.\(device.uuidString).\(signer.uuidString)"
    }

    /// 签名覆盖除签名之外的每个字段。
    var signedBytes: Data {
        var canonical = RemoteGroupCanonical(label: Self.label)
        canonical.append(device)
        canonical.append(admission.admitterID)
        canonical.append(admission.admitterKey)
        canonical.append(admission.admittedAt)
        canonical.append(admission.signature)
        canonical.append(signer)
        canonical.append(signerKey)
        canonical.append(signedAt)
        return canonical.bytes
    }

    static func make(device: RemoteGroupDevice, admission: RemoteGroupAdmission, signer: RemoteGroupDevice,
                     signedAt: RemoteGroupTime, key: Curve25519.Signing.PrivateKey) throws -> RemoteGroupAdmit {
        var normalized = device
        // 登记时间按毫秒取整再签：不是整毫秒的值经 JSON 来回一趟，取整后可能落到相邻的一毫秒，验签就过不了。
        normalized.updatedAt = RemoteGroupTime(device.updatedAt).date
        var admit = RemoteGroupAdmit(device: normalized, admission: admission, signer: signer.id,
                                     signerKey: signer.signingKey, signedAt: signedAt, signature: Data())
        admit.signature = try key.signature(for: admit.signedBytes)
        return admit
    }

    var hasValidSignature: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signerKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    /// 与本机认的这台组员内容相同（Ed25519 签名带随机数，不能比字节）。
    func matches(_ member: RemoteGroupMember) -> Bool {
        device.sameIdentity(as: member.device) && admission == member.admission
    }
}

/// 「D 被移除」，由做移除的组员签。按 Ed25519 公钥生效：D 换了钥匙（重装）就不是同一台。
nonisolated struct RemoteGroupRemove: Codable, Equatable, Sendable {
    static let label = "uTerm device-group remove v1"

    var deviceID: UUID
    var publicKey: Data
    var signingKey: Data
    /// 签名者取「现在」、被移除者的加入时间、自己的进组时间里最晚的那个：「移除时间 ≥ 加入时间」才算移除，
    /// 这样即便钟不准、或被移除者的加入时间被（被偷的组员）写到了将来，移除也照样生效。
    var removedAt: RemoteGroupTime
    /// 被移除的设备当初怎么进的组（做移除的设备本机记的那份，带最初添加者的签名）。没见过这台设备的
    /// 组员靠它知道「它当过组员、是谁加的」：它加过的设备照样认，移除连带也顺着它找得到。
    var admission: RemoteGroupAdmission?
    var signer: UUID
    var signerKey: Data
    var signature: Data

    var account: String { Self.account(device: deviceID, signer: signer) }

    static func account(device: UUID, signer: UUID) -> String {
        "remove.\(device.uuidString).\(signer.uuidString)"
    }

    var signedBytes: Data {
        var canonical = RemoteGroupCanonical(label: Self.label)
        canonical.append(deviceID)
        canonical.append(publicKey)
        canonical.append(signingKey)
        canonical.append(removedAt)
        canonical.appendOptional(admission)
        canonical.append(signer)
        canonical.append(signerKey)
        return canonical.bytes
    }

    static func make(target: RemoteGroupDevice, admission: RemoteGroupAdmission?, removedAt: RemoteGroupTime,
                     signer: RemoteGroupDevice, key: Curve25519.Signing.PrivateKey) throws -> RemoteGroupRemove {
        var remove = RemoteGroupRemove(deviceID: target.id, publicKey: target.publicKey, signingKey: target.signingKey,
                                       removedAt: removedAt, admission: admission, signer: signer.id,
                                       signerKey: signer.signingKey, signature: Data())
        remove.signature = try key.signature(for: remove.signedBytes)
        return remove
    }

    var hasValidSignature: Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signerKey) else { return false }
        return key.isValidSignature(signature, for: signedBytes)
    }

    /// 记录里带的、签名对得上被移除者的那份加入信息。
    var verifiedAdmission: RemoteGroupAdmission? {
        guard let admission, admission.isValid(deviceID: deviceID, publicKey: publicKey, signingKey: signingKey)
        else { return nil }
        return admission
    }
}

// MARK: - 加入

/// 新设备的加入请求（CPace 第一条消息）。不签名：真伪靠核对码。
nonisolated struct RemoteGroupJoin: Codable, Equatable, Sendable {
    var device: RemoteGroupDevice
    /// 这一轮的 sid（16 字节随机），每换一个数就换一个。
    var sid: Data
    /// Ya。
    var share: Data
    var createdAt: Date

    var account: String { Self.account(device.id) }

    static func account(_ candidate: UUID) -> String { "join.\(candidate.uuidString)" }
}

/// 输码的组员回的（CPace 第二条消息）：Yb、确认标签 Tb、用会话密钥封的入组包。
nonisolated struct RemoteGroupAnswer: Codable, Equatable, Sendable {
    var candidate: UUID
    var sid: Data
    /// 组员自己的条目：其中 ID 与两把钥匙就是它喂进 CPace 的 AD。
    var member: RemoteGroupDevice
    var share: Data
    var confirmation: Data
    /// `RemoteGroupAdmissionPackage`，ChaChaPoly 封好（`RemoteGroupJoinCrypto.sealPackage`）。
    var package: Data
    var createdAt: Date

    var account: String { Self.account(candidate: candidate, member: member.id) }

    static func account(candidate: UUID, member: UUID) -> String {
        "answer.\(candidate.uuidString).\(member.uuidString)"
    }
}

/// 新设备核对通过后回的（CPace 第三条消息）：确认标签 Ta，外加封好的自己的条目（名字、机型经它认证）。
nonisolated struct RemoteGroupDone: Codable, Equatable, Sendable {
    var candidate: UUID
    var member: UUID
    var sid: Data
    var confirmation: Data
    /// 新设备自己的 `RemoteGroupDevice`，ChaChaPoly 封好（`RemoteGroupJoinCrypto.sealEntry`）。
    var entry: Data
    var createdAt: Date

    var account: String { Self.account(candidate: candidate, member: member) }

    static func account(candidate: UUID, member: UUID) -> String {
        "done.\(candidate.uuidString).\(member.uuidString)"
    }

    /// 同一条（不看时间）。
    func sameContent(as other: RemoteGroupDone) -> Bool {
        candidate == other.candidate && member == other.member && sid == other.sid
            && confirmation == other.confirmation && entry == other.entry
    }
}

// MARK: - 信封

/// 名册里的一条记录。外面包一层 `record` / `v`：以后多一种记录，老版本跳过不认识的就行。
nonisolated enum RemoteGroupRecord: Equatable, Sendable {
    case device(RemoteGroupDevice)
    case join(RemoteGroupJoin)
    case answer(RemoteGroupAnswer)
    case done(RemoteGroupDone)
    case admit(RemoteGroupAdmit)
    case remove(RemoteGroupRemove)

    static let version = 1

    var account: String {
        switch self {
        case .device(let device): return Self.deviceAccount(device.id)
        case .join(let join): return join.account
        case .answer(let answer): return answer.account
        case .done(let done): return done.account
        case .admit(let admit): return admit.account
        case .remove(let remove): return remove.account
        }
    }

    static func deviceAccount(_ id: UUID) -> String { "device.\(id.uuidString)" }

    private struct Envelope: Codable {
        var v: Int
        var record: String
        var device: RemoteGroupDevice?
        var join: RemoteGroupJoin?
        var answer: RemoteGroupAnswer?
        var done: RemoteGroupDone?
        var admit: RemoteGroupAdmit?
        var remove: RemoteGroupRemove?
    }

    func encoded() throws -> Data {
        var envelope = Envelope(v: Self.version, record: "")
        switch self {
        case .device(let device): envelope.record = "device"; envelope.device = device
        case .join(let join): envelope.record = "join"; envelope.join = join
        case .answer(let answer): envelope.record = "answer"; envelope.answer = answer
        case .done(let done): envelope.record = "done"; envelope.done = done
        case .admit(let admit): envelope.record = "admit"; envelope.admit = admit
        case .remove(let remove): envelope.record = "remove"; envelope.remove = remove
        }
        return try RemoteGroupFormat.encoder().encode(envelope)
    }

    /// 解不开、版本不认识、长度不对、签名验不过的记录都当没有（名册谁都能写）。
    /// 这里只验「签名与它自己声称的签名者对得上」；签名者是不是组员由 `RemoteGroupMembership` 判。
    static func decode(_ data: Data) -> RemoteGroupRecord? {
        guard let envelope = try? RemoteGroupFormat.decoder().decode(Envelope.self, from: data),
              envelope.v == version else { return nil }
        switch envelope.record {
        case "device":
            guard let device = envelope.device, device.hasValidKeys else { return nil }
            return .device(device)
        case "join":
            guard let join = envelope.join, join.device.hasValidKeys,
                  join.sid.count == RemoteGroupFormat.sessionIDLength,
                  join.share.count == RemoteGroupFormat.shareLength else { return nil }
            return .join(join)
        case "answer":
            guard let answer = envelope.answer, answer.member.hasValidKeys,
                  answer.sid.count == RemoteGroupFormat.sessionIDLength,
                  answer.share.count == RemoteGroupFormat.shareLength,
                  answer.confirmation.count == RemoteGroupFormat.tagLength, !answer.package.isEmpty else { return nil }
            return .answer(answer)
        case "done":
            guard let done = envelope.done, done.sid.count == RemoteGroupFormat.sessionIDLength,
                  done.confirmation.count == RemoteGroupFormat.tagLength, !done.entry.isEmpty else { return nil }
            return .done(done)
        case "admit":
            // 最初添加者的签名也要对得上；自己加自己（第一台）的不收：它从不需要靠名册进别人的名单，
            // 收了的话被偷的组员能让它加的设备自称「第一台」、躲过移除连带。
            guard let admit = envelope.admit, admit.device.hasValidKeys,
                  admit.signerKey.count == RemoteGroupFormat.keyLength,
                  admit.signature.count == RemoteGroupFormat.signatureLength, admit.hasValidSignature,
                  admit.admission.isValid(for: admit.device), !admit.admission.isSelfAdmission(of: admit.device.signingKey)
            else { return nil }
            return .admit(admit)
        case "remove":
            guard let remove = envelope.remove, remove.publicKey.count == RemoteGroupFormat.keyLength,
                  remove.signingKey.count == RemoteGroupFormat.keyLength,
                  remove.signerKey.count == RemoteGroupFormat.keyLength,
                  remove.signature.count == RemoteGroupFormat.signatureLength, remove.hasValidSignature,
                  remove.admission == nil || remove.verifiedAdmission != nil else { return nil }
            return .remove(remove)
        default:
            return nil
        }
    }
}

/// 某一刻的名册。
nonisolated struct RemoteGroupSnapshot: Equatable, Sendable {
    var devices: [RemoteGroupDevice] = []
    var joins: [RemoteGroupJoin] = []
    var answers: [RemoteGroupAnswer] = []
    var dones: [RemoteGroupDone] = []
    var admits: [RemoteGroupAdmit] = []
    var removes: [RemoteGroupRemove] = []

    func device(_ id: UUID) -> RemoteGroupDevice? {
        devices.first { $0.id == id }
    }

    /// 一台新设备当前的加入请求。冒充者可以把同一台设备的请求放在别的 account 下，有几条时取最新的
    /// （冒充者能做的也只是让这一轮作废）。
    func join(for candidate: UUID) -> RemoteGroupJoin? {
        joins.filter { $0.device.id == candidate }.max { $0.createdAt < $1.createdAt }
    }
}

/// 名册的读写（iCloud 钥匙串，`RemoteSyncedStorage`）。测试宿主里是内存的一份（`RemoteLocalState`）。
nonisolated struct RemoteGroupRoster: Sendable {
    static let service = "com.uozi.uTerm.remote.group"

    let storage: any RemoteSyncedStorage

    init(storage: any RemoteSyncedStorage = RemoteLocalState.syncedStorage(service: Self.service)) {
        self.storage = storage
    }

    func load() -> RemoteGroupSnapshot {
        var snapshot = RemoteGroupSnapshot()
        for record in storage.loadAll().compactMap(RemoteGroupRecord.decode) {
            switch record {
            case .device(let device): snapshot.devices.append(device)
            case .join(let join): snapshot.joins.append(join)
            case .answer(let answer): snapshot.answers.append(answer)
            case .done(let done): snapshot.dones.append(done)
            case .admit(let admit): snapshot.admits.append(admit)
            case .remove(let remove): snapshot.removes.append(remove)
            }
        }
        return snapshot
    }

    func save(_ record: RemoteGroupRecord) throws {
        try storage.save(record.encoded(), account: record.account)
    }

    func delete(account: String) {
        try? storage.delete(account: account)
    }
}
