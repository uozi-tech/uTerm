import Foundation

/// 远程桌面工具栏上的扬声器按钮（手机与 Mac 主控端共用）：开关声音，并按那台 Mac 记住选择，下次看它时照样打开。
extension RemoteDesktopSession {
    /// 按钮显示为「开着」：正在打开或正在放。
    var isAudioOn: Bool {
        switch audioState {
        case .starting, .playing: return true
        case .off, .unavailable: return false
        }
    }

    /// 按钮点一下：翻转声音，记住这台 Mac 的选择。本机播放打不开时 `setAudio` 自己复位、不叫 Mac 开声音，
    /// 这里照样记成「要声音」——下次换个能放的输出设备还会自动打开，本次的原因由 `audioState` 交给界面提示。
    func toggleAudio(defaults: UserDefaults = RemoteLocalState.defaults) {
        // 老 Mac 不报 `desktop-audio` 时按钮不显示；万一被调到也别记下一个那台 Mac 给不了的选择。
        guard supportsAudio else { return }
        let on = !isAudioOn
        setAudio(on)
        if let mac = client.macDeviceID { RemoteDesktopAudioPreference.setWantsAudio(on, mac: mac, defaults: defaults) }
    }

    /// 开流成功后：上次看这台 Mac 时开着声音就照样打开。
    func restoreAudioIfWanted(defaults: UserDefaults = RemoteLocalState.defaults) {
        guard supportsAudio, audioState == .off, let mac = client.macDeviceID,
              RemoteDesktopAudioPreference.wantsAudio(mac: mac, defaults: defaults) else { return }
        setAudio(true)
    }}
