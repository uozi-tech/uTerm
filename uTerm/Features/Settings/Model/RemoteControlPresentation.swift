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
        case .failed: return .badge(symbol: "exclamationmark.triangle.fill", tone: .danger, label: "无法连接")
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
        return "跨网络控制需要在你自己的主机上运行中继：可以让 AI 经 uterm 技能装到已保存的主机上，或导入 uterm-relay 生成的配置文件。"
    }

    /// 已配中继那一行的副标题：名字 · 地址 · 版本（知道时）。
    static func relaySubtitle(_ config: RemoteRelayConfig, version: String?) -> String {
        var parts = [config.name, config.endpointDescription]
        if let version { parts.append("v\(version)") }
        return parts.joined(separator: " · ")
    }

    static func relayUpdateHint(running: String?, host: String?) -> String {
        let current = running.map { String(localized: "正在运行 \($0)。") } ?? ""
        if let host {
            return current + String(localized: "会在「\(host)」上下载、校验后替换并重启，新版本起不来会自动换回。")
        }
        return current + String(localized: "尚未指定中继所在的主机：在「更多操作」菜单里选「指定所在主机…」，或让 AI 更新。")
    }

    struct Note: Equatable {
        let tone: SettingsTone
        let text: String
    }

    static func relayUpdateNote(_ phase: RemoteRelayManager.UpdatePhase) -> Note? {
        switch phase {
        case .idle: return nil
        case .running: return Note(tone: .muted, text: String(localized: "正在更新中继…"))
        case .finished(let text): return Note(tone: .success, text: text)
        case .openedTerminal:
            return Note(tone: .warning, text: String(localized: "这台主机的 sudo 需要密码，已打开终端窗口运行更新命令，在那里输入密码。"))
        case .failed(let text): return Note(tone: .danger, text: String(localized: "更新失败：\(text)"))
        }
    }

    /// 测试结果：一行总评，再逐条列问题。
    static func relayCheckNotes(_ result: RemoteRelayCheckResult) -> [Note] {
        func mark(_ outcome: RemoteRelayCheckResult.Outcome) -> String {
            switch outcome {
            case .ok: return "✓"
            case .failed: return "✗"
            case .skipped: return "–"
            }
        }
        var summary = "TCP \(mark(result.tcp))   认证 \(mark(result.auth))   UDP \(mark(result.udp))"
        if let rtt = result.rttMs { summary += String(localized: "   往返 \(String(rtt)) ms") }
        let tone: SettingsTone = !result.isUsable ? .danger : (result.udp == .ok ? .success : .warning)
        return [Note(tone: tone, text: summary)] + result.problems.map { Note(tone: .warning, text: $0) }
    }

    /// `state == nil` 表示中继连接还没建出来（刚打开开关），按「正在连接」显示。
    static func relayStatusLabel(_ state: RemoteRelayHostLink.State?) -> String {
        switch state {
        case .registered: return "已连接中继"
        case .connecting, .none: return "正在连接"
        case .failed: return "无法连接"
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
            : "手机不在同一局域网时用这个配对：在手机 uTerm 主机页「我的 Mac › 扫码配对」扫二维码。"
    }
}
