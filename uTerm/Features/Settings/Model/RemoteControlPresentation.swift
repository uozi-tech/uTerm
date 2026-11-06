import Foundation

/// 设置 › 远程控制里各项状态的文案、图标与色调（只有 macOS 有这一页：输入的
/// `RemoteHostServer` / `RemoteRelayHostLink` / `LocalShellService` 都是 mac 专属，
/// 本文件因此也是 mac-only）。从视图里拿出来是为了能单测。
enum RemoteControlPresentation {
    // MARK: - 总开关的状态行

    static func serverStatus(_ status: RemoteHostServer.Status,
                             hasConnectedDevices: Bool) -> (symbol: String, tone: SettingsTone) {
        switch status {
        case .listening:
            return (hasConnectedDevices ? "iphone.radiowaves.left.and.right" : "dot.radiowaves.left.and.right",
                    .active)
        case .stopped:
            return ("pause.circle", .neutral)
        case .failed:
            return ("exclamationmark.triangle.fill", .danger)
        }
    }

    static func connectedHint(_ devices: [String]) -> String? {
        devices.isEmpty ? nil : "已连接：\(devices.joined(separator: "、"))"
    }

    // MARK: - 本机终端的辅助程序

    /// 辅助程序状态的展示形态：查过之前不显示、查的时候转圈、查完给结论。
    enum HelperDisplay: Equatable {
        case hidden
        case progress
        case badge(symbol: String, tone: SettingsTone, label: String)
    }

    static func helperDisplay(_ state: LocalShellService.HelperState) -> HelperDisplay {
        switch state {
        case .unknown: return .hidden
        case .checking: return .progress
        case .ok: return .badge(symbol: "checkmark.circle.fill", tone: .success, label: "正常")
        case .failed: return .badge(symbol: "exclamationmark.triangle.fill", tone: .danger, label: "连不上")
        }
    }

    static func helperHint(_ state: LocalShellService.HelperState) -> String {
        switch state {
        case .failed(let reason): return reason
        default: return "本机终端由 uTerm 内置的辅助程序启动（不受 App 沙盒限制，才能读写你的主目录），用到时自动运行，不需要额外授权。"
        }
    }

    // MARK: - 公网接入

    static func relayHint(_ config: RemoteRelayConfig?) -> String {
        if let config {
            return "\(config.name)（\(config.endpointDescription)）。这份配置含成员密钥，二维码只给自己的设备扫。"
        }
        return "跨网络控制需要一台你自己的服务器，部署方法见 relay/README.md。配置文件由 uterm-relay config 生成。"
    }

    /// `state == nil` 表示中继连接还没建出来（刚打开开关），按「正在连接」显示。
    static func relayStatusLabel(_ state: RemoteRelayHostLink.State?) -> String {
        switch state {
        case .registered: return "已连接中继"
        case .connecting, .none: return "正在连接"
        case .failed: return "连不上"
        case .superseded: return "被其他设备顶替"
        case .stopped: return "已停止"
        }
    }

    static func relayStatusHint(_ state: RemoteRelayHostLink.State?) -> String? {
        switch state {
        case .failed(let message): return message
        case .superseded: return "另一台机器用这台 Mac 的身份注册了中继，这里不再自动重连。"
        default: return nil
        }
    }

    static func relayStatus(_ state: RemoteRelayHostLink.State?) -> (symbol: String, tone: SettingsTone) {
        switch state {
        case .registered: return ("checkmark.circle.fill", .success)
        case .failed, .superseded: return ("exclamationmark.triangle.fill", .danger)
        default: return ("arrow.triangle.2.circlepath", .neutral)
        }
    }

    // MARK: - 配对

    static func pairingHint(hasInvitation: Bool) -> String {
        hasInvitation
            ? "二维码 10 分钟内有效，只能用一次。"
            : "不同 Apple ID 的 iPhone / iPad 用这个配对：在手机 uTerm 主机页「我的 Mac › 扫码配对」扫二维码。"
    }
}
