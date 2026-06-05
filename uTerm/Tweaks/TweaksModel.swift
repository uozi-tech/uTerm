#if DEBUG
import Foundation
import Observation

/// 欢迎页列表数据来源覆盖。
enum WelcomeSource: Hashable {
    case real    // 真实 @Query 数据
    case empty   // 强制空态
    case mock    // 强制 Mock 数据
}

/// Tweaks 调试状态（仅 DEBUG）。单例跨 Scene 共享：Tweaks 窗口写、欢迎页读。
///
/// `@Observable` + `@MainActor`：欢迎页 `body` 读取本对象属性即自动建立依赖、
/// 任一属性变更触发欢迎页重渲染。`resolvedProfiles(.mock)` 每次现算（工厂确定性、
/// id 稳定），无需缓存。
@MainActor
@Observable
final class TweaksModel {
    static let shared = TweaksModel()

    // 状态覆盖（A）
    var welcomeSource: WelcomeSource = .real

    // Mock 旋钮（C）
    var serverCount: Int = 8
    var groupCount: Int = 2
    var pinnedCount: Int = 1
    var recentCount: Int = 3
    var nameStyle: MockNameStyle = .normal

    /// 显示路径调用：把真实数组解析为最终用于渲染的数组。
    func resolvedProfiles(real: [ServerProfile]) -> [ServerProfile] {
        switch welcomeSource {
        case .real:  return real
        case .empty: return []
        case .mock:
            return MockServerFactory.make(
                serverCount: serverCount,
                groupCount: groupCount,
                pinnedCount: pinnedCount,
                recentCount: recentCount,
                nameStyle: nameStyle)
        }
    }
}
#endif
