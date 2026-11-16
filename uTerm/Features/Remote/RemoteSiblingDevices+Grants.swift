import CryptoKit
import Foundation

// 确认之后的开通（两端共用）：
// - 本机是**已有设备**：对本机确认过的每台设备 × 本机配对过、此刻在线的每台 Mac，经那条远控连接请 Mac 记下它
//   （`RemoteMacClient.vouch(for:)`），结果封好写进名册（`RemoteSiblingSealedGrant`）。一次只问一台，连不上的过
//   一会儿再问；Mac 记下了、拒绝了就不再问，不允许、版本太旧的隔几个小时再问。
// - 本机是**新设备**：收它认可的担保者（确认时本机也点了「一致」）封给本机的结果，Mac 记下了本机的，把 Mac 记进
//   本机的信任表（`RemoteSiblingHostAccess.adopt`）。本机忘记过的 Mac 不加回来，公钥对不上的不覆盖。

/// 本机配对过、此刻能问到的一台 Mac。
struct RemoteSiblingVouchTarget: Equatable {
    var id: UUID
    var name: String
    var publicKey: Data
    var model: String?
    var platform: String?
    /// 本机给这台 Mac 单独记的中继，交给新设备用。成员证书是发给本机的，不交出去。
    var relay: RemoteRelayConfig?
}

/// 新设备收下一台 Mac 的结果。
enum RemoteSiblingAdoption: Equatable {
    case added
    case alreadyKnown
    case conflict
    case forgotten
}

/// 开通要用到的、本机配对过的 Mac。App 里是 `RemoteMacDirectory`，测试里换成直连测试服务端的。
@MainActor
protocol RemoteSiblingHostAccess: AnyObject {
    /// 配对过、此刻在线、问得到的 Mac。
    func vouchTargets() -> [RemoteSiblingVouchTarget]
    /// 所有配对过的 Mac（不管在不在线），算进度用：id → 名字。
    func pairedHostNames() -> [UUID: String]
    /// 请这台 Mac 记下那台设备。连不上抛错。
    func vouch(_ device: RemoteSiblingDevice, at host: UUID) async throws -> RemoteVouchResult
    /// 新设备：把别的设备替本机开通的 Mac 记进信任表。
    func adopt(_ grant: RemoteSiblingGrant) -> RemoteSiblingAdoption
    /// 请这台 Mac 撤销同一组里丢了的那台设备。连不上抛错，Mac 太旧抛 `RemoteAttachError.rejected`。
    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult
}

extension RemoteSiblingDevices {
    /// 连不上的 Mac 隔这么久再问。
    static let vouchRetryInterval: TimeInterval = 60
    /// Mac 不允许、版本太旧：隔这么久再问。
    static let vouchRefusedRetryInterval: TimeInterval = 6 * 3600

    /// 新设备启动时收一次别的设备替它开通的 Mac（不问 Mac、不连网，只读名册）。还没有远控身份就什么都不做。
    static func receivePendingGrants(into hosts: any RemoteSiblingHostAccess) {
        guard let model = live(createsIdentity: false) else { return }
        model.hosts = hosts
        model.receiveGrants(model.roster.load())
    }

    // MARK: - 本机是新设备

