import SwiftUI

/// 设置 › 远程控制：网络诊断（中继与直连链路）与「只走公网」开发者选项。
/// 控制 Mac 本身从主机页「我的 Mac」发起。
///
/// 「只走公网」走 `RemoteMacDirectory.internetOnly`（它负责落盘、断开现有连接并按新的路重连），
/// 不直接写 `DefaultsKey.remoteInternetOnly`。
struct SettingsRemoteSection: View {
    @Environment(RemoteMacDirectory.self) private var remoteMacs

    var body: some View {
        MInsetGroup(header: "远程控制",
                    footer: "「只走公网」打开后，即使 Mac 就在同一个局域网里，连接也经中继或打洞，用来在家里复现外出时的情况。"
                        + "切换后立即断开现有连接，并按新设置重新连接。网络诊断不受它影响。") {
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
