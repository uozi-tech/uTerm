import SwiftUI

/// 打开 `uterm://relay?…` 链接（Mac 设置里「分享到我的设备」经 AirDrop / 信息发来的）：确认后导入中继配置。
///
/// 链接里有成员密钥，所以不静默导入：先给用户看是哪台中继。
struct RemoteRelayLinkHandler: ViewModifier {
    @Environment(RemoteMacDirectory.self) private var directory
    @State private var pending: RemoteRelayConfig?
    @State private var failed = false

    func body(content: Content) -> some View {
        content
            .onOpenURL { url in
                guard let config = RemoteRelayConfig(scanned: url.absoluteString) else { return }
                pending = config
            }
            .alert("导入中继？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
                Button("导入") {
                    if let pending, !directory.importRelayConfig(pending) { failed = true }
                    pending = nil
                }
                Button("取消", role: .cancel) { pending = nil }
            } message: {
                Text(pending.map { String(localized: "「\($0.name)」（\($0.endpointDescription)）。导入后，不在同一网络时也能连接已允许这台手机的 Mac。只导入你自己部署的中继。") } ?? "")
            }
            .alert("无法导入中继", isPresented: $failed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("保存到钥匙串失败。")
            }
    }
}
