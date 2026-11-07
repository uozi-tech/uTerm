import SwiftUI

/// 打开 `uterm://pair?…` 链接（Mac 设置里「拷贝邀请链接」经隔空投送 / 信息发来的）：确认后与那台 Mac 配对。
///
/// 和扫码一样一次性、10 分钟内有效。不静默配对：先给用户看是哪台 Mac、会不会顺带导入中继。
struct RemotePairingLinkHandler: ViewModifier {
    @Environment(RemoteMacDirectory.self) private var directory
    @State private var pending: RemotePairingInvitation?
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let invitation = RemotePairingInvitation(scanned: url.absoluteString) else { return }
                pending = invitation
            }
            .alert("与「\(pending?.macName ?? "")」配对？",
                   isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("配对") {
                    if let pending {
                        if let mac = try? directory.pair(with: pending) {
                            directory.pendingOpenMacID = mac.id
                        } else {
                            failed = true
                        }
                    }
                    pending = nil
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                Text(pending.map(Self.message) ?? "")
            }
            .alert("无法配对", isPresented: $failed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("保存到钥匙串失败。")
            }
    }

    private static func message(_ invitation: RemotePairingInvitation) -> String {
        guard let relay = invitation.relay else {
            return String(localized: "配对后，这台手机可以控制这台 Mac。只接受你信任的人发来的邀请。")
        }
        return String(localized: "配对后，这台手机可以控制这台 Mac，并经中继「\(relay.name)」在外网连接它。只接受你信任的人发来的邀请。")
    }
}
