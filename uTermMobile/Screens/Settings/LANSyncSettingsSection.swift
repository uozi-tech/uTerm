import SwiftUI

/// 移动端局域网监听何时开始。
///
/// 监听（Bonjour 广播 + NWListener）会触发系统的「查找本地网络上的设备」授权。按 Apple 的
/// 做法，授权应在用户真正用到这项功能时才请求，而不是首次启动就弹：所以首次启动不监听，
/// 用户第一次在设置里看到「局域网接收」区块时才开始（此时弹授权，上下文清楚），并记下已启用，
/// 之后每次启动直接监听（授权只问一次，之后不再弹）。
enum LANSyncActivation {
    private static let activatedKey = "lanSync.receiverActivated"
    private static let pairingCodeKey = "lanSync.pairingCode"

    /// 已启用过：看到过局域网接收区块，或升级前就配过配对码（老用户不必再进一次设置）。
    static var isActivated: Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: activatedKey) { return true }
        return !(defaults.string(forKey: pairingCodeKey) ?? "").isEmpty
    }

    /// 局域网接收区块滚进可视区时调用：记下已启用，并在还没监听（或上次出错）时开始监听。
    @MainActor static func activate(_ coordinator: LANSyncCoordinator) {
        UserDefaults.standard.set(true, forKey: activatedKey)
        switch coordinator.status {
        case .stopped, .error: coordinator.start()
        default: break
        }
    }
}

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
                      onTap: { draftCode = ""; editingCode = true })
        }
        // 设置页是非 lazy 的 VStack，onAppear 在一进设置就触发；要的是「滚到这个区块」时才请求授权。
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            if visible { LANSyncActivation.activate(lanSync) }
        }
        .sheet(isPresented: $editingCode) {
            PairingCodeSheet(code: $draftCode, hasSavedCode: !pairingCode.isEmpty,
                             onSave: save, onClear: { save("") })
        }
        // 同步请求的确认弹窗挂在根视图（`mobileLANSyncHost()`），不在这里：
        // 用户不在设置页时也要看得到，否则 Mac 60 秒后超时，再进设置看到的是过期请求。
    }
}

extension LANSyncSettingsSection {
    private func save(_ code: String) {
        // 与 LANSyncCoordinator.setPairingCode 同一规范化：只留数字、最多 6 位。
        let normalized = MCodeField.normalize(code, length: 6)
        pairingCode = normalized
        lanSync.setPairingCode(normalized)
        editingCode = false
    }
}

/// 配对码输入弹窗：6 个输入位（MCodeField），填满即保存并收起。
private struct PairingCodeSheet: View {
    @Binding var code: String
    var hasSavedCode: Bool
    var onSave: (String) -> Void
    var onClear: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("输入配对码").font(M.sans(18, weight: .semibold)).foregroundStyle(M.text)
                Text("在 Mac 的 设置 › 高级 中查看 6 位配对码")
                    .font(M.sans(13)).foregroundStyle(M.text3)
                    .multilineTextAlignment(.center)
            }
            MCodeField(code: $code, length: 6) { full in
                // 让最后一位显示出来再收起。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onSave(full) }
            }
            HStack(spacing: 10) {
                if hasSavedCode {
                    MBtn(title: "清除配对码", kind: .dangerTint, full: true, height: 44, action: onClear)
                }
                MBtn(title: "取消", kind: .secondary, full: true, height: 44) { dismiss() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 420)
        .presentationDetents([.height(hasSavedCode ? 300 : 290)])
        .presentationSizing(.form.fitted(horizontal: false, vertical: true))
        .presentationDragIndicator(.visible)
        .presentationBackground(M.canvas)
    }
}

extension View {
    /// 局域网接收的全局入口：同步请求确认弹窗 + 回前台时重启监听。挂在根视图上。
    func mobileLANSyncHost() -> some View { modifier(MobileLANSyncHost()) }
}

private struct MobileLANSyncHost: ViewModifier {
    @Environment(LANSyncCoordinator.self) private var lanSync
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .alert("收到局域网同步请求", isPresented: pendingOfferPresented) {
                Button("拒绝", role: .cancel) { lanSync.rejectPendingSync() }
                Button("确认并覆盖", role: .destructive) { lanSync.confirmPendingSync() }
            } message: {
                Text(pendingOfferMessage)
            }
            // 退到后台后系统会让监听失效（状态转为出错 / 停止）。改前只有用户滚到设置里那一块
            // 才会重启，期间 Mac 怎么发都找不到这台手机。已启用过的回前台就重新监听。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, LANSyncActivation.isActivated else { return }
                switch lanSync.status {
                case .stopped, .error: lanSync.start()
                default: break
                }
            }
    }

    private var pendingOfferPresented: Binding<Bool> {
        Binding(get: { lanSync.pendingOffer != nil }, set: { visible in
            if !visible, lanSync.pendingOffer != nil { lanSync.rejectPendingSync() }
        })
    }

    private var pendingOfferMessage: String {
        guard let offer = lanSync.pendingOffer else { return "" }
        return "设备：\(offer.deviceName)\n配置与历史记录：\(offer.recordCount) 条\n偏好设置：\(offer.preferenceCount) 项\n敏感凭据：\(offer.secretCount) 项\n\n确认后本机数据将与这台 Mac 完全一致：本机有、Mac 上没有的主机、密钥、命令与会话记录会被删除，并经 iCloud 同步到你的其他设备。"
    }
}
