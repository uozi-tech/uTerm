import SwiftUI

/// 设置 › 远程控制：网络诊断入口与「只走公网」开发者选项。
struct SettingsRemoteSection: View {
    @Environment(RemoteMacDirectory.self) private var remoteMacs

    var body: some View {
        MInsetGroup(header: "远程控制",
                    footer: "「只走公网」打开后，即使 Mac 就在同一个局域网里，连接也经中继或打洞，用来在家里复现外出时的情况。"
                        + "切换后马上断开现有连接、按新的路重连。网络诊断不受它影响。") {
            NavigationLink { RemoteNetworkDiagnosticsScreen() } label: {
                MInsetRow(icon: "globe", label: "网络诊断", chevron: true)
            }
            .buttonStyle(MRowStyle())
            MInsetRow(icon: "forward", label: "只走公网", last: true,
                      trailing: AnyView(MSwitch(on: Binding(get: { remoteMacs.internetOnly },
                                                            set: { remoteMacs.internetOnly = $0 }))))
        }
    }
}
