import AgentKit
import AppKit
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

/// 四个「管理类」列表的渲染成本 + 契约探针：分组管理、密钥管理、SSH config 导入复核、
/// Agent 会话历史下拉。
///
/// 形状抄 `uTermTests/Support/ProbeSmokeTests.swift`（真窗口 `.transparentOnScreen`、
/// 建窗后断言 `blindsRealMouse`、`defer { closeAllWindows() }`）。
///
/// ## 规模来源
///
/// - **2000 台主机**：`ServerProfile` 无条数上限；欢迎页 Tweaks 的 mock 只钳到 50 台
///   （`MockServerFactory.swift:28`），所以极端档只能自己造。2000 是「一个大团队把
///   整片机器都存进来」的量级。
/// - **60 个分组**：`ServerGroup` 也无上限，按环境 × 角色切分很容易到几十个。
/// - **50 把密钥**：`SSHKey` 同上。
/// - **2000 条 Host**：`~/.ssh/config` 里 Host 段的条数，导入复核页一次全列。
/// - **1000 条会话**：`ChatSession` 每次「新建对话」一条，长期使用累计。
@MainActor
final class ManagementListScrollCostTests: XCTestCase {

    // MARK: - 夹具

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func makeContainer() throws -> ModelContainer {
        // `cloudKitDatabase: .none`：不关的话 `NSCloudKitMirroringDelegate` 会为这
        // 一千多条新记录排导出任务，在沙盒里连不上 cloudd、反复重试，把测试挂住
        // ~100 秒（日志里成片的 `CKError "Service Unavailable"`）。探针不需要同步。
        let config = ModelConfiguration("mgmt-probe-\(UUID())",
                                        isStoredInMemoryOnly: true,
                                        cloudKitDatabase: .none)
        return try ModelContainer(for: ServerProfile.self, ServerGroup.self,
                                  SSHKey.self, ChatSession.self, ChatMessageRecord.self,
                                  configurations: config)
    }

    private func seedHosts(_ container: ModelContainer, groups: Int, hosts: Int, keys: Int) {
        let ctx = ModelContext(container)
        var keyIDs: [UUID] = []
        for k in 0..<keys {
            let key = SSHKey()
            key.name = "key-\(String(format: "%02d", k))"
            key.fingerprint = "SHA256:probe\(k)"
            keyIDs.append(key.id)
            ctx.insert(key)
        }
        var names: [String] = []
        for g in 0..<groups {
            let name = "env-\(String(format: "%02d", g))"
            names.append(name)
            ctx.insert(ServerGroup(name: name,
                                   colorHex: ServerGroup.palette[g % ServerGroup.palette.count],
                                   sortOrder: g))
        }
        for i in 0..<hosts {
            let p = ServerProfile()
            p.name = "host-\(String(format: "%04d", i))"
            p.host = "10.\(i / 65536).\((i / 256) % 256).\(i % 256)"
            p.username = "ops"
            p.sortOrder = i
            // 留 1/40 台不分组，让「未分组」那条派生行也出现。
            p.group = i % 40 == 39 ? nil : names[i % max(1, names.count)]
            if !keyIDs.isEmpty { p.keyID = keyIDs[i % keyIDs.count] }
            ctx.insert(p)
        }
        try? ctx.save()
    }

