import SwiftUI

/// 在远程 Mac 上新建终端前怎么办（两端共用）：Mac 有最近的工作区就先问开在哪，没有就直接开。
nonisolated enum RemoteNewShellPlan: Equatable, Sendable {
    /// 先问：主目录 + 这些最近的工作区。
    case ask(RemoteLocalWorkspaces)
    /// 直接开在主目录（Mac 没有最近的工作区，或版本太旧不报）。
    case openDirectly

    init(_ workspaces: RemoteLocalWorkspaces?) {
        if let workspaces, !workspaces.directories.isEmpty {
            self = .ask(workspaces)
        } else {
            self = .openDirectly
        }
    }
}

extension RemoteMacClient {
    /// 新建终端前问一次 Mac 最近的工作区（要先连上，这段时间界面显示「正在打开…」）。
    func newShellPlan() async -> RemoteNewShellPlan {
        RemoteNewShellPlan(await localWorkspaces())
    }
}

extension View {
    /// 在 Mac 上新开终端前问开在哪（`RemoteNewShellPlan.ask`）。要挂在触发它的控件上：iPad 宽屏下它是 popover，
    /// 箭头指向所挂的视图。
    func macWorkspaceDialog(_ choices: Binding<RemoteLocalWorkspaces?>,
                            onPick: @escaping (_ directory: String?) -> Void) -> some View {
        confirmationDialog("在哪个目录打开？",
                           isPresented: Binding(get: { choices.wrappedValue != nil },
                                                set: { if !$0 { choices.wrappedValue = nil } }),
                           titleVisibility: .visible,
                           presenting: choices.wrappedValue) { workspaces in
            Button("主目录") { onPick(nil) }
            ForEach(workspaces.directories, id: \.self) { directory in
                Button(RemoteLocalWorkspaces.displayPath(directory, home: workspaces.home)) { onPick(directory) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
