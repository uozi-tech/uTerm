import SwiftUI

/// 移动端局域网同步入口：移动端只监听，Mac 发起后由这里请求确认。
struct LANSyncSettingsSection: View {
    @Environment(LANSyncCoordinator.self) private var lanSync
    @AppStorage("lanSync.pairingCode") private var pairingCode = ""

    var body: some View {
        MInsetGroup(header: "局域网接收", footer: "手机与 Mac 需连接同一 Wi-Fi。Mac 发起全量加密同步后，需在这里确认才会覆盖本机数据；密码、私钥和 API Key 会随本次加密会话传输。") {
            MInsetRow(icon: "wifi", label: "接收状态", sub: lanSync.status.label,
                      value: "前台监听", last: false)
            MInsetRow(label: "配对码", sub: "输入 Mac 设置 › 高级中显示的 6 位代码",
                      trailing: AnyView(
                          TextField("6 位配对码", text: $pairingCode)
                              .keyboardType(.numberPad)
                              .multilineTextAlignment(.trailing)
                              .font(M.mono(14))
                              .foregroundStyle(M.text)
                              .frame(width: 110)
                              .onChange(of: pairingCode) { _, value in
                                  lanSync.setPairingCode(value)
                              }), last: true)
        }
        .alert("收到局域网同步请求", isPresented: pendingOfferPresented) {
            Button("拒绝", role: .cancel) { lanSync.rejectPendingSync() }
            Button("确认并覆盖") { lanSync.confirmPendingSync() }
        } message: {
            Text(pendingOfferMessage)
        }
    }

    private var pendingOfferPresented: Binding<Bool> {
        Binding(get: { lanSync.pendingOffer != nil }, set: { visible in
            if !visible, lanSync.pendingOffer != nil { lanSync.rejectPendingSync() }
        })
    }

    private var pendingOfferMessage: String {
        guard let offer = lanSync.pendingOffer else { return "" }
        return "设备：\(offer.deviceName)\n配置与历史记录：\(offer.recordCount) 条\n偏好设置：\(offer.preferenceCount) 项\n敏感凭据：\(offer.secretCount) 项\n确认后将用 Mac 数据覆盖本机。"
    }
}
