import Foundation

// 组里的 Mac 互认（docs/remote-device-group-design.md §7.3「组里的 Mac 互认」，决定 2）。只在本机是 Mac、
// 服务交进了它自己的被控端（`localHost`）时做，每轮一步：
//
// 1. 撤：本机信任的主控端里，经担保记下的（设备组或别的设备担保的）、钥匙就是被移除的组员的，不拉黑地撤掉；
//    本机不在组里了（离开了），设备组记下的都撤掉。Mac 主人在这台 Mac 上手动配对的不动。撤先于记。
// 2. 记：本机开着被控和「允许担保」、在组里时，组里每台别的组员都记成主控端（担保者记成本机，设置里显示
//    「由设备组添加」）；Mac 主人撤销过（拉黑）的不加。记下了（或早就认识）就写一条本机签的 `grant`
//    （签名者就是这台 Mac），对方照 §7.2 收下这台 Mac。
//
// 规则在被控端（`RemoteHostServer.handleGroupController`，同担保：已认识的公钥不同不替换、拉黑的不加、公网接入
// 照新配对设备的默认值）。远控进程在服务时由 `RemoteHostServer` 经 XPC 转过去，远控进程不读名册。
// 和问别的 Mac 共用「每台 Mac 一次一个请求」（这台 Mac 自己的 ID 当那一格）。

extension RemoteDeviceGroup {
    /// 这台 Mac 写进自己签的 `grant` 的公开信息。
    var localHostInfo: RemoteGroupHostInfo {
        RemoteGroupHostInfo(id: local.id, name: local.name, publicKey: local.publicKey, model: local.model,
                            platform: RemoteDevicePlatform.mac.rawValue)
    }

    func syncLocalHost(_ snapshot: RemoteGroupSnapshot, _ state: RemoteGroupLocalState) {
        guard let localHost, local.isMac, !vouches.isAsking(local.id), !isCoolingDown(local.id) else { return }
        let peers = localHost.groupControllerPeers()
        if let drop = peers.first(where: { shouldDrop($0, state) }) {
            startLocalDrop(drop, localHost: localHost)
            return
        }
        guard localHost.acceptsGroupControllers, !state.members.isEmpty else { return }
        let trusted = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let mine = snapshot.grants.filter {
            $0.signer == local.id && $0.signerKey == local.signingKey && $0.isAbout(local.id, key: local.publicKey)
        }
        let members = state.members.sorted {
            ($0.admission.admittedAt, $0.device.id.uuidString) > ($1.admission.admittedAt, $1.device.id.uuidString)
        }
        for member in members {
            let device = member.device
            guard device.id != local.id, !hasTwin(member, in: state), !localHost.isControllerBlocked(device.id) else { continue }
            if let asked = lastAsked[Self.askKey(device, local.id)] {
                let age = now().timeIntervalSince(asked)
                if age >= 0, age < Self.vouchRetryInterval { continue }
            }
            let own = mine.filter { $0.isFor(device) }
            if let peer = trusted[device.id] {
                // 记着另一把钥匙（你在这台 Mac 上手动配对过它重装之前的那一份）：不替换，要在 Mac 上处理。
                guard peer.publicKey == device.publicKey else { continue }
                if own.contains(where: \.isUsable) { continue }
            } else if own.contains(where: { $0.isFinal && !$0.isUsable }) {
                continue
            }
            startLocalAdd(device, localHost: localHost)
            return
        }
    }

    /// 要撤的主控端：经担保记下的、钥匙是被移除的设备的（还在组里的不算：重新加入后同一把钥匙又是组员）；
    /// 本机不在组里了时，设备组记下的都撤。
    private func shouldDrop(_ peer: RemoteGroupLocalController, _ state: RemoteGroupLocalState) -> Bool {
        guard peer.isVouched else { return false }
        if state.members.contains(where: { $0.device.id == peer.id && $0.device.publicKey == peer.publicKey }) { return false }
        if state.removals.contains(where: { $0.deviceID == peer.id && $0.publicKey == peer.publicKey }) { return true }
        return peer.isFromGroup && state.members.isEmpty
    }

    /// 本机签的、对组员的结果已经不对了：说它能用，但本机此刻不认它，而且你在这台 Mac 上撤销过它（拉黑）。
    func isStaleLocalGrant(_ grant: RemoteGroupHostGrant) -> Bool {
        guard let localHost, grant.isUsable, localHost.isControllerBlocked(grant.deviceID) else { return false }
        return !localHost.groupControllerPeers().contains { $0.id == grant.deviceID && $0.publicKey == grant.publicKey }
    }

    private func startLocalDrop(_ peer: RemoteGroupLocalController, localHost: any RemoteGroupLocalHost) {
        let token = UUID()
        let hostID = local.id
        let task = Task { [weak self] in
            let result = await localHost.dropGroupController(peer.id, publicKey: peer.publicKey)
            guard let self, self.vouches.finish(hostID, token: token), !Task.isCancelled else { return }
            if result == nil {
                // 转不到远控进程：过一分钟再试。
                self.hostFailures[hostID] = self.now()
                return
            }
            AppLogger.notice("设备组：本机撤掉被移除的主控端 \(peer.id.uuidString.prefix(8))：\(result?.outcome ?? "")",
                             category: RemoteLog.category)
            self.refresh()
        }
        vouches.start(hostID, token: token, at: now(), task: task)
    }

    private func startLocalAdd(_ device: RemoteGroupDevice, localHost: any RemoteGroupLocalHost) {
        let token = UUID()
        let hostID = local.id
        let task = Task { [weak self] in
            let result = await localHost.addGroupController(device)
            guard let self, self.vouches.finish(hostID, token: token), !Task.isCancelled else { return }
            self.finishLocalAdd(device, result)
        }
        vouches.start(hostID, token: token, at: now(), task: task)
        AppLogger.info("设备组：把「\(device.name)」记成本机的主控端", category: RemoteLog.category)
    }

    private func finishLocalAdd(_ device: RemoteGroupDevice, _ result: RemoteVouchResult?) {
        guard let result else {
            // 远控进程不在、或版本太旧不认这个操作：过一分钟再试。
            hostFailures[local.id] = now()
            AppLogger.info("设备组：没能把「\(device.name)」记成本机的主控端（远控进程不在或太旧）", category: RemoteLog.category)
            return
        }
        hostFailures[local.id] = nil
        lastAsked[Self.askKey(device, local.id)] = now()
        guard let state = loadState(), !state.selfRemoved,
              let member = state.members.first(where: { $0.device.sameKeys(as: device) }) else { return }
        var box: Data?
        if let relay = result.relay, let identityKey {
            box = try? RemoteGroupRelaySeal.seal(relay, key: RemoteGroupRelaySeal.key(local: identityKey,
                                                                                      remote: member.device.publicKey),
                                                 signer: local.id, target: member.device.id, host: local.id)
        }
        let joinedAt = state.selfAdmission?.admittedAt ?? .distantPast
        do {
            try roster.save(.grant(try RemoteGroupHostGrant.make(device: member.device, host: localHostInfo,
                                                                 outcome: result.outcome, reason: result.reason,
                                                                 internetAccess: result.internetAccess, relay: box,
                                                                 signer: local, signedAt: max(RemoteGroupTime(now()), joinedAt),
                                                                 key: signingKey)))
        } catch {
            fail(error)
            hostFailures[local.id] = now()
            return
        }
        AppLogger.notice("设备组：本机对「\(device.name)」的结果 \(result.outcome)", category: RemoteLog.category)
        refresh()
    }
}
