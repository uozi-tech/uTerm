import AgentKit
import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

/// 「`Button` → `onTapGesture` + 显式 AX」这一轮改造的**默认动作**闸门。
///
/// ## 为什么要有这一条
///
/// 滚动成本那轮把好几处整行 `Button` 换成了 `contentShape + onTapGesture`
/// （`Button` 每行带 `_FocusRingView` / `KeyViewProxy`，是密集网格里的主因，
/// 见 uTable `docs/swiftui-scroll-perf-playbook.md` §三）。换完之后各处都补了
/// `.accessibilityElement(children: .combine)` + `.accessibilityAddTraits(.isButton)`
/// —— **但没补默认动作**。
///
/// `.isButton` 只是「长得像按钮」；`onTapGesture` 不像 `Button` 那样自动往
/// AX 元素上挂一条 `AXPress`。结果是 VoiceOver 念得出「按钮」、
/// 全键盘控制也能走焦点过去，**按下去什么都不发生**。
/// 这类回归编译器不管、视觉不显，只有走 AX 树按一下才抓得到。
///
/// 所以每一处都钉同一件事：**在 AX 树里找到那个元素 →
/// `accessibilityPerformPress()` → 断言状态真的变了**。
/// 写法抄 `ManagementListScrollCostTests.testGroupMemberRowRemainsAccessibleButton`。
///
/// 覆盖（2026-09-08 这一轮补的五处）：
/// 1. `GroupsManagerView` 分组行；
/// 2. `KeyManagerView` 的 `KeyRow`；
/// 3. `SSHConfigImportView` 复核行（勾选 / 取消勾选）；
/// 4. `ProvidersSettingsView` 的 `ProviderRow`；
/// 5. `AssistantView` 的排队消息卡与用户消息气泡（这两处改前**连 label 都没有**）。
@MainActor
final class TapGestureRowAccessibilityTests: XCTestCase {

    // MARK: - 夹具

    private var windows: [NSWindow] = []

    /// `uTermTests` 默认隔离 `nonisolated` + Swift 6：不能覆写 `tearDown()` 拆窗，
    /// 每条用例开头 `defer { closeAllWindows() }`（见 `ProbeSmokeTests`）。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 900, height: 640)

