import SwiftUI

/// 别的设备想加入你的设备组时弹的单子（组员一侧），状态同 Mac 的 `RemoteDeviceGroupPrompt`：输入它屏幕上的 6 位数
/// （输满就核对），或「拒绝」；输了之后是「正在核对…」，可以关掉、后台继续；输错了请你输新数；次数用完说一声。
/// 核对通过、请求没了就自己收起。挂在根视图上，不管你在哪一页都会弹。状态都在 `RemoteDeviceGroupService`
/// （App 在前台时一直在读名册）。
extension RemoteGroupDevice {
    /// 列表与弹窗里的图标（`MIcon` 的名字）：Mac、iPad、其余按 iPhone。
    var mGlyph: String {
        if isMac { return "mac" }
        return (model ?? name).localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }
}

struct RemoteGroupJoinHandler: ViewModifier {
    @Environment(RemoteDeviceGroupService.self) private var service

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(get: { service.pendingRequest != nil }, set: { _ in })) {
                RemoteGroupJoinSheet()
                    .presentationDetents([.medium])
                    .presentationBackground(M.canvas)
                    // 必须明确选一个：下滑关掉等于什么都没说，下一拍又会弹出来。
                    .interactiveDismissDisabled()
            }
    }
}

struct RemoteGroupJoinSheet: View {
    @Environment(RemoteDeviceGroupService.self) private var service
    @Environment(\.mAccent) private var accent
    @State private var code = ""
    /// 在验证本人 / 核对：这期间不再提交。
    @State private var submitting = false

    var body: some View {
        if let request = service.pendingRequest {
            VStack(spacing: 16) {
                MIcon(name: request.candidate.mGlyph, size: 28, color: accent)
                Text(request.status == .verifying ? RemoteDeviceGroupCopy.verifyingTitle
                                                  : RemoteDeviceGroupCopy.requestTitle(request.candidate))
                    .font(M.sans(18, weight: .bold)).foregroundStyle(M.text)
                    .multilineTextAlignment(.center)
                Text(RemoteDeviceGroupCopy.requestDetail(request))
                    .font(M.sans(13))
                    .foregroundStyle(RemoteDeviceGroupCopy.isWarning(request.status) ? M.danger : M.text3)
                    .multilineTextAlignment(.center)
                if RemoteDeviceGroupCopy.acceptsCode(request.status) {
                    MCodeField(code: $code, length: RemoteGroupJoinCrypto.codeLength, groupSize: 3,
                               isError: isWrong(request.status) && code.isEmpty) { full in
                        // 让最后一位显示出来，再验证本人、核对（`service.submit`）。验证没过单子不收，清掉输入可以重输。
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { submit(full, for: request) }
                    }
                } else if request.status == .verifying {
                    ProgressView()
                }
                Spacer(minLength: 0)
                if RemoteDeviceGroupCopy.acceptsCode(request.status) {
                    MBtn(title: String(localized: "拒绝"), kind: .secondary, full: true, height: 44) { service.reject(request) }
                } else {
                    MBtn(title: String(localized: "关闭"), kind: .secondary, full: true, height: 44) { service.hidePrompt(request) }
                }
            }
            .padding(24)
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
            // 换了一台设备、输错了要输新数：清掉上一次的。
            .onChange(of: request.id) { _, _ in code = "" }
            .onChange(of: request.status) { _, _ in code = "" }
        }
    }

    private func submit(_ full: String, for request: RemoteDeviceGroup.JoinRequest) {
        guard !submitting else { return }
        submitting = true
        Task {
            _ = await service.submit(full, for: request)
            submitting = false
            if code == full { code = "" }
        }
    }

    private func isWrong(_ status: RemoteDeviceGroup.JoinRequest.Status) -> Bool {
        if case .wrongCode = status { return true }
        return false
    }
}
