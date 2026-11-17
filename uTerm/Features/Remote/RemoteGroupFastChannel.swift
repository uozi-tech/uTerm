import CryptoKit
import Foundation

/// 设备组快通道（docs/remote-device-group-design.md §7.4，落地见 §16、§17）：同步层（`RemoteGroupFastSync`）加上
/// 两条线路——局域网（`RemoteGroupLANService`）与中继信箱（`RemoteGroupRelayService`）。两条都把握好手的
/// `RemoteGroupPeerLink` 交给 `sync.add`；同一台对端两条都通时同步层留局域网，局域网断了中继那边马上补拨。
///
/// 由 `RemoteDeviceGroupService` 持有、跟着它起停（Mac 上 App 开着就开，iOS 只在前台）。本机没有远控身份、
/// 名册不是叠加层、测试宿主里都不开（`live` 返回 nil）。
nonisolated final class RemoteGroupFastChannel: @unchecked Sendable {
    let sync: RemoteGroupFastSync
    let lan: RemoteGroupLANService
    let relay: RemoteGroupRelayService?

    /// 同步层的「线路断了」要转给中继服务，而中继服务又要问同步层「连着什么」：先建一个空的引用，建好中继再填上。
    private final class RelayReference: @unchecked Sendable {
        weak var service: RemoteGroupRelayService?
    }

    init(local: RemoteGroupDevice, identityKey: Curve25519.KeyAgreement.PrivateKey, overlay: RemoteGroupOverlayStorage,
         advertises: Bool = true, browses: Bool = true, relay relayOptions: RemoteGroupRelayService.Options? = nil,
         syncCoalesceDelay: TimeInterval = RemoteGroupFastSync.coalesceDelay,
         syncInterval: TimeInterval = RemoteGroupFastSync.syncInterval,
         onReceive: @escaping @Sendable (RemoteGroupFastSync.Received) -> Void) {
        let reference = RelayReference()
        let sync = RemoteGroupFastSync(overlay: overlay, coalesceDelay: syncCoalesceDelay, syncInterval: syncInterval,
                                       onLinkClosed: { peer, _ in reference.service?.linkLost(peer) },
                                       onReceive: onReceive)
        self.sync = sync
        // 只认钥匙串名册里的设备：叠加层收到的 `device` 记录不给人进快通道的资格。
        let trusted: @Sendable () -> [RemoteGroupDevice] = { overlay.baseDevices() }
        lan = RemoteGroupLANService(local: local, identityKey: identityKey, trusted: trusted,
                                    advertises: advertises, browses: browses) { [weak sync] link in
            guard let sync else { return link.close() }
            sync.add(link)
        }
        relay = relayOptions.map { options in
            RemoteGroupRelayService(local: local, identityKey: identityKey, trusted: trusted, options: options,
                                    hasPreferredLink: { [weak sync] peer in
                                        guard let kind = sync?.linkKind(for: peer) else { return false }
                                        return kind.priority > RemoteGroupLinkKind.relay.priority
                                    }) { [weak sync] link in
                guard let sync else { return link.close() }
                sync.add(link)
            }
        }
        reference.service = relay
    }

    /// App 里用的那一份：模型的名册是叠加层、本机有远控私钥、不是测试宿主时才有。
    @MainActor
    static func live(for model: RemoteDeviceGroup,
                     onReceive: @escaping @Sendable (RemoteGroupFastSync.Received) -> Void) -> RemoteGroupFastChannel? {
        guard !RemoteLocalState.isIsolated, let identityKey = model.identityKey,
              let overlay = model.roster.storage as? RemoteGroupOverlayStorage else { return nil }
        return RemoteGroupFastChannel(local: model.local, identityKey: identityKey, overlay: overlay, relay: .live(),
                                      onReceive: onReceive)
    }

    func start() {
        lan.start()
        relay?.start()
    }

    /// 先关同步层和它手里的线路（中继线路借着还在的控制连接告诉对端；同步层停了，局域网断开也不会叫中继补拨），
    /// 再关两条线路的服务。
    func stop() {
        sync.stop()
        lan.stop()
        relay?.stop()
    }
}
