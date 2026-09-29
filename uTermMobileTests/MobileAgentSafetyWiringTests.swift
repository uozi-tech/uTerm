import AgentKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// 移动端信任档位拨盘 → `AssistantModel.approvalMode` 的接线。
///
/// 回归：`MobileAgentChat` 此前从不给 `approvalMode` 赋值，模型恒为 `.confirm`，
/// 拨盘选「只读自动」/「AI 审批」都不生效（桌面 `AssistantView` /
/// `TerminalAgentView` 一直是接上的）。
///
/// 用私有 `UserDefaults` 套件经 `.defaultAppStorage` 注入：测试宿主会起
/// `SharedPreferencesSync`，直接改 `.standard` 的 `agentSafety` 可能被推进 iCloud KVS。
///
/// 隔离：整类 `@MainActor`，不覆写 `tearDown()`，用例开头 `defer` 拆窗（README「隔离」）。
@MainActor
final class MobileAgentSafetyWiringTests: XCTestCase {
    private static let key = "agentSafety"

    private func waitUntil(_ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("等待超时", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testSafetyPickerValueDrivesApprovalMode() async throws {
        defer { MobileProbeWindow.closeAll() }

        let suite = "MobileAgentSafetyWiringTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(AgentSafety.auto.rawValue, forKey: Self.key)

        let container = try MobileFixtures.emptyContainer()
        let context = container.mainContext
        context.autosaveEnabled = false
        let provider = MobileFakeAgent.provider()
        context.insert(provider)
        let host = ServerProfile()
        host.name = "safety-node"
        host.host = "10.0.0.12"
        context.insert(host)
        try context.save()

        let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                   provider: provider, apiKey: "sk-probe")
        defer { model.dispose() }
        XCTAssertEqual(model.approvalMode, .confirm, "前提：模型默认档位是 .confirm")

        let rig = MobileProbeRig(label: "agent-safety")
        rig.mount(
            MobileAgentChat(model: model, host: host, tasks: MAgentTaskBag())
                .modelContainer(container)
                .environment(\.mAccent, M.accent)
                // 不注入的话默认 `.live` 会去解析 keychain / 建 SSH 连接。
                .environment(\.agentCommandExecutorFactory, .none)
                .defaultAppStorage(defaults))

        // 出现时按持久化档位灌入。
        try await waitUntil { model.approvalMode == .auto }

        // 拨盘改动（经 AppStorage 写回同一 key）跟随到模型。
        defaults.set(AgentSafety.confirm.rawValue, forKey: Self.key)
        try await waitUntil { model.approvalMode == .confirm }

        // 非法值与桌面同口径回退 .readAuto（拨盘此时也显示「只读自动」，两边一致）。
        defaults.set("not-a-mode", forKey: Self.key)
        try await waitUntil { model.approvalMode == .readAuto }
    }
}
