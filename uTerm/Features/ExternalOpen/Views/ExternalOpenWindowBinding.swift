import SwiftUI

/// 窗口级的「打开 / 下载…」接线（工作区窗口与独立 SFTP 窗口共用）：
/// - 接 `.remoteFileCommand`（预览区、预览标签右键发出；只在 key window 上执行）；
/// - 右下角挂 toast / 同步芯片浮层；
/// - 关窗前检查没上传的改动（`ExternalEditCloseGuardInstaller`）。
///
/// 抽成独立 ViewModifier —— 内联进 `WorkspaceWindowView.body` 会把它推过类型检查上限。
struct ExternalOpenWindowBinding: ViewModifier {
    /// 当前窗口负责执行命令、显示浮层的那一份（独立 SFTP 窗口 = 活动标签的）。
    let coordinator: ExternalOpenCoordinator
    /// 「下载…」进哪条传输队列。
    let fileBrowserModel: FileBrowserModel
    /// 关窗时要检查的全部（独立 SFTP 窗口 = 所有标签的）。
    let allCoordinators: () -> [ExternalOpenCoordinator]
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content
            .overlay { ExternalOpenOverlay(coordinator: coordinator) }
            .background(ExternalEditCloseGuardInstaller(coordinators: allCoordinators))
            .onReceive(NotificationCenter.default.publisher(for: .remoteFileCommand)) { note in
                // 通知广播到所有窗口，只让发起操作的前台窗口处理。
                guard controlActiveState == .key,
                      let command = note.userInfo?[RemoteFileCommand.userInfoKey] as? RemoteFileCommand
                else { return }
                switch command {
                case .open(let path, let route):
                    Task { await coordinator.open(remotePath: path, route: route) }
                case .download(let path, let size):
                    RemoteFileDownload.saveAs(remotePath: path, size: size, using: fileBrowserModel)
                }
            }
    }
}