    private func seedSessions(_ container: ModelContainer, count: Int) {
        let t0 = CFAbsoluteTimeGetCurrent()
        defer { print(String(format: "[sessions-seed] %d 条耗时 %.1fs", count,
                             CFAbsoluteTimeGetCurrent() - t0)) }
        let ctx = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_750_000_000)
        for i in 0..<count {
            // `preview` 是从 messages 派生的计算属性，不能直接赋值 —— 挂一条真的用户消息。
            let s = ChatSession(title: "会话 \(String(format: "%04d", i))：排查 nginx 502")
            s.updatedAt = base.addingTimeInterval(Double(i) * 60)
            ctx.insert(s)
            // 只给最近 100 条挂消息（`preview` 是从 messages 派生的计算属性）：
            // 1000 条全挂会让内存库的插入本身跑上百秒，与要量的东西无关。
            if i >= count - 100 {
                let m = ChatMessageRecord()
                m.roleRaw = "user"
                m.text = "已检查 upstream 与 error.log，定位到后端超时。"
                m.session = s
                ctx.insert(m)
            }
        }
        try? ctx.save()
    }

    private static let size = NSSize(width: 980, height: 660)

    private func mount<V: View>(_ view: V, size: NSSize = ManagementListScrollCostTests.size)
        throws -> (window: ProbeWindow.Unconstrained, host: NSHostingView<AnyView>, mountMS: Double) {
        let host = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .darkAqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(unconstrained),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")
        return (unconstrained, host, mountMS)
    }

    private func viewCount(in root: NSView) -> Int {
        var n = 0
        func walk(_ v: NSView) { n += 1; for s in v.subviews { walk(s) } }
        walk(root)
        return n
    }

    private func classHistogram(in root: NSView) -> String {
        var counts: [String: Int] = [:]
        func walk(_ v: NSView) {
            counts[String(describing: type(of: v)), default: 0] += 1
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return counts.sorted { $0.value > $1.value }.prefix(6)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }

    /// 子树里所有 `NSScrollView`，按面积从大到小。
    private func scrollViews(in root: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ v: NSView) {
            if let s = v as? NSScrollView { found.append(s) }
            for s in v.subviews { walk(s) }
        }
        walk(root)
        return found.sorted { $0.frame.width * $0.frame.height > $1.frame.width * $1.frame.height }
    }

    struct Reading {
        var label = ""
        var mountMS = 0.0
        var beats = 0
        var p50 = 0.0
        var p95 = 0.0
        var overBudget = 0.0
        var hitP50 = 0.0
        var views = 0
        var docHeight = 0.0
        var histogram = ""
    }

    private func log(_ tag: String, _ r: Reading) {
        print(String(format: """
            [%@] %@ mount=%.1fms beats=%d/375 p50=%.2fms p95=%.2fms over8.33=%.1f%% \
            hit-p50=%.1fus views=%d doc-h=%.0f cpu=%.2fs rss=%.0fMB
            """,
            tag, r.label as NSString, r.mountMS, r.beats, r.p50, r.p95, r.overBudget,
            r.hitP50, r.views, r.docHeight,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[\(tag)-views] \(r.label) \(r.histogram)")
    }

    /// 通用一档：挂载 → 扫一遍让懒行实例化 → 3s 心跳 → 200 步往返 → hitTest。
    /// `scrollIndex` 选子树里第几个（按面积降序）滚动视图。
    private func measure<V: View>(_ label: String,
                                  _ view: V,
                                  scrollIndex: Int = 0,
                                  size: NSSize = ManagementListScrollCostTests.size) async throws -> Reading {
        let fixture = try mount(view, size: size)
        let host = fixture.host
        var r = Reading(label: label, mountMS: fixture.mountMS)
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
        try await Task.sleep(for: .milliseconds(250))
        layout()

        let all = scrollViews(in: host)
        guard all.indices.contains(scrollIndex), let document = all[scrollIndex].documentView else {
            r.views = viewCount(in: host)
            r.histogram = classHistogram(in: host)
            XCTFail("\(label)：找不到第 \(scrollIndex) 个 NSScrollView（共 \(all.count) 个）")
            await closeWindows()
            return r
        }
        let scroll = all[scrollIndex]
        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        let amplitude = min(maxOffset, viewport * 3)
        r.docHeight = Double(document.frame.height)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        var visited: CGFloat = 0
        while visited < amplitude {
            scrollTo(visited); layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += max(1, viewport * 0.8)
        }
        scrollTo(0); layout()
        try await Task.sleep(for: .milliseconds(120))

        let t0 = Date()
        while Date().timeIntervalSince(t0) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(r.beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            r.beats += 1
        }

        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave); layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }
        r.p50 = ProbeMetrics.percentile(frames, 0.5)
        r.p95 = ProbeMetrics.percentile(frames, 0.95)
        r.overBudget = Double(frames.filter { $0 > 8.33 }.count) / Double(frames.count) * 100

        var hits: [Double] = []
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction); layout()
            try await Task.sleep(for: .milliseconds(100))
            for i in 0..<100 {
                let point = NSPoint(x: CGFloat(60 + (i % 11) * 60), y: CGFloat(60 + (i % 9) * 60))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }
        r.hitP50 = ProbeMetrics.percentile(hits, 0.5)
        r.views = viewCount(in: host)
        r.histogram = classHistogram(in: host)
        await closeWindows()
        return r
    }

    // MARK: - 分组管理

    private func groupsView(_ container: ModelContainer) -> some View {
        GroupsManagerView().modelContainer(container)
    }

    /// 左栏组列表（60 组）+ 右栏「添加」候选（≈1967 台）。
    func testGroupsManagerLists() async throws {
        defer { closeAllWindows() }
        let small = try makeContainer()
        seedHosts(small, groups: 6, hosts: 60, keys: 3)
        let big = try makeContainer()
        seedHosts(big, groups: 60, hosts: 2000, keys: 50)

        // 极端的**成员列表**：把 2000 台全塞进一个组，右栏「成员」页就是 2000 行。
        let oneGroup = try makeContainer()
        seedHosts(oneGroup, groups: 1, hosts: 2000, keys: 50)

        let a = try await measure("6组/60台", groupsView(small))
        log("groups", a)
        let b = try await measure("60组/2000台", groupsView(big))
        log("groups", b)
        let c = try await measure("1组/2000成员", groupsView(oneGroup))
        log("groups", c)

        // 结构判据：左栏组行是懒栈 + 成员数改成查表，NSView 数不该随主机数量级涨。
        XCTAssertLessThan(b.views, a.views * 4,
                          "60 组 / 2000 台的 NSView 数不该是 6 组 / 60 台的 4 倍以上："
                          + "\(a.views) → \(b.views)")
        XCTAssertGreaterThan(b.beats, 60, "3 秒 8ms 心跳掉到 60 拍以下 = 主线程被占死")
        // 2000 行成员列表必须是懒的：NSView 数不该比 60 台档翻倍。
        XCTAssertLessThan(c.views, a.views * 4,
                          "2000 行成员列表的 NSView 数不该是小档的 4 倍以上：\(a.views) → \(c.views)")
        XCTAssertGreaterThan(c.docHeight, 2000 * 20.0,
                             "2000 行成员的文档高度必须与 2000 × 行高同量级（否则量的不是那张表）")
        XCTAssertGreaterThan(c.beats, 60, "3 秒 8ms 心跳掉到 60 拍以下 = 主线程被占死")
    }

    /// 契约：成员行的「移出 / + 加入」从 `Button` 换成命中区 + 手势之后，
    /// **AX 仍然是一个可按下的按钮**，按下去真的会改分组。
    func testGroupMemberRowRemainsAccessibleButton() async throws {
        AccessibilityTreeForTests.enable(for: self)
        defer { closeAllWindows() }
        let container = try makeContainer()
        seedHosts(container, groups: 3, hosts: 12, keys: 2)
        let fixture = try mount(groupsView(container))
        fixture.host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()

        let buttons = axElements(in: fixture.host) { label, role in
            role == NSAccessibility.Role.button.rawValue && label.hasPrefix("移出 ")
        }
        print("[groups-ax] 找到 \(buttons.count) 个「移出」按钮："
              + buttons.prefix(3).map { axLabel($0) }.joined(separator: " / "))
        XCTAssertFalse(buttons.isEmpty,
                       "成员行的「移出」必须在 AX 树里是一个 button —— "
                       + "换掉 SwiftUI `Button` 之后这条才是真正的回归闸门")

        let ctx = ModelContext(container)
        let before = try ctx.fetch(FetchDescriptor<ServerProfile>())
            .filter { !($0.group ?? "").isEmpty }.count
        XCTAssertGreaterThan(before, 0, "夹具里必须有已分组的主机")

        let pressed = axPress(try XCTUnwrap(buttons.first))
        XCTAssertTrue(pressed, "AX 必须能按下「移出」")
        try await Task.sleep(for: .milliseconds(400))

        let after = try ModelContext(container).fetch(FetchDescriptor<ServerProfile>())
            .filter { !($0.group ?? "").isEmpty }.count
        XCTAssertEqual(after, before - 1,
                       "按下「移出」必须真的把一台主机移出分组：\(before) → \(after)")
        await closeWindows()
    }

    // MARK: - 密钥管理

    func testKeyManagerSidebar() async throws {
        defer { closeAllWindows() }
        let small = try makeContainer()
        seedHosts(small, groups: 3, hosts: 60, keys: 5)
        let big = try makeContainer()
        seedHosts(big, groups: 60, hosts: 2000, keys: 50)

        let a = try await measure("5密钥/60台", KeyManagerView().modelContainer(small))
        log("keys", a)
        let b = try await measure("50密钥/2000台", KeyManagerView().modelContainer(big))
        log("keys", b)

        XCTAssertLessThan(b.views, a.views * 4,
                          "50 密钥 / 2000 台的 NSView 数不该是小档的 4 倍以上：\(a.views) → \(b.views)")
        XCTAssertGreaterThan(b.beats, 60, "3 秒 8ms 心跳掉到 60 拍以下 = 主线程被占死")
    }

    // MARK: - SSH config 导入复核

    /// 复核页的行来自 `SSHConfigImporter.plan`；这里直接造 `ImportRow` 注入视图不可行
    /// （`phase` 是私有 `@State`），所以拿一份 2000 段 Host 的 config 文本走
    /// `parseSSHConfig` + `plan`，量「plan 出来这些行、把它们摆成列表」的账。
    func testSSHConfigImportReviewList() async throws {
        defer { closeAllWindows() }
        for count in [50, 2000] {
            var text = ""
            for i in 0..<count {
                text += """
                Host srv-\(String(format: "%04d", i))
                  HostName 10.\(i / 256).\(i % 256).10
                  User ops
                  Port 22
                  IdentityFile ~/.ssh/id_ed25519_\(i % 7)

                """
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let hosts = parseSSHConfig(text)
            let rows = SSHConfigImporter.plan(hosts, existingNames: [])
            let planMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            XCTAssertEqual(rows.count, count)
            print(String(format: "[import] hosts=%d parse+plan=%.1fms", count, planMS))
        }

        // 视图侧：复核页要走 `NSOpenPanel` 才进得去 review 相位（`phase` 是私有
        // `@State`），探针进不去，所以拿一份**与 `importRowView` 同形状**的行列表，
        // 把改法的两个开关（懒栈 / 每行 `.help`）在同一轮里对照着量。
        let before = try await measure("2000 行 · 旧形态(VStack + 每行 .help)",
                                       ImportRowListProbe(count: 2000, lazyRows: false, perRowHelp: true))
        log("import", before)
        let after = try await measure("2000 行 · 新形态(LazyVStack + 无 .help)",
                                      ImportRowListProbe(count: 2000, lazyRows: true, perRowHelp: false))
        log("import", after)
        let smallAfter = try await measure("50 行 · 新形态",
                                           ImportRowListProbe(count: 50, lazyRows: true, perRowHelp: false))
        log("import", smallAfter)

        // 结构判据：新形态的 NSView 数不随行数涨；旧形态涨。
        XCTAssertLessThanOrEqual(abs(after.views - smallAfter.views), 6,
                                 "懒栈 + 无 `.help` 的复核行不该随行数长 NSView："
                                 + "50 行 \(smallAfter.views) vs 2000 行 \(after.views)")
        // tooltip 不长 NSView（它挂的是 `NSTrackingArea`），所以这条闸门要盯**命中路径**：
        // 2000 行 × 每行一个 tracking area，`hitTest` 一次要走完这堆区域。
        XCTAssertLessThan(after.hitP50 * 4, before.hitP50,
                          "旧形态每行 `.help` 会把 hitTest 拖慢一个数量级："
                          + "\(Int(before.hitP50))µs → \(Int(after.hitP50))µs")
        XCTAssertLessThan(after.mountMS * 4, before.mountMS,
                          "旧形态非懒 `VStack` 会在进入复核页那一帧把 2000 行全建出来："
                          + "\(Int(before.mountMS))ms → \(Int(after.mountMS))ms")
        XCTAssertGreaterThan(after.docHeight, smallAfter.docHeight * 10,
                             "2000 行的文档高度必须远大于 50 行（否则列表是空壳）")
    }

    /// 与 `SSHConfigImportView.importRowView` 同形状的行（懒栈、无 `.help`、多选）。
    /// 只用来量结构判据。
    private struct ImportRowListProbe: View {
        let count: Int
        var lazyRows = true
        var perRowHelp = false
        @State private var selection: Set<Int> = []

        var body: some View {
            ScrollView {
                Group {
                    if lazyRows { LazyVStack(spacing: 1) { rows } } else { VStack(spacing: 1) { rows } }
                }
                .padding(12)
            }
        }

        @ViewBuilder
        private var rows: some View {
            ForEach(0..<count, id: \.self) { i in
                        HStack(spacing: 10) {
                            Image(systemName: selection.contains(i) ? "checkmark.square.fill" : "square")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("srv-\(String(format: "%04d", i))")
                                Text("ops@10.\(i / 256).\(i % 256).10:22  ·  id_ed25519_\(i % 7)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .lineLimit(1).truncationMode(.middle)
                                    .modifier(RowHelp(enabled: perRowHelp,
                                                      text: "ops@10.\(i / 256).\(i % 256).10:22  ·  ~/.ssh/id_ed25519_\(i % 7)"))
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selection.contains(i) { selection.remove(i) } else { selection.insert(i) }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
            }
        }
    }

    /// 每行一个 `.help`（旧形态）。tooltip 的 `NSTrackingArea` 是按行建的。
    private struct RowHelp: ViewModifier {
        let enabled: Bool
        let text: String
        func body(content: Content) -> some View {
            if enabled { content.help(text) } else { content }
        }
    }

    // MARK: - 会话历史下拉

    /// `@Query` 钉上 `fetchLimit` 之后，1000 条会话的库里下拉只取最近 50 条。
    func testSessionDropdownFetchLimit() async throws {
        let container = try makeContainer()
        seedSessions(container, count: 1000)
        let ctx = ModelContext(container)

        let all = try ctx.fetch(FetchDescriptor<ChatSession>())
        XCTAssertEqual(all.count, 1000, "夹具里必须真有 1000 条会话")

        let t0 = CFAbsoluteTimeGetCurrent()
        let limited = try ctx.fetch(ChatSessionQueries.recent)
        let limitedMS = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        var unlimitedDescriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        unlimitedDescriptor.fetchLimit = nil
        let t1 = CFAbsoluteTimeGetCurrent()
        let unlimited = try ModelContext(container).fetch(unlimitedDescriptor)
        let unlimitedMS = (CFAbsoluteTimeGetCurrent() - t1) * 1000

        print(String(format: "[sessions] total=%d limited=%d(%.1fms) unlimited=%d(%.1fms)",
                     all.count, limited.count, limitedMS, unlimited.count, unlimitedMS))

        XCTAssertEqual(limited.count, ChatSessionQueries.recentLimit,
                       "下拉必须只取 \(ChatSessionQueries.recentLimit) 条")
        XCTAssertEqual(unlimited.count, 1000)
        // 契约：取到的是**最近**那批（updatedAt 倒序的头 50 条）。
        XCTAssertEqual(limited.first?.title, unlimited.first?.title,
                       "限量之后第一条仍必须是最近更新的那条")
        XCTAssertEqual(limited.last?.title, unlimited[ChatSessionQueries.recentLimit - 1].title,
                       "限量之后最后一条必须是倒序第 \(ChatSessionQueries.recentLimit) 条")
    }

    // MARK: - AX 小工具

    private func axLabel(_ element: Any) -> String {
        ((element as AnyObject).accessibilityLabel?() as String?)
            ?? ((element as AnyObject).value(forKey: "accessibilityLabel") as? String)
            ?? ""
    }

    private func axRole(_ element: Any) -> String {
        ((element as AnyObject).accessibilityRole?()?.rawValue)
            ?? ((element as AnyObject).value(forKey: "accessibilityRole") as? String)
            ?? ""
    }

    private func axPress(_ element: Any) -> Bool {
        (element as AnyObject).accessibilityPerformPress?() ?? false
    }

    /// 深度优先遍历 AX 树，收集满足条件的元素（上限 5000 个节点，防止病态树把测试挂住）。
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
}
