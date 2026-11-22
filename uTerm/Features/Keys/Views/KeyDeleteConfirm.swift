import UDesignKit
import SwiftUI

/// 删除密钥的确认弹层（设计稿 `keys.jsx` 的 `KeyDeleteConfirm`），提示受影响主机数。
struct KeyDeleteConfirm: View {
    let key: SSHKey
    let hostCount: Int
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        UDConfirmModal(title: String(localized: "删除密钥「\(key.name)」？"), width: 400,
                       onCancel: onCancel, onConfirm: onConfirm) {
            Text(message)
        }
    }

    private var message: String {
        if hostCount > 0 {
            return String(localized: "使用此密钥的 \(hostCount) 台主机将无法连接。此操作无法撤销。")
        }
        return String(localized: "此密钥未被任何主机使用。此操作无法撤销。")
    }
}