    func receiveGrants(_ snapshot: RemoteSiblingSnapshot) {
        guard let hosts, let localKey else { return }
        let vouchers = store.trustedVouchers()
        var list: [Received] = []
        for sealed in snapshot.grants where sealed.candidate == local.id {
            // 只认本机认可的担保者，用确认时记下的那把公钥：名册里它的条目后来被改了也不认。
            guard let voucher = vouchers[sealed.voucher],
                  let key = try? RemoteSiblingSeal.key(local: localKey, remote: voucher.publicKey),
                  let grant = RemoteSiblingSeal.open(sealed, key: key) else { continue }
            let status: Received.Status
            if grant.isUsable {
                switch hosts.adopt(grant) {
                case .added: status = .opened
                case .alreadyKnown: status = .alreadyPaired
                case .conflict: status = .conflict
                case .forgotten: status = .forgotten
                }
            } else {
                status = .refused(grant.reason ?? String(localized: "这台 Mac 没有记下这台设备"))
            }
            list.append(Received(hostID: grant.hostID, hostName: grant.hostName, voucherName: voucher.name, status: status))
        }
        // 几台担保者都开通了同一台 Mac：能用的那条优先。
        var byHost: [UUID: Received] = [:]
        for item in list {
            if let existing = byHost[item.hostID], existing.status.isUsable, !item.status.isUsable { continue }
            byHost[item.hostID] = item
        }
        let sorted = byHost.values.sorted { ($0.hostName, $0.hostID.uuidString) < ($1.hostName, $1.hostID.uuidString) }
        if sorted != received { received = sorted }
    }

    // MARK: - 本机是已有设备

    /// 找下一件要问 Mac 的事做：先撤销丢了的设备，再替确认过的设备开通。一次只问一台，上一台还在问就等它。
    func vouchNext(_ snapshot: RemoteSiblingSnapshot) {
        guard vouchTask == nil, let hosts else { return }
        let targets = hosts.vouchTargets()
        cleanUpGrants(snapshot, pairedHosts: Set(hosts.pairedHostNames().keys))
        if revokeNext(snapshot, targets: targets, hosts: hosts) { return }
        guard let localKey else { return }
        let approvals = store.approvals()
        for device in others(snapshot) {
            guard approvals[device.id]?.publicKey == device.publicKey,
                  let key = try? RemoteSiblingSeal.key(local: localKey, remote: device.publicKey) else { continue }
            for target in targets where target.id != device.id {
                guard needsVouch(device: device, host: target, key: key, snapshot: snapshot) else { continue }
                lastVouchAttempt[attemptKey(device.id, target.id)] = now()
                vouchTask = Task { [weak self] in
                    await self?.vouch(device, at: target, key: key, hosts: hosts)
                    self?.vouchTask = nil
                }
                return
            }
        }
    }

    private func attemptKey(_ device: UUID, _ host: UUID) -> String { "\(device.uuidString).\(host.uuidString)" }

    /// 本机替设备写过、但本机已经不再配对的 Mac 的开通结果：没用了，清掉。
    private func cleanUpGrants(_ snapshot: RemoteSiblingSnapshot, pairedHosts: Set<UUID>) {
        for grant in snapshot.grants where grant.voucher == local.id && !pairedHosts.contains(grant.host) {
            roster.delete(account: grant.account)
        }
    }

    // MARK: - 丢了的设备

    /// 有还没撤的（丢了的设备, 在线的 Mac）就问一台，返回 true。
    private func revokeNext(_ snapshot: RemoteSiblingSnapshot, targets: [RemoteSiblingVouchTarget],
                            hosts: any RemoteSiblingHostAccess) -> Bool {
        let done = store.revocations()
        for tombstone in snapshot.tombstones where tombstone.deviceID != local.id {
            for target in targets where target.id != tombstone.deviceID {
                if let record = done[tombstone.deviceID]?[target.id],
                   record.isFinal || now().timeIntervalSince(record.at) < Self.vouchRefusedRetryInterval { continue }
                let key = "revoke." + attemptKey(tombstone.deviceID, target.id)
                if let last = lastVouchAttempt[key], now().timeIntervalSince(last) < Self.vouchRetryInterval { continue }
                lastVouchAttempt[key] = now()
                vouchTask = Task { [weak self] in
                    await self?.revoke(tombstone, at: target, hosts: hosts)
                    self?.vouchTask = nil
                }
                return true
            }
        }
        return false
    }

