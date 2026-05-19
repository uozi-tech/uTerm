import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedProfile: ServerProfile?

    var body: some View {
        NavigationSplitView {
            ServerListView(selection: $selectedProfile)
                .frame(minWidth: 200)
        } detail: {
            if let profile = selectedProfile {
                TerminalPaneView(profile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView(
                    "未选择服务器",
                    systemImage: "terminal",
                    description: Text("从左侧选择一台服务器以建立连接")
                )
            }
        }
        .navigationTitle(selectedProfile?.name ?? "uTerm")
    }
}
