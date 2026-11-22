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
        devices.isEmpty ? nil : String(localized: "已连接：\(devices.joined(separator: String(localized: "、", comment: "并列设备名之间的分隔符")))")
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
        case .ok: return .badge(symbol: "checkmark.circle.fill", tone: .success, label: String(localized: "正常", comment: "本机终端辅助程序状态"))
        case .failed: return .badge(symbol: "exclamationmark.triangle.fill", tone: .danger, label: String(localized: "无法连接", comment: "本机终端辅助程序状态"))
        }
    }

    static func helperHint(_ state: LocalShellService.HelperState) -> String {
        switch state {
        case .failed(let reason): return reason
        default: return String(localized: "本机终端由 uTerm 内置的辅助程序启动（不受 App 沙盒限制，才能读写你的主目录），用到时自动运行，不需要额外授权。")
        }
    }

    // MARK: - 公网接入

    static func relayHint(_ config: RemoteRelayConfig?) -> String {
        if let config {
            return String(localized: "\(config.name)（\(config.endpointDescription)）。这份配置含成员密钥，二维码只给自己的设备扫。")
        }
        return String(localized: "跨网络控制需要在你自己的主机上运行中继：可以让 AI 经 uterm 技能装到已保存的主机上，或导入 uterm-relay 生成的配置文件。")
    }

    /// 已配中继那一行的副标题：名字 · 地址 · 版本（知道时）。
    static func relaySubtitle(_ config: RemoteRelayConfig, version: String?) -> String {
        var parts = [config.name, config.endpointDescription]
        if let version { parts.append("v\(version)") }
        return parts.joined(separator: " · ")
    }

    static func relayUpdateHint(running: String?, host: String?) -> String {
        switch (running, host) {
        case let (running?, host?):
            return String(localized: "正在运行 \(running)。会在「\(host)」上下载、校验后替换并重启，新版本起不来会自动换回。")
        case let (nil, host?):
            return String(localized: "会在「\(host)」上下载、校验后替换并重启，新版本起不来会自动换回。")
        case let (running?, nil):
            return String(localized: "正在运行 \(running)。尚未指定中继所在的主机：在「更多操作」菜单里选「指定所在主机…」，或让 AI 更新。")
        case (nil, nil):
            return String(localized: "尚未指定中继所在的主机：在「更多操作」菜单里选「指定所在主机…」，或让 AI 更新。")
        }
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
        let tcp = mark(result.tcp), auth = mark(result.auth), udp = mark(result.udp)
        let summary: String
        if let rtt = result.rttMs {
            summary = String(localized: "TCP \(tcp)   认证 \(auth)   UDP \(udp)   往返 \(String(rtt)) ms", comment: "中继测试结果：每项后面是 ✓ / ✗ / –")
        } else {
            summary = String(localized: "TCP \(tcp)   认证 \(auth)   UDP \(udp)", comment: "中继测试结果：每项后面是 ✓ / ✗ / –")
        }
        let tone: SettingsTone = !result.isUsable ? .danger : (result.udp == .ok ? .success : .warning)
        return [Note(tone: tone, text: summary)] + result.problems.map { Note(tone: .warning, text: $0) }
    }

    /// `state == nil` 表示中继连接还没建出来（刚打开开关），按「正在连接」显示。
    static func relayStatusLabel(_ state: RemoteRelayHostLink.State?) -> String {
        switch state {
        case .registered: return String(localized: "已连接中继")
        case .connecting, .none: return String(localized: "正在连接")
        case .failed: return String(localized: "无法连接")
        case .superseded: return String(localized: "被其他设备顶替")
        case .stopped: return String(localized: "已停止", comment: "中继连接状态")
        }
    }

    static func relayStatusHint(_ state: RemoteRelayHostLink.State?) -> String? {
        switch state {
        case .failed(let message): return message
        case .superseded: return String(localized: "另一台机器用这台 Mac 的身份注册了中继。稍后会自动再试，也可以现在重新连接。")
        default: return nil
        }
    }

    /// 这个 uTerm 不注册中继（开发构建 / 测试宿主）：设置页公网区顶上那一行。
    static func relayRegistrationBlockLabel(_ block: RemoteRelayRegistrationBlock) -> String {
        switch block {
        case .developmentBuild: return String(localized: "开发构建，不注册")
        case .testHost: return String(localized: "测试宿主，不注册")
        }
    }

    static func relayRegistrationBlockHint(_ block: RemoteRelayRegistrationBlock) -> String {
        switch block {
        case .developmentBuild:
            return String(localized: "这个 uTerm 不在「应用程序」文件夹里，不会以这台 Mac 的身份注册中继，以免顶替已安装的 uTerm。")
        case .testHost:
            return String(localized: "这是跑测试用的 uTerm，不连接中继，也不读写已安装的 uTerm 的远程控制设置。")
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

    /// 二维码下面的说明：邀请带不带中继，决定了对方能不能在外网配对，也要讲明中继会一起交出去。
    static func invitationCaption(relayName: String?) -> String {
        guard let relayName else {
            return String(localized: "在 iPhone / iPad 的 uTerm 主机页打开「我的 Mac › 扫码配对」扫这个二维码，或拷贝链接发给对方。这张邀请只能在同一局域网里用；打开「允许经公网接入」后重新显示，不在同一网络也能配对。")
        }
        return String(localized: "在 iPhone / iPad 的 uTerm 主机页打开「我的 Mac › 扫码配对」扫这个二维码，或拷贝链接发给对方。邀请里带着中继「\(relayName)」，不在同一网络也能配对；对方配上后可以经公网连接这台 Mac，也能使用这台中继。")
    }

    static func pairingHint(hasInvitation: Bool) -> String {
        hasInvitation
            ? String(localized: "二维码和链接 10 分钟内有效，只能用一次。")
            : String(localized: "不在同一局域网的设备用这个配对：在手机 uTerm 主机页「我的 Mac › 扫码配对」扫二维码，或把链接发给对方。")
    }
}
