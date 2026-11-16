import CryptoKit
import Foundation
import Security

// 「我的设备」：同一 Apple ID 下打开过 uTerm 的设备，各自把**公开**身份写进 iCloud 钥匙串的名册。
//
// 名册只是请求队列，**被控端从不读它**，名册里有谁都不会被任何一台 Mac 放行。2026-11-07 删掉的
// `RemoteLegacyRoster`（service `com.uozi.uTerm.remote.roster`）正是凭名册放行，所以这里换了 service，
// 还在跑旧测试版的设备看不到这份名册。
//
// 确认一台新设备要在已有的那台上做：两台设备显示同一个 6 位数，你核对后点「一致」（`RemoteSiblingCode`）。
// 确认结果只记在点了「一致」的那台设备上（`RemoteSiblingApprovals`，不同步）：名册里谁都能写，同步的
// 「已确认」记录会被钥匙串圈里的冒充者伪造。之后由确认过的设备向它配对过的 Mac 担保新设备（P1 起）。
// 方案与威胁模型见 docs/remote-shared-pairing-research.md。

/// 名册里的一台设备：只有公开信息。
nonisolated struct RemoteSiblingDevice: Codable, Equatable, Sendable, Identifiable {
    /// 远控设备 ID（`RemoteLocalDevice.id()`），与握手里报的 `deviceID` 是同一个。
    var id: UUID
    var name: String
    var model: String?
    /// `RemoteDevicePlatform` 的原始值。
    var platform: String?
    /// 远控长期公钥（X25519 原始 32 字节），与握手里报的 `staticKey` 是同一把。
    var publicKey: Data
    /// 最近一次登记（名字、机型、钥匙变了才重写）的时间。
    var updatedAt: Date

    var isMac: Bool { platform == RemoteDevicePlatform.mac.rawValue }

    /// 副标题里的机型：与名字相同（名字本来就是退回的机型名）就不重复。
    var modelDetail: String? {
        guard let model, model != name else { return nil }
        return model
    }

    /// 内容相同（不看登记时间）：没变就不重写，免得每次启动都推一次同步。
    func sameIdentity(as other: RemoteSiblingDevice) -> Bool {
        id == other.id && name == other.name && model == other.model && platform == other.platform
            && publicKey == other.publicKey
    }
}

/// 确认新设备时两台设备之间往来的一条消息，经名册同步。
///
/// 顺序（先定公钥、后出随机数，照蓝牙「数字比较」配对）：
/// 1. 新设备（candidate）对每台已有设备（voucher）先写 `commitment` = H(两边身份 ‖ 自己的随机数)；
/// 2. 已有设备上点「确认」后，它记下这条承诺，写 `challenge`（自己的随机数）；
/// 3. 新设备看到 `challenge` 才写 `reveal`（第 1 步的随机数 ‖ 对方的随机数），然后换一个随机数重新承诺；
/// 4. 已有设备核对 `reveal` 与承诺一致，两边都按两个随机数算出 6 位数。
///
/// 冒充者要让两边的数字一样，必须在看到对方随机数之前就定下自己那一半，只有百万分之一的机会。
nonisolated struct RemoteSiblingMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case commitment
        case challenge
        case reveal
    }

    var kind: Kind
    /// 被确认的设备（新设备）。
    var candidate: UUID
    var candidateKey: Data
    /// 确认它的设备（已有的设备）。
    var voucher: UUID
    var voucherKey: Data
    /// `commitment`：承诺值；`challenge`：已有设备的随机数；`reveal`：新设备的随机数 ‖ 它回答的那个 `challenge` 的随机数。
    var value: Data
    var createdAt: Date

    var account: String { Self.account(kind, candidate: candidate, voucher: voucher) }

    static func account(_ kind: Kind, candidate: UUID, voucher: UUID) -> String {
        "\(kind.rawValue).\(candidate.uuidString).\(voucher.uuidString)"
    }

    /// 两边的身份与给定的设备对得上。
    func pairs(candidate: RemoteSiblingDevice, voucher: RemoteSiblingDevice) -> Bool {
        self.candidate == candidate.id && candidateKey == candidate.publicKey
            && self.voucher == voucher.id && voucherKey == voucher.publicKey
    }
}

