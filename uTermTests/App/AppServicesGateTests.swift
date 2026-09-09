import XCTest
@testable import uTerm

/// 应用级服务（CloudKit 监听 / 命令行接口 / `terminal-open` 的开窗入口）的
/// 一次性安装闸门。
///
/// 它存在的理由是一个真实的坑：这三样原本只挂在 Welcome 窗的 `.task` 里，而
/// Welcome 窗**不一定出现**（启动行为「上次会话 / 上次主机」会 dismiss 它，macOS
/// 恢复窗口状态时也可能只恢复工作区窗口）。那时 `ControlSettings.observe` 从没装上，
/// 用户在设置里打开命令行开关**什么都不发生、也不报错**。现在每个 Scene 都触发一次
/// 安装，由这个闸门保证只跑一次 —— 所以「幂等」是这里唯一要钉死的性质。
@MainActor
final class AppServicesGateTests: XCTestCase {

    func testFreshGateHasNotInstalled() {
        XCTAssertFalse(AppServicesGate().hasInstalled)
    }

    /// 多个窗口先后出现 → 只装一次。
    func testInstallsExactlyOnceNoMatterHowManyScenesTrigger() {
        let gate = AppServicesGate()
        var installs = 0
        XCTAssertTrue(gate.install { installs += 1 })
        XCTAssertTrue(gate.hasInstalled)
        for _ in 0..<5 {
            XCTAssertFalse(gate.install { installs += 1 })
        }
        XCTAssertEqual(installs, 1)
    }

    /// 第一个触发的**不必**是 Welcome —— 任何窗口都行，这正是修复的要点。
    func testAnySceneCanBeTheFirstInstaller() {
        let gate = AppServicesGate()
        var installedBy: String?
        // 状态恢复只恢复了工作区窗口，Welcome 从未出现。
        gate.install { installedBy = "workspace" }
        gate.install { installedBy = "welcome" }
        XCTAssertEqual(installedBy, "workspace")
    }
}
