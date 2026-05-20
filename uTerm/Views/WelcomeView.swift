import SwiftUI

/// Welcome 窗口：服务器列表 + 增删改。点一台服务器 → 新开一个绑定该服务器的工作区窗口。
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationStack {
            ServerListView(onOpenServer: { profile in
                openWindow(value: WorkspaceWindowID(id: UUID(), serverID: profile.id))
            })
        }
        .frame(minWidth: 320, minHeight: 400)
    }
}