/// 名册里的一条记录。外面包一层 `record` / `v`，以后多一种记录，老版本跳过不认识的就行。
nonisolated enum RemoteSiblingRecord: Equatable, Sendable {
    case device(RemoteSiblingDevice)
    case message(RemoteSiblingMessage)

    static let version = 1

    var account: String {
        switch self {
        case .device(let device): return Self.deviceAccount(device.id)
        case .message(let message): return message.account
        }
    }

    static func deviceAccount(_ id: UUID) -> String { "device.\(id.uuidString)" }

    private struct Envelope: Codable {
        var v: Int
        var record: String
        var device: RemoteSiblingDevice?
        var message: RemoteSiblingMessage?
    }

    func encoded() throws -> Data {
        let envelope: Envelope
        switch self {
        case .device(let device): envelope = Envelope(v: Self.version, record: "device", device: device)
        case .message(let message): envelope = Envelope(v: Self.version, record: "message", message: message)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try encoder.encode(envelope)
    }

    /// 解不开、版本不认识、钥匙长度不对的记录都当没有（名册谁都能写）。
    static func decode(_ data: Data) -> RemoteSiblingRecord? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.v == version else { return nil }
        switch envelope.record {
        case "device":
            guard let device = envelope.device, device.publicKey.count == RemoteSiblingCode.keyLength else { return nil }
            return .device(device)
        case "message":
            guard let message = envelope.message, message.candidateKey.count == RemoteSiblingCode.keyLength,
                  message.voucherKey.count == RemoteSiblingCode.keyLength, !message.value.isEmpty else { return nil }
            return .message(message)
        default:
            return nil
        }
    }
}

/// 某一刻的名册。
nonisolated struct RemoteSiblingSnapshot: Equatable, Sendable {
    var devices: [RemoteSiblingDevice] = []
    var messages: [RemoteSiblingMessage] = []

    func device(_ id: UUID) -> RemoteSiblingDevice? {
        devices.first { $0.id == id }
    }

    func message(_ kind: RemoteSiblingMessage.Kind, candidate: UUID, voucher: UUID) -> RemoteSiblingMessage? {
        messages.first { $0.kind == kind && $0.candidate == candidate && $0.voucher == voucher }
    }
}

/// 名册的读写（iCloud 钥匙串，`RemoteSyncedStorage`）。测试宿主里是内存的一份（`RemoteLocalState`）。
nonisolated struct RemoteSiblingRoster: Sendable {
    static let service = "com.uozi.uTerm.remote.devices"

    let storage: any RemoteSyncedStorage

    init(storage: any RemoteSyncedStorage = RemoteLocalState.syncedStorage(service: Self.service)) {
        self.storage = storage
    }

    func load() -> RemoteSiblingSnapshot {
        var snapshot = RemoteSiblingSnapshot()
        var seenDevices = Set<UUID>()
        for record in storage.loadAll().compactMap(RemoteSiblingRecord.decode) {
            switch record {
            case .device(let device):
                // 同一个 ID 只会有一条（account 按 ID 取），防着点。
                if seenDevices.insert(device.id).inserted { snapshot.devices.append(device) }
            case .message(let message):
                snapshot.messages.append(message)
            }
        }
        return snapshot
    }

    func save(_ record: RemoteSiblingRecord) throws {
        try storage.save(record.encoded(), account: record.account)
    }

    func delete(account: String) {
        try? storage.delete(account: account)
    }

    /// 登记（或更新）一台设备。内容没变就不写。
    func register(_ device: RemoteSiblingDevice, existing: RemoteSiblingDevice?) throws {
        if let existing, existing.sameIdentity(as: device) { return }
        try save(.device(device))
    }

    /// 撤下一台设备，连同和它有关的消息。
    func remove(_ id: UUID, snapshot: RemoteSiblingSnapshot) {
        delete(account: RemoteSiblingRecord.deviceAccount(id))
        for message in snapshot.messages where message.candidate == id || message.voucher == id {
            delete(account: message.account)
        }
    }

    /// 启动时登记本机。名字、机型要在主线程取，钥匙串读写放后台（同步钥匙串可能慢）。
    @MainActor
    static func registerLocalDevice() {
        let name = LANSyncCoordinator.localDeviceName()
        let model = RemoteDeviceModel.current()
        DispatchQueue.global(qos: .utility).async {
            // 只读不生成：启动时别的地方可能正在第一次生成身份（见 `existingIdentity`）。还没有身份就等下次启动，
            // 或者打开「我的设备」时再登记。
            guard let device = try? RemoteSiblingDevice.local(name: name, model: model, createsIdentity: false) else { return }
            let roster = RemoteSiblingRoster()
            try? roster.register(device, existing: roster.load().device(device.id))
        }
    }
}

nonisolated extension RemoteSiblingDevice {
    /// 本机：主控方向的长期身份。Mac 上两个方向本来就是同一把钥匙、同一个设备 ID。
    /// `createsIdentity` 为 false 时还没有身份就抛错，不生成。
    static func local(name: String, model: String?, identity: RemoteIdentityStore = RemoteIdentityStore(role: .hosts),
                      createsIdentity: Bool = true, now: Date = Date()) throws -> RemoteSiblingDevice {
        let key: Curve25519.KeyAgreement.PrivateKey
        if createsIdentity {
            key = try identity.localIdentity()
        } else {
            // 设备 ID 同理：还没有就不生成。
            guard let existing = identity.existingIdentity(),
                  RemoteLocalState.defaults.string(forKey: DefaultsKey.remoteDeviceID) != nil else {
                throw RemoteProtocolError.notPaired
            }
            key = existing
        }
        return RemoteSiblingDevice(id: RemoteLocalDevice.id(), name: name, model: model,
                                   platform: RemoteDevicePlatform.current.rawValue,
                                   publicKey: key.publicKey.rawRepresentation, updatedAt: now)
    }
}