    private func revoke(_ tombstone: RemoteSiblingTombstone, at target: RemoteSiblingVouchTarget,
                        hosts: any RemoteSiblingHostAccess) async {
        let record: RemoteSiblingRevocationRecord
        do {
            let result = try await hosts.revokeSibling(tombstone.deviceID, publicKey: tombstone.publicKey, at: target.id)
            guard !Task.isCancelled else { return }
            record = RemoteSiblingRevocationRecord(outcome: result.outcome, reason: result.reason, at: now())
        } catch RemoteAttachError.rejected(let reason) {
            record = RemoteSiblingRevocationRecord(outcome: RemoteSiblingGrant.unsupported, reason: reason, at: now())
        } catch {
            AppLogger.info("我的设备：请「\(target.name)」撤销「\(tombstone.deviceName)」没连上：\(error.localizedDescription)",
                           category: RemoteLog.category)
            return
        }
        AppLogger.notice("我的设备：「\(target.name)」撤销「\(tombstone.deviceName)」的结果 \(record.outcome)",
                         category: RemoteLog.category)
        try? store.recordRevocation(record, device: tombstone.deviceID, host: target.id)
        refresh()
    }

    /// 本机替丢了的设备向各台 Mac 撤销的进度（列表用）。
    func revocationProgress(for tombstone: RemoteSiblingTombstone) -> Lost {
        var lost = Lost(tombstone: tombstone, revoked: [], refused: [:], waiting: [])
        let records = store.revocations()[tombstone.deviceID] ?? [:]
        let names = hosts?.pairedHostNames() ?? [:]
        for (hostID, name) in names.sorted(by: { $0.value < $1.value }) where hostID != tombstone.deviceID {
            guard let record = records[hostID] else {
                lost.waiting.append(name)
                continue
            }
            switch RemoteSiblingRevokeResult.Outcome(rawValue: record.outcome) {
            case .revoked, .notTrusted:
                lost.revoked.append(name)
            case .notInFamily, nil:
                lost.refused[name] = record.reason ?? String(localized: "这台 Mac 撤不了它")
            }
        }
        return lost
    }

    private func needsVouch(device: RemoteSiblingDevice, host: RemoteSiblingVouchTarget, key: SymmetricKey,
                            snapshot: RemoteSiblingSnapshot) -> Bool {
        if let last = lastVouchAttempt[attemptKey(device.id, host.id)],
           now().timeIntervalSince(last) < Self.vouchRetryInterval { return false }
        guard let sealed = snapshot.grants.first(where: { $0.candidate == device.id && $0.voucher == local.id && $0.host == host.id }),
              let grant = RemoteSiblingSeal.open(sealed, key: key) else { return true }
        // Mac 换了钥匙（重装过）：重新问。
        guard grant.hostKey == host.publicKey else { return true }
        if grant.isFinal { return false }
        return now().timeIntervalSince(sealed.createdAt) > Self.vouchRefusedRetryInterval
    }

    private func vouch(_ device: RemoteSiblingDevice, at target: RemoteSiblingVouchTarget, key: SymmetricKey,
                       hosts: any RemoteSiblingHostAccess) async {
        var grant = RemoteSiblingGrant(hostID: target.id, hostName: target.name, hostKey: target.publicKey,
                                       hostModel: target.model, hostPlatform: target.platform, outcome: "")
        do {
            let result = try await hosts.vouch(device, at: target.id)
            guard !Task.isCancelled else { return }
            grant.outcome = result.outcome
            grant.reason = result.reason
            grant.internetAccess = result.internetAccess
            // Mac 发的成员证书优先；没有就交本机给这台 Mac 单独记的中继（默认中继新设备经 iCloud 钥匙串本来就有）。
            grant.relay = result.relay ?? (result.internetAccess == true ? target.relay : nil)
        } catch RemoteAttachError.rejected(let reason) {
            grant.outcome = RemoteSiblingGrant.unsupported
            grant.reason = reason
        } catch {
            // 连不上：不写，过一会儿再问。
            AppLogger.info("我的设备：替「\(device.name)」问「\(target.name)」没连上：\(error.localizedDescription)",
                           category: RemoteLog.category)
            return
        }
        AppLogger.notice("我的设备：「\(target.name)」对「\(device.name)」的开通结果 \(grant.outcome)", category: RemoteLog.category)
        do {
            write(.grant(try RemoteSiblingSeal.seal(grant, candidate: device.id, voucher: local.id, key: key, now: now())))
        } catch {
            storageError = String(localized: "没法写入 iCloud 钥匙串：\(error.localizedDescription)")
        }
        refresh()
    }

