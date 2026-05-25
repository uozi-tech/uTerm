import Foundation

/// App 启动时如何决定主窗口呈现。AppStorage key: `startupBehavior`（String raw）。
/// 默认 `.welcome`。
///
/// 注意：setting 改了只在**下次 app 启动**时生效——WelcomeView .task 在 app
/// 启动时读一次后即定型，运行中不响应 setting 变化。
enum StartupBehavior: String, CaseIterable, Identifiable {
    case welcome
    case restore
    case lastHost = "last-host"

    var id: String { rawValue }

    var localizedLabel: String {
        switch self {
        case .welcome:  return "欢迎页"
        case .restore:  return "上次会话"
        case .lastHost: return "上次主机"
        }
    }
}
