import LocalAuthentication
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 应用锁上锁时内容树不能被卸载。
///
/// 钉的是实机回归：改前 `MobileAppLockGate` 上锁时把整棵内容树移出视图树，根视图持有的
/// 会话工作区随之销毁——开着应用锁时，切去别的 App 再回来所有终端 / 文件标签全没了。
/// 现在内容常驻，锁屏画在独立的高层窗口里。
@MainActor
final class MobileAppLockGateTests: XCTestCase {

    func testLockingKeepsContentMountedAndShowsLockWindow() async throws {
        let model = AppLockModel(authenticator: AlwaysSucceeds(), requireAuthAtLaunch: false)
        let probe = MountProbe()
        let rig = MobileProbeRig(label: "app-lock")
        rig.mount(MountProbeView(probe: probe).mobileAppLockGate(model))
        try await settle(rig)
        XCTAssertEqual(probe.appeared, 1)
        XCTAssertFalse(lockWindowVisible(), "没上锁就出现了锁屏窗口")

        model.relock()
        try await settle(rig)
        XCTAssertEqual(probe.disappeared, 0, "上锁把内容树卸掉了——会话会随之销毁")
        XCTAssertTrue(lockWindowVisible(), "上锁后没有独立的锁屏窗口（盖不住已弹出的抽屉）")

        await model.authenticate()
        XCTAssertTrue(model.isUnlocked)
        try await settle(rig, extra: .milliseconds(400))   // 锁屏窗口 0.22s 淡出
        XCTAssertEqual(probe.appeared, 1, "解锁后内容被重新创建了，原来的状态没保住")
        XCTAssertEqual(probe.disappeared, 0)
        XCTAssertFalse(lockWindowVisible(), "解锁后锁屏窗口没撤")
        await rig.close()
    }

    private func settle(_ rig: MobileProbeRig, extra: Duration = .milliseconds(150)) async throws {
        rig.layout()
        try await Task.sleep(for: extra)
        rig.layout()
    }

    private func lockWindowVisible() -> Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.windowLevel == .alert + 1 && !$0.isHidden }
    }
}

@MainActor
private final class AlwaysSucceeds: BiometricAuthenticator {
    func availability() -> BiometryAvailability { .biometrics }
    func authenticate(policy: LAPolicy, reason: String) async -> AuthOutcome { .success }
}

@MainActor
private final class MountProbe {
    var appeared = 0
    var disappeared = 0
}

/// 带 `@State` 的内容：被卸载过就会重新 onAppear。
private struct MountProbeView: View {
    let probe: MountProbe
    @State private var marker = UUID()

    var body: some View {
        Text(marker.uuidString)
            .onAppear { probe.appeared += 1 }
            .onDisappear { probe.disappeared += 1 }
    }
}
