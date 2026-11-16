import Foundation

// 设备组里的 Mac 把组员记成自己的主控端（docs/remote-device-group-design.md §7.3「组里的 Mac 互认」）：
// 设备组的模型在 App 里经这一层读、写这台 Mac 的被控端信任表。只编进 Mac 主程序：远控进程不读名册、
// 也不编这个文件（它收的是 `RemoteHostAgentCommand.groupAddController` / `groupDropController`），iOS 没有被控端。

extension RemoteHostServer: RemoteGroupLocalHost {
    var acceptsGroupControllers: Bool { groupControllerPolicy() }

    func groupControllerPeers() -> [RemoteGroupLocalController] {
        // 远控进程在服务时，它写回的信任表与担保记录已经落进 App 的钥匙串（`agentPersistedIdentity`）：直接读。
        let vouches = identity.vouches()
        return identity.trustedPeers().map { peer in
            let vouch = vouches[peer.id]
            return RemoteGroupLocalController(id: peer.id, publicKey: peer.publicKey, isVouched: vouch != nil,
                                              isFromGroup: vouch?.isFromDeviceGroup(hostID: localID) ?? false,
                                              vouchedBy: vouch?.vouchedBy)
        }
    }

    func isControllerBlocked(_ id: UUID) -> Bool {
        identity.isBlocked(id)
    }

    func addGroupController(_ device: RemoteGroupDevice) async -> RemoteVouchResult? {
        await groupAddController(RemoteVouchRequest(requestID: UUID(), deviceID: device.id, name: device.name,
                                                    model: device.model, platform: device.platform,
                                                    publicKey: device.publicKey))
    }

    func dropGroupController(_ id: UUID, publicKey: Data) async -> RemoteSiblingRevokeResult? {
        await groupDropController(RemoteSiblingRevokeRequest(requestID: UUID(), deviceID: id, publicKey: publicKey))
    }
}