// MARK: - 核对码

nonisolated enum RemoteSiblingCode {
    static let keyLength = 32
    static let nonceLength = 16

    static func newNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: nonceLength)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceLength, &bytes)
        return Data(bytes)
    }

    /// 新设备对自己随机数的承诺：H(用途 ‖ 新设备 ‖ 已有设备 ‖ 新设备的随机数)。
    static func commitment(candidate: RemoteSiblingDevice, voucher: RemoteSiblingDevice, nonce: Data) -> Data {
        digest("uterm-sibling-commit-v1", candidate: candidate, voucher: voucher, nonces: [nonce])
    }

    /// 两边显示的 6 位数：H(用途 ‖ 新设备 ‖ 已有设备 ‖ 新设备的随机数 ‖ 已有设备的随机数) 取前 4 字节模一百万。
    static func code(candidate: RemoteSiblingDevice, voucher: RemoteSiblingDevice,
                     candidateNonce: Data, voucherNonce: Data) -> String {
        let hash = digest("uterm-sibling-code-v1", candidate: candidate, voucher: voucher,
                          nonces: [candidateNonce, voucherNonce])
        let value = hash.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    /// 定长字段直接拼（UUID 16 字节、公钥 32 字节、随机数 16 字节），不会有歧义。
    private static func digest(_ label: String, candidate: RemoteSiblingDevice, voucher: RemoteSiblingDevice,
                               nonces: [Data]) -> Data {
        var message = Data(label.utf8)
        message.append(uuidBytes(candidate.id))
        message.append(candidate.publicKey)
        message.append(uuidBytes(voucher.id))
        message.append(voucher.publicKey)
        for nonce in nonces { message.append(nonce) }
        return Data(SHA256.hash(data: message))
    }

    private static func uuidBytes(_ id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }
}

// MARK: - 只存本机的两份记录

/// 本机确认过的设备（本机是已有的那台）。只存本机、不同步：同步的话，钥匙串圈里的冒充者能自己写一条「已确认」。
/// 按设备 ID + 公钥记：那台设备重装后换了钥匙，要重新确认。
nonisolated struct RemoteSiblingApproval: Codable, Equatable, Sendable {
    var id: UUID
    var publicKey: Data
    var name: String
    var approvedAt: Date
}

/// 本机作为新设备、对每台已有设备承诺过的随机数，以及已经回答过的那次确认（App 重开后还要接着显示同一个数，
/// 也不能对同一次确认答第二个随机数）。
nonisolated struct RemoteSiblingCommitState: Codable, Equatable, Sendable {
    /// 承诺时对方的公钥：对方换了钥匙就重新承诺。
    var voucherKey: Data
    /// 当前承诺里的随机数。
    var nonce: Data
    /// 回答过的那次确认：对方的随机数与算出的 6 位数。
    var answeredChallenge: Data?
    var answeredCode: String?
}

/// 上面两份记录的存取（`RemoteSecretStorage`：生产是本机钥匙串，`ThisDeviceOnly`）。
nonisolated final class RemoteSiblingLocalStore: @unchecked Sendable {
    private static let approvalsAccount = "siblingApprovals"
    private static let commitsAccount = "siblingCommits"

    private let storage: any RemoteSecretStorage
    private let lock = NSLock()

    init(storage: any RemoteSecretStorage = RemoteLocalState.secrets) {
        self.storage = storage
    }

    func approvals() -> [UUID: RemoteSiblingApproval] {
        lock.lock()
        defer { lock.unlock() }
        return load(Self.approvalsAccount) ?? [:]
    }

    func approve(_ approval: RemoteSiblingApproval) throws {
        try update(Self.approvalsAccount) { (all: inout [UUID: RemoteSiblingApproval]) in all[approval.id] = approval }
    }

    func removeApproval(_ id: UUID) throws {
        try update(Self.approvalsAccount) { (all: inout [UUID: RemoteSiblingApproval]) in all[id] = nil }
    }

    func commits() -> [UUID: RemoteSiblingCommitState] {
        lock.lock()
        defer { lock.unlock() }
        return load(Self.commitsAccount) ?? [:]
    }

    func setCommit(_ state: RemoteSiblingCommitState?, voucher: UUID) throws {
        try update(Self.commitsAccount) { (all: inout [UUID: RemoteSiblingCommitState]) in all[voucher] = state }
    }

    private func load<Value: Decodable>(_ account: String) -> Value? {
        guard let data = try? storage.load(account) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func update<Value: Codable>(_ account: String, _ change: (inout [UUID: Value]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var all: [UUID: Value] = load(account) ?? [:]
        change(&all)
        try storage.save(try JSONEncoder().encode(all), account: account)
    }
}
