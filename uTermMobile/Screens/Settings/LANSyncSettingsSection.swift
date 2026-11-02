import SwiftUI

/// 移动端局域网同步入口：移动端只监听，Mac 发起后由这里请求确认。
struct LANSyncSettingsSection: View {
    @Environment(LANSyncCoordinator.self) private var lanSync
    @AppStorage("lanSync.pairingCode") private var pairingCode = ""
    @State private var editingCode = false
    @State private var draftCode = ""

    var body: some View {
        MInsetGroup(header: "局域网接收", footer: "手机与 Mac 需连接同一 Wi-Fi。Mac 发起全量加密同步后，需在这里确认才会覆盖本机数据；密码、私钥和 API Key 会随本次加密会话传输。") {
            MInsetRow(icon: "wifi", label: "接收状态", sub: lanSync.status.label,
                      value: "前台监听", last: false)
            // 点按后在弹窗里输入：行内常驻的数字键盘没有「完成」键，聚焦后键盘关不掉（实机反馈）。
            MInsetRow(label: "配对码", sub: "输入 Mac 设置 › 高级中显示的 6 位代码",
                      value: pairingCode.isEmpty ? "未设置" : pairingCode, valueMono: !pairingCode.isEmpty,
                      chevron: true, last: true,
                      onTap: { draftCode = pairingCode; editingCode = true })
        }
        .alert("配对码", isPresented: $editingCode) {
            TextField("6 位配对码", text: $draftCode)
                .keyboardType(.numberPad)
                .font(M.mono(14))
            Button("取消", role: .cancel) {}
            Button("保存") {
                // 与 LANSyncCoordinator.setPairingCode 同一规范化：只留数字、最多 6 位。
                let code = String(draftCode.filter(\.isNumber).prefix(6))
                pairingCode = code
                lanSync.setPairingCode(code)
            }
        } message: {
            Text("输入 Mac 设置 › 高级中显示的 6 位代码")
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
