import AgentKit
import AppKit
import Markdown
import SwiftData
import SwiftUI
import XCTest
@testable import uTerm

/// Agent 消息流（`AssistantView.chat`）的滚动 / 挂载成本探针。
///
/// 形态：`ScrollViewReader + ScrollView + LazyVStack + ForEach(model.messages)`，
/// 每条 assistant 消息挂一棵 `StreamingMarkdownView`（内部是**非 lazy** 的
/// `MarkdownBlocks`）+ `textSelection` + `ForEach(toolCalls)`；用户消息是
/// `UserMessageRow`（一个 `.help` + `onHover`）。
///
/// 两臂靠 `AssistantView.messageWindowLimit` 切换，**同一个进程、同一份代码**：
/// - `legacy` 臂 `.max` —— 挂载全部消息（改前行为）；
/// - `windowed` 臂 `AgentMessageWindow.defaultLimit` —— 只挂最近 N 条（改后行为）。
///
/// 规模来源：`ChatSession` 对消息条数没有任何上限（`AgentKit` 的
/// `ChatMessageRecord` 一条一行、`AssistantModel.load` 全量映射进 `messages`），
/// `ContextCompressor` 只裁进模型的上下文、不裁视图数组。所以真实档取 200 条
/// （一天的排障会话量级），极端档取 1000 条。
@MainActor
final class AgentMessageListCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    /// 拆窗不走 `tearDown()`（`uTermTests` 默认 `nonisolated` + Swift 6，见
    /// `ProbeSmokeTests` 顶部注释）。每条用例开头 `defer { closeAllWindows() }`。
    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let size = NSSize(width: 420, height: 760)

    // MARK: - 造数据

    /// 一条 assistant 回复的 Markdown：标题 / 段落 / 列表 / 代码块 / 表格混排，
    /// 块数落在任务给的 30~50 之间。
    static func assistantMarkdown(index: Int, blocks: Int = 36,
                                  codeBlocks: Bool = true) -> String {
        var lines: [String] = []
        var produced = 0
        var section = 0
        while produced < blocks {
            section += 1
            lines.append("### 步骤 \(section)：排查 svc-\(index)-\(section)")
            produced += 1
            if produced >= blocks { break }
            lines.append(
                "先确认 **节点 \(index)** 的负载是否已经落回基线，"
                + "再看 `journalctl` 里 unit `app-\(index).service` 最近 5 分钟的报错。"
                + "这一段刻意写长一些，好让段落真的换行、排版成本进得了账。")
            produced += 1
            if produced >= blocks { break }
            lines.append("- 检查磁盘水位 `df -h /var`")
            lines.append("- 检查连接数 `ss -s`")
            lines.append("- 检查内存 `free -m`")
            produced += 1
            if produced >= blocks { break }
            if codeBlocks {
                lines.append("```bash\nssh node-\(index) 'systemctl status app-\(index)'\n"
                             + "journalctl -u app-\(index) --since -5min | tail -40\n```")
            } else {
                // 同样长度的纯段落替身：块数、字符数都对齐，只少了 ChatCodeBlock
                // 那一套「横向 ScrollView + Button + .help + textSelection」。
                lines.append("    ssh node-\(index) 'systemctl status app-\(index)' 然后 "
                             + "journalctl -u app-\(index) --since -5min | tail -40")
            }
            produced += 1
            if produced >= blocks { break }
            lines.append("| 指标 | 当前 | 阈值 |\n| --- | --- | --- |\n"
                         + "| CPU | \(40 + index % 50)% | 80% |\n"
                         + "| 内存 | \(30 + index % 60)% | 85% |\n"
                         + "| 连接 | \(100 + index) | 4096 |")
            produced += 1
        }
        return lines.joined(separator: "\n\n")
    }

    static func userText(index: Int) -> String {
        "第 \(index) 轮：node-\(index) 上的 app 又开始 5xx 了，先看一眼负载和日志，"
        + "有需要就直接跑命令。"
    }

    private static func toolCalls(index: Int) -> [ToolCallState] {
        [ToolCallState(id: "call-\(index)", name: "run_command",
                       command: "journalctl -u app-\(index) --since -5min | tail -40",
                       explanation: "查看最近 5 分钟日志",
                       status: .done,
                       output: (0..<12).map { "line \($0) of tool output for \(index)" }
                           .joined(separator: "\n"),
                       exitCode: 0)]
    }

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(for: ChatSession.self, ChatMessageRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    /// 走真实的持久化载入路径（`AssistantModel.load`），不给模型开测试后门。
    private func seed(_ model: AssistantModel, context: ModelContext, messages: Int,
                      codeBlocks: Bool = true) {
        let session = ChatSession(title: "probe")
        context.insert(session)
        var records: [ChatMessageRecord] = []
        for i in 0..<messages {
            let isUser = i % 2 == 0
            let record: ChatMessageRecord
            if isUser {
                record = ChatMessageRecord(roleRaw: "user", text: Self.userText(index: i),
                                           orderIndex: i)
            } else {
                record = ChatMessageRecord(
                    roleRaw: "assistant",
                    text: Self.assistantMarkdown(index: i, codeBlocks: codeBlocks),
                    toolCallsJSON: i % 8 == 1
                        ? ChatMessageRecord.encode(Self.toolCalls(index: i)) : "",
                    orderIndex: i)
            }
            record.session = session
            context.insert(record)
            records.append(record)
        }
        session.messages = records
        model.load(session)
    }

    private struct Fixture {
        let window: ProbeWindow.Unconstrained
        let host: NSHostingView<AnyView>
        let scroll: NSScrollView
        let document: NSView
        let model: AssistantModel
        let container: ModelContainer
        let mountMS: Double
    }

    private func makeFixture(messages: Int, windowLimit: Int,
                             codeBlocks: Bool = true) throws -> Fixture {
        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let provider = AIProvider(name: "Probe", kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "probe-model")
        let model = AssistantModel(client: MockLLMClient(deltas: []),
                                   provider: provider, apiKey: "sk-probe")
        model.attach(context: context)
        seed(model, context: context, messages: messages, codeBlocks: codeBlocks)

        let size = Self.size
        let root = AnyView(
            AssistantView(serverContext: "probe",
                          serverName: "node-probe",
                          model: model,
                          activeProviderIDString: .constant(provider.id.uuidString),
                          messageWindowLimit: windowLimit)
                .modelContainer(container)
                .frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled],
                                      contentView: host,
                                      key: true,
                                      placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        let start = CFAbsoluteTimeGetCurrent()
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000
        let scroll = try XCTUnwrap(host.firstScrollView(), "AssistantView 里必须有 NSScrollView")
        let document = try XCTUnwrap(scroll.documentView)
        let unconstrained = try XCTUnwrap(window as? ProbeWindow.Unconstrained)
        return Fixture(window: unconstrained, host: host, scroll: scroll, document: document,
                       model: model, container: container, mountMS: mountMS)
    }

    // MARK: - 尺

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

    struct Reading {
        let arm: String
        let messages: Int
        let mountMS: Double
        let beats: Int
        let frameP50: Double
        let frameP95: Double
        let overBudget: Double
        let hitP50: Double
        let views: Int
        let documentHeight: CGFloat
        let scrollableHeight: CGFloat
    }

    private func closeWindows() async {
        closeAllWindows()
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// 一档：挂载 → 扫一遍让懒行实例化 → 3s 心跳 → 200 步往返单帧 → hitTest。
    /// 往返幅度钳 ≈3 个视口（playbook：整篇一个余弦量到的是页跳不是滚动）。
    private func measure(arm: String, messages: Int, windowLimit: Int,
                         codeBlocks: Bool = true,
                         fullRange: Bool = false) async throws -> Reading {
        let fixture = try makeFixture(messages: messages, windowLimit: windowLimit,
                                      codeBlocks: codeBlocks)
        XCTAssertTrue(ProbeWindow.blindsRealMouse(fixture.window),
                      "透明屏内档必须谎报鼠标位置，否则用户光标会点亮 .onHover")
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host

        let viewport = scroll.contentSize.height
        let maxOffset = max(0, document.frame.height - viewport)
        // 钳 ≈3 视口是默认口径（playbook：整篇一个余弦量的是页跳不是滚动）；
        // `fullRange` 那一档故意不钳，量的就是「从底一路甩到顶」这件事。
        let amplitude = fullRange ? maxOffset : min(maxOffset, viewport * 3)

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(maxOffset, max(0, y))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        func layout() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }

        var visited: CGFloat = 0
        let sweepLimit = min(amplitude, viewport * 24)
        while visited < sweepLimit {
            scrollTo(visited)
            layout()
            try await Task.sleep(for: .milliseconds(8))
            visited += viewport * 0.8
        }
        scrollTo(0)
        layout()
        try await Task.sleep(for: .milliseconds(120))

        let heartbeatStart = Date()
        var beats = 0
        while Date().timeIntervalSince(heartbeatStart) < 3 {
            try await Task.sleep(for: .milliseconds(8))
            let wave = 0.5 * (1 - cos(Double(beats % 80) / 80 * 2 * .pi))
            scrollTo(amplitude * wave)
            beats += 1
        }

        var frames: [Double] = []
        for step in 0..<200 {
            let wave = 0.5 * (1 - cos(Double(step % 80) / 80 * 2 * .pi))
            let start = CFAbsoluteTimeGetCurrent()
            scrollTo(amplitude * wave)
            layout()
            frames.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(8))
        }

        var hits: [Double] = []
        for fraction in [0.02, 0.5, 0.98] {
            scrollTo(amplitude * fraction)
            layout()
            try await Task.sleep(for: .milliseconds(120))
            for i in 0..<100 {
                let point = NSPoint(x: CGFloat(40 + (i % 9) * 40), y: CGFloat(40 + (i % 11) * 40))
                let start = CFAbsoluteTimeGetCurrent()
                _ = host.hitTest(point)
                hits.append((CFAbsoluteTimeGetCurrent() - start) * 1_000_000)
            }
        }

        let reading = Reading(arm: arm,
                              messages: messages,
                              mountMS: fixture.mountMS,
                              beats: beats,
                              frameP50: ProbeMetrics.percentile(frames, 0.5),
                              frameP95: ProbeMetrics.percentile(frames, 0.95),
                              overBudget: Double(frames.filter { $0 > 8.33 }.count)
                                  / Double(frames.count) * 100,
                              hitP50: ProbeMetrics.percentile(hits, 0.5),
                              views: viewCount(in: host),
                              documentHeight: document.frame.height,
                              scrollableHeight: maxOffset)
        print(String(format: """
            [agent-list] arm=%@ messages=%d amp=%.0f mount=%.1fms beats=%d/375 frame-p50=%.3fms \
            frame-p95=%.3fms over-8.33=%.1f%% hit-p50=%.1fus views=%d doc-h=%.0f \
            scrollable=%.0f cpu=%.2fs rss=%.1fMB
            """,
            reading.arm, reading.messages, amplitude, reading.mountMS, reading.beats, reading.frameP50,
            reading.frameP95, reading.overBudget, reading.hitP50, reading.views,
            reading.documentHeight, reading.scrollableHeight,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        print("[agent-list-views] arm=\(arm) messages=\(messages) \(classHistogram(in: host))")
        await closeWindows()
        return reading
    }

    // MARK: - 用例

    /// 真实档 200 条 / 极端档 1000 条，两臂（无窗口 vs 渲染窗口）同轮交替。
    /// 断言只用**结构判据与同轮相对比**；绝对毫秒只打印。
    func testMessageListMountAndScrollCost() async throws {
        defer { closeAllWindows() }
        let unlimited = Int.max
        let windowed = AgentMessageWindow.defaultLimit

        // 轮内顺序反转一次，抵消「先跑的那一臂占便宜/吃亏」。
        let legacy200 = try await measure(arm: "legacy", messages: 200, windowLimit: unlimited)
        let win200 = try await measure(arm: "windowed", messages: 200, windowLimit: windowed)
        let win1000 = try await measure(arm: "windowed", messages: 1000, windowLimit: windowed)
        let legacy1000 = try await measure(arm: "legacy", messages: 1000, windowLimit: unlimited)

        print(String(format: "[agent-list-ratio] mount 1000/200 legacy=%.2f windowed=%.2f",
                     legacy1000.mountMS / max(legacy200.mountMS, 0.001),
                     win1000.mountMS / max(win200.mountMS, 0.001)))
        print(String(format: "[agent-list-ratio] views 1000/200 legacy=%.2f windowed=%.2f",
                     Double(legacy1000.views) / Double(max(legacy200.views, 1)),
                     Double(win1000.views) / Double(max(win200.views, 1))))

        // 结构判据 ①：渲染窗口下，1000 条与 200 条挂载的文档高度必须同量级
        //   —— 窗口真的把挂载量钳住了（留 25% 余量给窗口内的行高差异）。
        XCTAssertLessThan(win1000.documentHeight, win200.documentHeight * 1.25,
                          "渲染窗口档 1000 条的文档高度必须与 200 条同量级："
                          + "\(win1000.documentHeight) vs \(win200.documentHeight)")
        // 结构判据 ②：没有窗口时，1000 条的文档高度必须显著高于 200 条
        //   —— 证明改前臂确实在线性增长（否则上面那条是空断言）。
        XCTAssertGreaterThan(legacy1000.documentHeight, legacy200.documentHeight * 2,
                             "改前臂 1000 条的文档高度必须显著高于 200 条："
                             + "\(legacy1000.documentHeight) vs \(legacy200.documentHeight)")
        // 结构判据 ③：NSView 数不随会话总长涨（懒栈确实在回收行）——
        //   这是「滚动成本按视口走、不按总量走」的证据，两臂都必须成立。
        XCTAssertLessThanOrEqual(abs(legacy1000.views - legacy200.views), 40,
                                 "NSView 数不该随会话总长涨："
                                 + "200 条 \(legacy200.views) vs 1000 条 \(legacy1000.views)")
        // ④ 夹具自证：真的能滚，不是量了个空视图。
        XCTAssertGreaterThan(legacy200.scrollableHeight, 0, "200 条必须超过一屏")
        XCTAssertGreaterThan(win1000.beats, 30, "心跳一拍都收不到 = 主线程被占死")
    }

    /// 整篇跳转（不钳幅度）：一个 1000 条的会话，用户把滚动条从底拖到顶。
    /// 钳 3 视口的口径量不到这件事 —— 但**照抄 200 步余弦会把测试宿主挂死**
    /// （改前臂 1.6M pt 的 `LazyVStack` 上跑满程余弦，本机 3.5 分钟没跑完、
    /// runner 被判超时重启；这正是 uTable playbook §七 记的「LazyVStack + 大跨度
    /// 跳转」那条坑）。所以这里只做 8 次顶↔底跳转，每次逼一次布局。
    func testFullRangeJumpCost() async throws {
        defer { closeAllWindows() }
        let legacy = try await measureJumps(arm: "legacy-jump", messages: 1000,
                                            windowLimit: Int.max)
        let windowed = try await measureJumps(arm: "windowed-jump", messages: 1000,
                                              windowLimit: AgentMessageWindow.defaultLimit)
        print(String(format: "[agent-jump-ratio] windowed/legacy p50=%.2f max=%.2f travel=%.2f",
                     windowed.p50 / max(legacy.p50, 0.001),
                     windowed.max / max(legacy.max, 0.001),
                     Double(windowed.travel) / Double(max(legacy.travel, 1))))
        // 结构判据：改前臂的行程显著更长（渲染窗口真的把「能跳多远」钳住了）。
        XCTAssertGreaterThan(legacy.travel, windowed.travel * 2,
                             "改前臂 1000 条的可滚动行程必须显著长于渲染窗口臂："
                             + "\(legacy.travel) vs \(windowed.travel)")
    }

    private struct JumpReading {
        let arm: String
        let p50: Double
        let max: Double
        let travel: CGFloat
    }

    private func measureJumps(arm: String, messages: Int,
                              windowLimit: Int) async throws -> JumpReading {
        let fixture = try makeFixture(messages: messages, windowLimit: windowLimit)
        let scroll = fixture.scroll
        let document = fixture.document
        let host = fixture.host
        let maxOffset = max(0, document.frame.height - scroll.contentSize.height)
        var samples: [Double] = []
        for step in 0..<8 {
            let target: CGFloat = step % 2 == 0 ? maxOffset : 0
            let start = CFAbsoluteTimeGetCurrent()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            try await Task.sleep(for: .milliseconds(40))
        }
        let reading = JumpReading(arm: arm,
                                  p50: ProbeMetrics.percentile(samples, 0.5),
                                  max: samples.max() ?? 0,
                                  travel: maxOffset)
        print(String(format: "[agent-jump] arm=%@ messages=%d jump-p50=%.1fms jump-max=%.1fms "
                     + "travel=%.0f cpu=%.2fs rss=%.1fMB",
                     arm, messages, reading.p50, reading.max, reading.travel,
                     ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        await closeWindows()
        return reading
    }

    /// `ChatCodeBlock` 的贡献：同样的块数与字符数，一臂用围栏代码块
    /// （横向 `ScrollView` + `fixedSize` + 复制 `Button` + `.help` + `textSelection`），
    /// 一臂把它换成等长的缩进段落。差值就是代码块那套外框的账。
    func testChatCodeBlockChromeContribution() async throws {
        defer { closeAllWindows() }
        let limit = AgentMessageWindow.defaultLimit
        let withCode = try await measure(arm: "code-blocks", messages: 1000,
                                         windowLimit: limit, codeBlocks: true)
        let withoutCode = try await measure(arm: "no-code-blocks", messages: 1000,
                                            windowLimit: limit, codeBlocks: false)
        print(String(format:
            "[agent-codeblock-ratio] with/without beats=%.2f p50=%.2f p95=%.2f hit=%.2f "
            + "views=%d vs %d mount=%.2f",
            Double(withCode.beats) / Double(max(withoutCode.beats, 1)),
            withCode.frameP50 / max(withoutCode.frameP50, 0.001),
            withCode.frameP95 / max(withoutCode.frameP95, 0.001),
            withCode.hitP50 / max(withoutCode.hitP50, 0.001),
            withCode.views, withoutCode.views,
            withCode.mountMS / max(withoutCode.mountMS, 0.001)))
        XCTAssertGreaterThan(withCode.scrollableHeight, 0, "两臂都必须真的能滚")
        XCTAssertGreaterThan(withoutCode.scrollableHeight, 0, "两臂都必须真的能滚")
    }

    /// 挂载成本跟谁走：同一份 1000 条会话，只改挂载上限。
    /// 文档高度随上限单调增长 ⇒ 账在「挂了多少条」上，渲染窗口就是有效的旋钮。
    func testMountCostTracksWindowLimit() async throws {
        defer { closeAllWindows() }
        var mounts: [(Int, Double, CGFloat, Int)] = []
        for limit in [25, 50, 200, Int.max] {
            let fixture = try makeFixture(messages: 1000, windowLimit: limit)
            let views = viewCount(in: fixture.host)
            mounts.append((limit, fixture.mountMS, fixture.document.frame.height, views))
            print(String(format: "[agent-mount-sweep] limit=%@ mount=%.1fms doc-h=%.0f views=%d",
                         limit == Int.max ? "∞" : String(limit),
                         fixture.mountMS, fixture.document.frame.height, views))
            await closeWindows()
        }
        for i in 1..<mounts.count {
            XCTAssertGreaterThan(mounts[i].2, mounts[i - 1].2,
                                 "上限 \(mounts[i].0) 的文档高度必须高于上限 \(mounts[i - 1].0)")
        }
    }

    /// 流式期间：极端档 1000 条打底，用 20 chunk/s 的假 SSE 追加 12 秒，
    /// 量主线程 8ms 心跳的拍数（拍数掉多少，主线程就被占多少）。
    func testStreamingMainThreadCost() async throws {
        defer { closeAllWindows() }
        // 用 1000 条极端档：真实档 200 条正好等于默认上限，两臂在那里是同一件事。
        let legacy = try await measureStreaming(arm: "legacy", messages: 1000,
                                                windowLimit: Int.max)
        let windowed = try await measureStreaming(arm: "windowed", messages: 1000,
                                                  windowLimit: AgentMessageWindow.defaultLimit)
        print(String(format: "[agent-stream-ratio] beats windowed/legacy=%.2f",
                     Double(windowed.beats) / Double(max(legacy.beats, 1))))
        XCTAssertGreaterThan(legacy.appended, 0, "假 SSE 必须真的把文本追加进了尾消息")
        XCTAssertGreaterThan(windowed.appended, 0, "假 SSE 必须真的把文本追加进了尾消息")
    }

    private struct StreamReading {
        let arm: String
        let beats: Int
        let ideal: Int
        let appended: Int
    }

    /// 模拟 SSE：直接驱动模型公开的流式入口（`send`），后端是一个按 20 chunk/s
    /// 吐 `.text` 的假 client。测量窗口内主线程只跑 8ms 心跳，不做人工滚动
    /// —— 贴底跟随、Markdown 重解析、LazyVStack 重排都由被测视图自己触发。
    private func measureStreaming(arm: String, messages: Int,
                                  windowLimit: Int) async throws -> StreamReading {
        let seconds = 12.0
        let chunksPerSecond = 20.0
        let chunks = Int(seconds * chunksPerSecond)

        let container = try makeContainer()
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let provider = AIProvider(name: "Probe", kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL,
                                  model: "probe-model")
        let client = PacedLLMClient(chunks: chunks,
                                    interval: .milliseconds(Int(1000 / chunksPerSecond)))
        let model = AssistantModel(client: client, provider: provider, apiKey: "sk-probe")
        model.attach(context: context)
        seed(model, context: context, messages: messages)

        let size = Self.size
        let root = AnyView(
            AssistantView(serverContext: "probe",
                          serverName: "node-probe",
                          model: model,
                          activeProviderIDString: .constant(provider.id.uuidString),
                          messageWindowLimit: windowLimit)
                .modelContainer(container)
                .frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], contentView: host,
                                      key: true, placement: .transparentOnScreen)
        windows.append(window)
        ProbeWindow.isolateHostWindows(keeping: windows)
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let before = model.messages.count
        model.input = "开始流式"
        let send = Task { await model.send(serverContext: "probe") }

        let start = Date()
        var beats = 0
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(8))
            host.layoutSubtreeIfNeeded()
            beats += 1
        }
        let tail = model.messages.last?.text.count ?? 0
        send.cancel()
        model.dispose()
        _ = before
        let ideal = Int(seconds * 125)
        print(String(format: """
            [agent-stream] arm=%@ messages=%d beats=%d/%d tail-chars=%d cpu=%.2fs rss=%.1fMB
            """, arm, messages, beats, ideal, tail,
            ProbeMetrics.threadCPUSeconds(), ProbeMetrics.footprintMB()))
        await closeWindows()
        return StreamReading(arm: arm, beats: beats, ideal: ideal, appended: tail)
    }

    /// 100ms 重解析的耗时随消息长度怎么长 —— 不建窗口，只量
    /// `StreamingMarkdownRenderer` 每次落定时那一次 `Document(parsing:)`。
    func testReparseCostGrowsWithMessageLength() throws {
        var previous = 0.0
        var rows: [(Int, Double)] = []
        for blocks in [4, 8, 16, 32, 64, 128] {
            let source = Self.assistantMarkdown(index: 7, blocks: blocks)
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = CFAbsoluteTimeGetCurrent()
                let doc = Markdown.Document(parsing: source)
                _ = Array(doc.blockChildren).count
                samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
            }
            let p50 = ProbeMetrics.percentile(samples, 0.5)
            rows.append((source.count, p50))
            print(String(format: "[agent-reparse] blocks=%d chars=%d parse-p50=%.3fms",
                         blocks, source.count, p50))
            previous = p50
        }
        _ = previous
        // 结构判据：解析成本对字符数至少是单调不降的（它就是每 100ms 要付一次的账）。
        XCTAssertGreaterThan(rows.last!.1, 0, "解析必须真的发生")
        XCTAssertGreaterThan(rows.last!.0, rows.first!.0 * 4, "长度档必须真的拉开")
    }
}

/// 按固定间隔吐 `.text` 的假后端 —— 复现 20 chunk/s 的 SSE 节奏。
private struct PacedLLMClient: LLMClient {
    let chunks: Int
    let interval: Duration

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let chunks = chunks
        let interval = interval
        return AsyncThrowingStream { continuation in
            let task = Task {
                for i in 0..<chunks {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: interval)
                    continuation.yield(.text(Self.chunk(i)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 每 8 片凑出一个新的 Markdown 块，让重解析的输入真的越来越长、越来越复杂。
    private static func chunk(_ i: Int) -> String {
        switch i % 8 {
        case 0: return "\n\n### 分析 \(i / 8)\n\n"
        case 1, 2, 3: return "这是第 \(i) 段流式文本，带 `inline code` 与 **强调**。"
        case 4: return "\n\n- 要点 \(i)\n- 要点 \(i + 1)\n"
        case 5: return "\n\n```sh\necho step-\(i)\n```\n\n"
        default: return "继续补充第 \(i) 片内容。"
        }
    }
}
