import SwiftUI

/// 设置 › 关于：版本。（同步诊断已归「同步」，网络诊断已归「远程控制」。）
struct SettingsAboutSection: View {
    var body: some View {
        MInsetGroup(header: "关于") {
            MInsetRow(label: "版本", value: Self.appVersion, last: true)
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
