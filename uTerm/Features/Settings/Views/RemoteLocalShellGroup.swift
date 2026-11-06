import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 本机终端：允许配对设备在这台 Mac 上开终端，以及辅助程序的健康检查。
struct RemoteLocalShellGroup: View {
    @Environment(RemoteControlSettings.self) private var settings
    private let shell = LocalShellService.shared

    var body: some View {
        SettingsGroup(title: "本机终端") {
            SettingsRow(label: "允许打开本机终端",
                        hint: "打开后，配对过的设备可以在这台 Mac 上新开一个终端（你的登录 shell），这台 Mac 上也会弹出对应的窗口，断开后留着可以接着用。") {
                UDToggle(Binding(get: { settings.isLocalShellEnabled }, set: { settings.isLocalShellEnabled = $0 }))
            }
            if settings.isLocalShellEnabled {
                SettingsRow(label: "辅助程序", hint: RemoteControlPresentation.helperHint(shell.helperState)) {
                    HStack(spacing: 8) {
                        helperStatus
                        UDButton(title: "检查", style: .secondary) { Task { await shell.checkHelper() } }
                    }
                }
                .task { if shell.helperState == .unknown { await shell.checkHelper() } }
            }
        }
    }

    @ViewBuilder private var helperStatus: some View {
        switch RemoteControlPresentation.helperDisplay(shell.helperState) {
        case .hidden:
            EmptyView()
        case .progress:
            ProgressView().controlSize(.small)
        case .badge(let symbol, let tone, let label):
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tone.color)
                Text(label).font(.system(size: 12.5)).foregroundStyle(UD.text)
            }
        }
    }
}