    /// AX 判据是结构判据，不是时间判据 —— 走离屏档（`ProbeWindow` 顶部那张表：
    /// 结构 / 几何读数与屏内一模一样）。
    @discardableResult
    private func mount<V: View>(_ view: V, size: NSSize = size) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width,
                                                             height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .offScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        return host
    }

    private func settle(_ host: NSHostingView<AnyView>, ms: Int = 400) async throws {
        try await Task.sleep(for: .milliseconds(ms))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func makeContainer() throws -> ModelContainer {
        // `cloudKitDatabase: .none`：不关的话镜像代理会在沙盒里反复重试连 cloudd，
        // 把用例挂住上百秒（`ManagementListScrollCostTests` 顶部记过这一条）。
        let config = ModelConfiguration("ax-probe-\(UUID())",
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        return try ModelContainer(for: ServerProfile.self, ServerGroup.self,
                                  SSHKey.self, AIProvider.self,
                                  ChatSession.self, ChatMessageRecord.self,
                                  configurations: config)
    }

    // MARK: - 1. 分组管理：分组行

    func testGroupRowHasWorkingAccessibilityPressAction() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()
        let ctx = ModelContext(container)
        // 三个组成员数各不相同 → 右栏「成员」页里 `移出 …` 按钮的**个数**
        // 就是「当前选中的是哪个组」的可观测投影。
        let sizes = [2, 3, 7]
        for (g, n) in sizes.enumerated() {
            let name = "env-\(String(format: "%02d", g))"
            ctx.insert(ServerGroup(name: name,
                                   colorHex: ServerGroup.palette[g % ServerGroup.palette.count],
                                   sortOrder: g))
            for i in 0..<n {
                let p = ServerProfile()
                p.name = "host-\(g)-\(i)"
                p.host = "10.0.\(g).\(i)"
                p.username = "ops"
                p.group = name
                p.sortOrder = g * 100 + i
                ctx.insert(p)
            }
        }

        // `@Query` 读的是 `container.mainContext`；这里的 `ctx` 是另一个上下文，
        // 不 save 视图那边一行都看不到。
        try ctx.save()

        let host = mount(GroupsManagerView().modelContainer(container))
        try await settle(host)

        // 默认选中排序第一的组（`selection == nil` 时落到 `sortedGroups.first`）。
        XCTAssertEqual(removeButtonCount(in: host), 2,
                       "夹具失效：默认应选中 env-00（2 台）")

        // 目标：第三个组（7 台）。它的 AX label 是「env-02，7 台主机」。
        let rows = axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label.hasPrefix("env-02，")
        }
        print("[ax-groups] 命中分组行 \(rows.count) 个：\(rows.prefix(3).map(axLabel).joined(separator: " / "))")
        let row = try XCTUnwrap(rows.first, "分组行必须在 AX 树里是一个 button")

        XCTAssertTrue(axPress(row), "AX 必须能按下分组行")
        try await settle(host)
        XCTAssertEqual(removeButtonCount(in: host), 7,
                       "按下 env-02 之后右栏必须换成它的 7 个成员 —— "
                       + "个数没变说明 AXPress 是空转（改前就是这样）")
    }

    private func removeButtonCount(in host: NSView) -> Int {
        axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label.hasPrefix("移出 ")
        }.count
    }

    // MARK: - 2. 密钥管理：KeyRow

    func testKeyRowHasWorkingAccessibilityPressAction() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()
        let ctx = ModelContext(container)
        for k in 0..<4 {
            let key = SSHKey()
            key.name = "probekey-\(String(format: "%02d", k))"
            key.fingerprint = "SHA256:probe\(k)"
            ctx.insert(key)
        }

        try ctx.save()

        let host = mount(KeyManagerView().modelContainer(container))
        try await settle(host)

        // 右栏 `KeyDetailView` 也画一遍 `key.name` —— 名字在整棵 AX 树里出现
        // 两次（左栏行 + 右栏详情）就说明它被选中了。
        let target = "probekey-02"
        XCTAssertEqual(textOccurrences(of: target, in: host), 1,
                       "夹具失效：未选中时 \(target) 只该出现在左栏行上")

        let rows = axElements(in: host) { label, _ in label.hasPrefix(target + "，") }
        print("[ax-keys] 命中密钥行 \(rows.count) 个：\(rows.prefix(3).map(axLabel).joined(separator: " / "))")
        let row = try XCTUnwrap(rows.first, "密钥行必须在 AX 树里找得到")
        XCTAssertEqual(axRole(row), NSAccessibility.Role.button.rawValue,
                       "密钥行必须是 button")

        XCTAssertTrue(axPress(row), "AX 必须能按下密钥行")
        try await settle(host)
        XCTAssertGreaterThan(textOccurrences(of: target, in: host), 1,
                             "按下之后右栏必须换成 \(target) 的详情 —— 只出现一次 = AXPress 空转")
    }

    // MARK: - 3. SSH config 导入：复核行勾选

    func testImportReviewRowTogglesSelectionViaAccessibilityPress() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()

        // 复核相位靠 `ImportInbox`（拖放路径）进：`onAppear → consumeInboxOrResetIfDone`。
        // 不走 `NSOpenPanel`，探针进得去。
        var text = ""
        for i in 0..<6 {
            text += """
            Host imp-\(String(format: "%02d", i))
              HostName 10.9.0.\(i)
              User ops
              Port 22

            """
        }
        let hosts = parseSSHConfig(text)
        let rows = SSHConfigImporter.plan(hosts, existingNames: [])
        XCTAssertEqual(rows.count, 6, "夹具失效：应该 plan 出 6 行")
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("ax-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        ImportInbox.shared.enqueue(.init(rows: rows, dir: staging, stagingRoot: staging))

        let host = mount(SSHConfigImportView().modelContainer(container), size: NSSize(width: 720, height: 560))
        try await settle(host)

        // 底栏按钮「导入 N 台」= `selection.count` 的可观测投影。
        XCTAssertEqual(importCount(in: host), 6, "夹具失效：默认应全选 6 台")

        let target = "imp-03"
        let candidates = axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label == target
        }
        print("[ax-import] 命中复核行 \(candidates.count) 个")
        let row = try XCTUnwrap(candidates.first, "复核行必须在 AX 树里是一个 button")

        XCTAssertTrue(axPress(row), "AX 必须能按下复核行")
        try await settle(host)
        XCTAssertEqual(importCount(in: host), 5,
                       "按一下必须取消勾选一台：6 → 5（没变 = AXPress 空转）")

        XCTAssertTrue(axPress(row), "再按一次应重新勾选")
        try await settle(host)
        XCTAssertEqual(importCount(in: host), 6, "再按一次必须勾回来：5 → 6")
    }

    /// 底栏「导入 N 台」里的 N。
    private func importCount(in host: NSView) -> Int? {
        let labels = axElements(in: host) { label, _ in label.hasPrefix("导入 ") && label.hasSuffix(" 台") }
            .map(axLabel)
        guard let first = labels.first else { return nil }
        return Int(first.dropFirst("导入 ".count).dropLast(" 台".count))
    }

    // MARK: - 4. Provider 设置：ProviderRow

    func testProviderRowHasWorkingAccessibilityPressAction() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()
        let ctx = ModelContext(container)
        for (i, name) in ["Alpha", "Bravo", "Charlie"].enumerated() {
            ctx.insert(AIProvider(name: name, kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "model-\(i)", sortOrder: i))
        }

        try ctx.save()

        let host = mount(ProvidersSettingsView().modelContainer(container),
                         size: NSSize(width: 820, height: 560))
        try await settle(host)

        // 右栏 `ProviderEditView` 的名称输入框也带同一个名字。
        XCTAssertEqual(textOccurrences(of: "Charlie", in: host), 1,
                       "夹具失效：未选中时 Charlie 只该出现在左列行上")

        let rows = axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label == "Charlie"
        }
        print("[ax-providers] 命中 provider 行 \(rows.count) 个")
        let row = try XCTUnwrap(rows.first, "provider 行必须在 AX 树里是一个 button")

        XCTAssertTrue(axPress(row), "AX 必须能按下 provider 行")
        try await settle(host)
        XCTAssertGreaterThan(textOccurrences(of: "Charlie", in: host), 1,
                             "按下之后右栏必须换成 Charlie 的表单 —— 只出现一次 = AXPress 空转")
    }

    // MARK: - 5. Agent 面板：排队消息卡 / 用户气泡

    private func makeAssistant(_ container: ModelContainer) -> (AssistantModel, AIProvider, ModelContext) {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let provider = AIProvider(name: "Probe", kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "probe-model")
        let model = AssistantModel(client: MockLLMClient(deltas: []),
                                   provider: provider, apiKey: "sk-probe")
        model.attach(context: ctx)
        return (model, provider, ctx)
    }

    private func assistantView(_ model: AssistantModel,
                               _ provider: AIProvider,
                               _ container: ModelContainer) -> some View {
        AssistantView(serverContext: "probe",
                      serverName: "node-probe",
                      model: model,
                      activeProviderIDString: .constant(provider.id.uuidString))
            .modelContainer(container)
    }

    /// 排队消息卡：整卡可点 = 载入编辑。改前**完全没有 AX**（既无 label 也无动作）。
    func testQueuedMessageCardIsAccessibleAndLoadsForEditing() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()
        let (model, provider, _) = makeAssistant(container)
        model.enqueue("排队里的第一条")
        model.enqueue("排队里的第二条")

        let host = mount(assistantView(model, provider, container),
                         size: NSSize(width: 430, height: 760))
        try await settle(host)

        let cards = axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label.hasPrefix("排队消息：")
        }
        print("[ax-agent] 命中排队卡 \(cards.count) 个：\(cards.map(axLabel).joined(separator: " / "))")
        let card = try XCTUnwrap(cards.first { axLabel($0).contains("第二条") },
                                 "排队消息卡必须在 AX 树里是一个带 label 的 button")

        XCTAssertTrue(model.input.isEmpty, "夹具失效：输入框应为空")
        XCTAssertTrue(axPress(card), "AX 必须能按下排队消息卡")
        try await settle(host)
        XCTAssertEqual(model.input, "排队里的第二条",
                       "按下排队卡必须把它载回输入框（实际：\(model.input)）")
        XCTAssertEqual(model.queuedMessages.count, 1, "载入编辑同时要出队")
    }

    /// 用户消息气泡：点击进编辑。改前只有一个 `accessibilityHidden(true)` 的铅笔，
    /// 气泡本身对 AX 完全不可见。
    func testUserBubbleIsAccessibleAndBeginsEditing() async throws {
        defer { closeAllWindows() }
        let container = try makeContainer()
        let (model, provider, ctx) = makeAssistant(container)
        let session = ChatSession(title: "ax")
        ctx.insert(session)
        let record = ChatMessageRecord(roleRaw: "user", text: "第一条用户消息", orderIndex: 0)
        record.session = session
        ctx.insert(record)
        session.messages = [record]
        model.load(session)

        let host = mount(assistantView(model, provider, container),
                         size: NSSize(width: 430, height: 760))
        try await settle(host)

        let bubbles = axElements(in: host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label == "第一条用户消息"
        }
        print("[ax-agent] 命中用户气泡 \(bubbles.count) 个")
        let bubble = try XCTUnwrap(bubbles.first,
                                   "用户气泡必须在 AX 树里是一个 button —— "
                                   + "改前它只有 `onTapGesture`，AX 上什么都没有")

        XCTAssertNil(model.editingMessageID, "夹具失效：初始不该在编辑态")
        XCTAssertTrue(axPress(bubble), "AX 必须能按下用户气泡")
        try await settle(host)
        XCTAssertEqual(model.editingMessageID, model.messages.first?.id,
                       "按下用户气泡必须进入该条消息的编辑态")
    }

    // MARK: - AX 小工具（形状抄 `ManagementListScrollCostTests`）

    private func axLabel(_ element: Any) -> String {
        ((element as AnyObject).accessibilityLabel?() as String?)
            ?? ((element as AnyObject).value(forKey: "accessibilityLabel") as? String)
            ?? ""
    }

    private func axValueString(_ element: Any) -> String {
        // `accessibilityValue()` 在 NSObject 上有多个重载，直接调会歧义 —— 走 KVC。
        guard let raw = (element as AnyObject).value(forKey: "accessibilityValue") else { return "" }
        return (raw as? String) ?? String(describing: raw)
    }

    private func axRole(_ element: Any) -> String {
        ((element as AnyObject).accessibilityRole?()?.rawValue)
            ?? ((element as AnyObject).value(forKey: "accessibilityRole") as? String)
            ?? ""
    }

    private func axPress(_ element: Any) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() ?? false
    }

    /// 深度优先遍历 AX 树（上限 5000 节点，防止病态树把用例挂住）。
    private func axElements(in root: NSView,
                            where match: (String, String) -> Bool) -> [Any] {
        var out: [Any] = []
        var visited = 0
        func walk(_ node: Any) {
            guard visited < 5000 else { return }
            visited += 1
            if match(axLabel(node), axRole(node)) { out.append(node) }
            let children = ((node as AnyObject).accessibilityChildren?() as [Any]?) ?? []
            for child in children { walk(child) }
        }
        walk(root)
        return out
    }

    /// 整棵 AX 树里（label + value）出现过多少次这段文字。
    /// 用来判「右栏详情有没有换成这一条」—— 左栏行贡献 1 次，详情再贡献 1 次。
    private func textOccurrences(of needle: String, in root: NSView) -> Int {
        var n = 0
        var visited = 0
        func walk(_ node: Any) {
            guard visited < 5000 else { return }
            visited += 1
            if axLabel(node).contains(needle) { n += 1 }
            if axValueString(node).contains(needle) { n += 1 }
            let children = ((node as AnyObject).accessibilityChildren?() as [Any]?) ?? []
            for child in children { walk(child) }
        }
        walk(root)
        return n
    }
}
