import CryptoKit
import Foundation

/// 设备组快通道（docs/remote-device-group-design.md §7.4，落地见 §16）：同步层（`RemoteGroupFastSync`）加上各条线路。
/// G4a 只有局域网（`RemoteGroupLANService`）；G4b 的中继信箱另起一个服务，把握好手的 `RemoteGroupPeerLink`
/// 一样交给 `sync.add`。
///
/// 由 `RemoteDeviceGroupService` 持有、跟着它起停（Mac 上 App 开着就开，iOS 只在前台）。本机没有远控身份、
/// 名册不是叠加层、测试宿主里都不开（`live` 返回 nil）。
nonisolated final class RemoteGroupFastChannel: @unchecked Sendable {
    let sync: RemoteGroupFastSync
    let lan: RemoteGroupLANService

    init(local: RemoteGroupDevice, identityKey: Curve25519.KeyAgreement.PrivateKey, overlay: RemoteGroupOverlayStorage,
         advertises: Bool = true, browses: Bool = true,
         onReceive: @escaping @Sendable (RemoteGroupFastSync.Received) -> Void) {
        let sync = RemoteGroupFastSync(overlay: overlay, onReceive: onReceive)
        self.sync = sync
        // 只认钥匙串名册里的设备：叠加层收到的 `device` 记录不给人进快通道的资格。
        lan = RemoteGroupLANService(local: local, identityKey: identityKey, trusted: { overlay.baseDevices() },
                                    advertises: advertises, browses: browses) { [weak sync] link in
            guard let sync else { return link.close() }
            sync.add(link)
        }
    }

    /// App 里用的那一份：模型的名册是叠加层、本机有远控私钥、不是测试宿主时才有。
    @MainActor
    static func live(for model: RemoteDeviceGroup,
                     onReceive: @escaping @Sendable (RemoteGroupFastSync.Received) -> Void) -> RemoteGroupFastChannel? {
        guard !RemoteLocalState.isIsolated, let identityKey = model.identityKey,
              let overlay = model.roster.storage as? RemoteGroupOverlayStorage else { return nil }
        return RemoteGroupFastChannel(local: model.local, identityKey: identityKey, overlay: overlay, onReceive: onReceive)
    }

    func start() {
        lan.start()
    }

    func stop() {
        lan.stop()
        sync.stop()
    }
}
