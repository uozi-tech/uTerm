import Foundation

/// 持久化 / 创建 API 用的轻量窗格种类标签。
nonisolated enum PaneKindTag: String, Codable, Sendable {
    case terminal
    case files
}

/// 运行期窗格种类，携带各自的运行时对象。
@MainActor
enum PaneKind {
    case terminal(TerminalSession)
    case files(FileBrowserModel)

    var tag: PaneKindTag {
        switch self {
        case .terminal: .terminal
        case .files: .files
        }
    }
}