    /// 本机替这台设备开通的进度（列表副标题用）。
    func delivery(for device: RemoteSiblingDevice, snapshot: RemoteSiblingSnapshot) -> Delivery? {
        guard let hosts, let localKey,
              let key = try? RemoteSiblingSeal.key(local: localKey, remote: device.publicKey) else { return nil }
        var result = Delivery(opened: [], refused: [], waiting: [])
        for (hostID, name) in hosts.pairedHostNames().sorted(by: { $0.value < $1.value }) where hostID != device.id {
            let grant = snapshot.grants
                .first { $0.candidate == device.id && $0.voucher == local.id && $0.host == hostID }
                .flatMap { RemoteSiblingSeal.open($0, key: key) }
            switch grant {
            case let grant? where grant.isUsable: result.opened.append(name)
            case .some: result.refused.append(name)
            case nil: result.waiting.append(name)
            }
        }
        return result
    }
}

extension RemoteSiblingDevices.Received.Status {
    var isUsable: Bool {
        switch self {
        case .opened, .alreadyPaired: return true
        case .conflict, .forgotten, .refused: return false
        }
    }
}

// MARK: - App 里：配对过的 Mac 就是目录里那些

extension RemoteMacDirectory: RemoteSiblingHostAccess {
    func vouchTargets() -> [RemoteSiblingVouchTarget] {
        macs.compactMap { mac in
            guard mac.source == .paired, mac.isOnline, let id = mac.deviceID, let key = mac.publicKey else { return nil }
            let peer = pairedPeer(id: id)
            return RemoteSiblingVouchTarget(id: id, name: peer?.name ?? mac.name, publicKey: key, model: peer?.model,
                                            platform: peer?.platform,
                                            relay: peer?.relay.flatMap { $0.isCertificate ? nil : $0 })
        }
    }

    func pairedHostNames() -> [UUID: String] {
        Dictionary(macs.compactMap { mac in mac.source == .paired ? mac.deviceID.map { ($0, mac.name) } : nil },
                   uniquingKeysWith: { first, _ in first })
    }

    func vouch(_ device: RemoteSiblingDevice, at host: UUID) async throws -> RemoteVouchResult {
        guard let mac = macs.first(where: { $0.deviceID == host }) else { throw RemoteProtocolError.closed }
        // 已经开着这台 Mac 的连接就借用；没开就临时连一下，问完放掉（Mac 上按窗口计数，iOS 留着，退后台时一起收）。
        if let existing = existingClient(macID: mac.id) { return try await existing.vouch(for: device) }
        #if os(macOS)
        let client = acquireClient(for: mac)
        defer { releaseClient(macID: mac.id) }
        return try await client.vouch(for: device)
        #else
        return try await client(for: mac).vouch(for: device)
        #endif
    }

    func revokeSibling(_ deviceID: UUID, publicKey: Data, at host: UUID) async throws -> RemoteSiblingRevokeResult {
        guard let mac = macs.first(where: { $0.deviceID == host }) else { throw RemoteProtocolError.closed }
        if let existing = existingClient(macID: mac.id) { return try await existing.revokeSibling(deviceID, publicKey: publicKey) }
        #if os(macOS)
        let client = acquireClient(for: mac)
        defer { releaseClient(macID: mac.id) }
        return try await client.revokeSibling(deviceID, publicKey: publicKey)
        #else
        return try await client(for: mac).revokeSibling(deviceID, publicKey: publicKey)
        #endif
    }
}
