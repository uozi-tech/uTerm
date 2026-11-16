import Foundation
import UserNotifications

/// 有设备经担保被这台 Mac 记下时发一条通知：Mac 的主人可能不是担保者本人，要让他知道、撤得掉。
enum RemoteVouchNotifier {
    /// `hostID` 是这台 Mac 的设备 ID：担保者就是它时是设备组记下的（`RemotePeerVouch.isFromDeviceGroup`）。
    static func post(_ vouch: RemotePeerVouch, hostID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = vouch.isFromDeviceGroup(hostID: hostID)
            ? String(localized: "设备组里的「\(vouch.deviceName)」现在可以远程控制这台 Mac")
            : String(localized: "「\(vouch.voucherName)」为「\(vouch.deviceName)」开通了远程控制")
        content.body = String(localized: "「\(vouch.deviceName)」现在可以连接这台 Mac。不认识的话，到「设置 › 远程控制 › 已配对的设备」里撤销它。")
        let request = UNNotificationRequest(identifier: "remote.vouch.\(vouch.deviceID.uuidString)", content: content,
                                            trigger: nil)
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
            try? await center.add(request)
        }
    }
}
