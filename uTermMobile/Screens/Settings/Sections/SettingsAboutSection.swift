import SwiftUI

/// 设置 › 关于：同步诊断入口 + 版本。（网络诊断在「远程控制」。）
struct SettingsAboutSection: View {
    let syncDiagnosticsSubtitle: String
    let showSyncDiagnostics: () -> Void

    var body: some View {
        MInsetGroup(header: "关于") {
            MInsetRow(icon: "icloud", label: "同步诊断", sub: syncDiagnosticsSubtitle,
                      chevron: true, onTap: showSyncDiagnostics)
            MInsetRow(label: "版本", value: Self.appVersion, last: true)
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
