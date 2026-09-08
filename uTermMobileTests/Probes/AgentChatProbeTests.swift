import AgentKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// `MobileAgentChat`（移动端 Agent 聊天屏）的渲染评估探针。
///
/// 四条读数，对应任务书的四问：
///
/// 1. `testHistoryReplayMountAndScroll` —— 200 / 1000 条历史回放的**挂载与滚动**，
///    两臂（渲染窗口 关 / 开）同轮对照。
/// 2. `testStreamingMainThreadCost` —— 流式 30 秒（20 chunk/s）期间的**心跳 /
///    单帧 / `UIView` 波动**，两臂同轮对照。
/// 3. `testToolExecutionEndToEnd` —— 一次工具执行**批准到完成**的耗时与
///    卡片重绘次数（走产品自己的 `\.agentCommandExecutorFactory` 注入口）。
/// 4. `testSessionHistoryMenuOpenCost` —— 会话历史菜单（`fetchLimit` 已钉）的打开耗时。
///
/// **闸门只用结构判据与同轮相对比，绝对毫秒只打印**（playbook §一）。
///
/// 隔离：`uTermMobileTests` 默认 `nonisolated`，整类 `@MainActor`，
/// **不覆写 `tearDown()`**，每条用例开头 `defer { MobileProbeWindow.closeAll() }`
/// （README「隔离」/「夹具跨用例契约」）。
@MainActor
final class AgentChatProbeTests: XCTestCase {

    // MARK: - 档位

    /// 真实档 200 条 / 极端档 1000 条 —— 与桌面 `AgentMessageListCostTests` 同规模，
    /// 好让两端读数可比。规模来源：`ChatSession` 对消息条数没有任何上限，
    /// `AssistantModel.load` 全量映射进 `messages`，`ContextCompressor` 只裁
    /// **进模型的上下文**、不裁视图数组。
    private static let realisticMessages = 200
    private static let extremeMessages = 1_000

    /// 渲染窗口两臂。`0` = 不裁（改前行为），`AgentMessageWindow.defaultLimit` = 改后。
    private static let legacyLimit = 0
    private static let windowedLimit = AgentMessageWindow.defaultLimit

    /// iPhone 竖屏近似。**写死**：iPhone 与 iPad 可视行数差三倍，写死才可比。
    private static let screen = CGSize(width: 390, height: 700)

    // MARK: - 夹具装配

    /// 一份「能把 `MobileAgentChat` 撑起来」的最小环境。
    ///
    /// `providers` 为空时屏幕整个走 `MEmptyState`（**没有 `UIScrollView`**，
    /// 所有滚动读数当场作废），所以容器里必须有一个 `AIProvider`。
    /// 主机也得是库里的真对象 —— 屏幕拿它去 `\.agentCommandExecutorFactory` 造执行器。
    private struct Bench {
        let container: ModelContainer
        let context: ModelContext
        let host: ServerProfile
        let provider: AIProvider
    }

    private func makeBench() throws -> Bench {
        let container = try MobileFixtures.emptyContainer()
        let context = container.mainContext
        context.autosaveEnabled = false

        let provider = MobileFakeAgent.provider()
        context.insert(provider)

        let host = ServerProfile()
        host.name = "probe-node-01"
        host.host = "10.0.0.11"
        host.port = 22
        host.username = "root"
        context.insert(host)

        try context.save()
        return Bench(container: container, context: context, host: host, provider: provider)
    }

    /// 把屏幕包成可挂载的根视图。`executor` 非 nil 时经**产品自己的注入口**换掉真执行器。
    private func chat(_ model: AssistantModel,
                      bench: Bench,
                      windowLimit: Int,
                      executor: MobileFakeCommandExecutor? = nil) -> AnyView {
        var view = AnyView(
            MobileAgentChat(model: model,
                            host: bench.host,
                            tasks: MAgentTaskBag(),
                            serverContext: "probe-node-01（root@10.0.0.11:22）",
                            messageWindowLimit: windowLimit)
                .modelContainer(bench.container)
                .environment(\.mAccent, M.accent))
        if let executor {
            view = AnyView(view.environment(\.agentCommandExecutorFactory, .stub(executor)))
        } else {
            // 探针默认**不给**执行器：不注入的话默认值是 `.live`，会去解析 keychain、
            // 甚至真的建 SSH 连接。`.none` 等价于「认证材料解析失败」那条产品路径。
            view = AnyView(view.environment(\.agentCommandExecutorFactory, .none))
        }
        return view
    }

    // MARK: - 1. 历史回放：挂载 + 滚动

    /// 200 / 1000 条 × 渲染窗口 关 / 开，四档同轮。
    ///
    /// 轮内**顺序反转**（1000 条先跑「开」再跑「关」）：SwiftUI 首次渲染的一次性开销
    /// 会全砸在这一轮的第一个 fixture 上，不反转的话「先跑的那一臂更贵」会被读成结论。
    func testHistoryReplayMountAndScroll() async throws {
        defer { MobileProbeWindow.closeAll() }

        var rows: [String] = []
        let plan: [(Int, [Int])] = [
            (Self.realisticMessages, [Self.legacyLimit, Self.windowedLimit]),
            (Self.extremeMessages, [Self.windowedLimit, Self.legacyLimit]),   // 反转
        ]
        var readings: [String: (mount: Double, p50: Double, p95: Double, over: Double,
                                views: Int, hit: Double, content: CGFloat)] = [:]

        for (count, limits) in plan {
            for limit in limits {
                let key = "\(count)-\(limit == 0 ? "legacy" : "window\(limit)")"
                let bench = try makeBench()
                let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                           provider: bench.provider, apiKey: "sk-probe")
                model.attach(context: bench.context)
                defer { model.dispose() }
                MobileFakeAgent.replayHistory(into: model, context: bench.context, messages: count)
                XCTAssertEqual(model.messages.count, count, "回放条数必须一条不差")

                let rig = MobileProbeRig(label: key, size: Self.screen)
                rig.mount(chat(model, bench: bench, windowLimit: limit))
                // 挂载后给 SwiftUI 一拍把 `onAppear`/首屏排版跑完，再量。
                try await Task.sleep(for: .milliseconds(250))
                rig.layout()

                let scroll = try await rig.measureScroll()
                let shot = await rig.snapshot()
                rig.report(scroll, shot)
                attachProbePNG(shot.png, name: key)

                readings[key] = (rig.mountMS, scroll.p50, scroll.p95, scroll.overStrictPct,
                                 shot.views, shot.hitP50, scroll.contentHeight)
                rows.append(String(format: "| %@ | %.1fms | %.3fms | %.3fms | %.1f%% | %d | %.0fµs | %.0f |",
                                   key, rig.mountMS, scroll.p50, scroll.p95, scroll.overStrictPct,
                                   shot.views, shot.hitP50, scroll.contentHeight))

                // 结构判据：真的滚得动，且真的画出了东西。
                XCTAssertGreaterThan(scroll.scrollable, 0, "\(key) 滚不动 —— 读数作废")
                XCTAssertGreaterThan(scroll.travelled, 0, "\(key) 驱动没把视图推动")
                XCTAssertGreaterThan(shot.ink, 0, "\(key) 截图是空壳")

                await rig.close()
            }
        }

        print("[agent-history] | 档 | 挂载 | p50 | p95 | 超8.33 | UIView | hitTest | 文档高 |")
        print("[agent-history] |---|---|---|---|---|---|---|---|")
        for row in rows { print("[agent-history] \(row)") }

        // 唯一的**结构闸门**：渲染窗口必须真的把文档高度钳住。
        // 绝对毫秒只打印（机器负载噪声大），几何是确定性的。
        if let legacy = readings["\(Self.extremeMessages)-legacy"],
           let windowed = readings["\(Self.extremeMessages)-window\(Self.windowedLimit)"] {
            print(String(format: "[agent-history] 1000 条文档高 %.0f → %.0f（%.2f×）",
                         legacy.content, windowed.content,
                         windowed.content == 0 ? 0 : legacy.content / windowed.content))
            XCTAssertLessThan(windowed.content, legacy.content,
                              "渲染窗口没有钳住文档高度 —— 处方没生效")
        }
        // 真实档 200 条正好等于默认上限，两臂**挂的是同一批消息**（自证）。
        //
        // 判据是「文档高度在同一量级」而不是「逐点相等」：`LazyVStack` 的
        // contentSize 里含未实例化行的**估高**，实际数值取决于这一轮扫过哪些行，
        // 两臂差 1% 量级是常态（实测 472982 vs 478892 = 1.25%）。
        // 闸门放在 5% —— 真要是有一臂被裁了，差的是 5 倍不是 5%。
        if let a = readings["\(Self.realisticMessages)-legacy"],
           let b = readings["\(Self.realisticMessages)-window\(Self.windowedLimit)"] {
            let delta = abs(a.content - b.content) / Swift.max(a.content, b.content)
            print(String(format: "[agent-history] 200 条两臂文档高 %.0f vs %.0f（差 %.2f%%）",
                         a.content, b.content, delta * 100))
            XCTAssertLessThan(delta, 0.05,
                              "200 条 == 默认上限，两臂应当挂同样多的消息")
        }
    }

    // MARK: - 2. 流式 30 秒

    /// 1000 条打底，20 chunk/s 的假 SSE 追加 30 秒；主线程只跑 8ms 心跳 + `CADisplayLink`。
    /// 量的是「文本一直在长」的这半分钟里主线程还剩多少、单帧成本怎么样、`UIView` 有没有漂。
    ///
    /// 两臂（渲染窗口 关 / 开）同轮，**顺序：先关后开**（改前臂先跑，吃掉首次渲染开销
    /// 反而对「改后更好」这个结论不利 —— 宁可让结论承受不利的顺序偏置）。
    func testStreamingMainThreadCost() async throws {
        defer { MobileProbeWindow.closeAll() }

        let seconds: Double = 30
        let rate: Double = 20
        var arms: [(name: String, beat: MobileProbeRig.Heartbeat, chars: Int,
                    delivered: Int, viewsMin: Int, viewsMax: Int, frameP95: Double)] = []

        for limit in [Self.legacyLimit, Self.windowedLimit] {
            let name = limit == 0 ? "legacy" : "window\(limit)"
            let bench = try makeBench()
            let chunks = MobileFakeAgent.pacedChunks(seconds: seconds * 1.5, chunksPerSecond: rate)
            let client = MobilePacedLLMClient(chunks: chunks, chunksPerSecond: rate)
            let model = AssistantModel(client: client, provider: bench.provider, apiKey: "sk-probe")
            model.attach(context: bench.context)
            defer { model.dispose() }
            MobileFakeAgent.replayHistory(into: model, context: bench.context,
                                          messages: Self.extremeMessages)

            let rig = MobileProbeRig(label: "stream-\(name)", size: Self.screen)
            rig.mount(chat(model, bench: bench, windowLimit: limit))
            try await Task.sleep(for: .milliseconds(250))
            rig.layout()

            // 开流。`submit` 是屏幕自己走的那条路（忙碌时入队），这里空闲直发。
            let task = Task { await model.submit(text: "帮我排查一下 5xx", serverContext: "probe") }

            // 流式期间的 `UIView` 波动：每秒采一次。用引用盒装样本 ——
            // 局部 `var` 被逃逸闭包捕获并改写，Swift 6 判成数据竞争。
            let samples = ProbeIntBag()
            let sampler = Task { @MainActor in
                while !Task.isCancelled {
                    if let host = rig.hostView { samples.values.append(host.recursiveViewCount()) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            // 心跳：不叠加滚动（`wave: false`）—— 这一档要的是「流式本身吃掉多少主线程」，
            // 叠上往返滚动就分不清是谁的账。
            let beat = try await rig.heartbeat(seconds: seconds, wave: false)
            sampler.cancel()

            // 流式**期间**的单帧：心跳跑完立刻量一小段（60 步，流还没停）。
            let frames = try await rig.measureScroll(steps: 60, sweepFirst: false)

            let chars = model.messages.last?.text.count ?? 0
            let delivered = client.deliveredChunks
            let shot = await rig.snapshot()
            rig.report(frames, shot, beat)

            let vs = samples.values
            arms.append((name, beat, chars, delivered,
                         vs.min() ?? 0, vs.max() ?? 0, frames.p95))
            print(String(format: "[agent-stream-%@] views 采样 %d 次 min=%d max=%d 波动=%d",
                         name, vs.count, vs.min() ?? 0, vs.max() ?? 0,
                         (vs.max() ?? 0) - (vs.min() ?? 0)))

            task.cancel()
            await rig.close()
        }

        print("[agent-stream] | 臂 | sleep拍/理想 | display拍/理想 | 30s 收到字符 | 投递块 | UIView min~max | 单帧p95 |")
        print("[agent-stream] |---|---|---|---|---|---|---|")
        for a in arms {
            print(String(format: "[agent-stream] | %@ | %d/%d(%.2f) | %d/%d(%.2f) | %d | %d | %d~%d | %.3fms |",
                         a.name, a.beat.sleepBeats, a.beat.idealSleepBeats, a.beat.sleepRatio,
                         a.beat.displayTicks, a.beat.idealDisplayTicks, a.beat.displayRatio,
                         a.chars, a.delivered, a.viewsMin, a.viewsMax, a.frameP95))
        }
        if arms.count == 2 {
            let ratio = arms[0].beat.displayTicks == 0 ? 0
                : Double(arms[1].beat.displayTicks) / Double(arms[0].beat.displayTicks)
            print(String(format: "[agent-stream] 拍数比值 windowed/legacy = %.2f×（同轮相对比）", ratio))
        }

        // 结构判据：两臂都真的在流（收到过字符 / 拍数非零），否则整条读数作废。
        for a in arms {
            XCTAssertGreaterThan(a.chars, 0, "\(a.name) 30 秒一个字符都没收到 —— 流没跑起来")
            XCTAssertGreaterThan(a.beat.displayTicks, 0, "\(a.name) 渲染循环一拍都没有")
        }
    }

    // MARK: - 3. 一次工具执行：批准 → 完成

    /// 走产品自己的路：屏幕经 `\.agentCommandExecutorFactory` 造执行器 →
    /// 假流吐一张 `run_command` 卡 → 探针调 `model.approveAndRun` →
    /// 假执行器按节拍吐 40 行 → 输出回填卡片 → 完成态。
    ///
    /// 两个读数：**批准到完成的墙钟**，以及**卡片在这段时间里重绘了几次**。
    /// 卡片重绘用一个只观察 `model` 的 `MToolCall` 宿主计数（见 `ToolCardProbeHost`）——
    /// 屏幕里那张卡在 `LazyVStack` 深处，探针够不着它的 body。
    func testToolExecutionEndToEnd() async throws {
        defer { MobileProbeWindow.closeAll() }

        let bench = try makeBench()
        let fake = MobileFakeCommandExecutor(lines: 40, linesPerSecond: 200)
        let callID = "probe-call-1"
        let (model, client, executor) = MobileFakeAgent.toolCallScenario(callID: callID,
                                                                        executor: fake)
        model.attach(context: bench.context)
        defer { model.dispose() }

        let counter = ProbeBodyCounter()
        let rig = MobileProbeRig(label: "tool-exec", size: Self.screen)
        rig.mount(
            VStack(spacing: 0) {
                chat(model, bench: bench, windowLimit: Self.windowedLimit, executor: executor)
                // 计数宿主：只观察 model，渲染产品自己的 `MToolCall`。
                ToolCardProbeHost(model: model, callID: callID, counter: counter)
                    .frame(height: 1).opacity(0.01)
            })
        try await Task.sleep(for: .milliseconds(250))

        // 执行器必须经**注入口**落到状态机上 —— 这一条就是本轮补的注入口的自证。
        XCTAssertNotNil(model.executor, "屏幕没有经 \\.agentCommandExecutorFactory 拿到执行器")
        XCTAssertTrue(model.executor is MobileFakeCommandExecutor, "拿到的不是假执行器")

        // 首轮：短开场白 + 一张 pending 卡。
        let submit = Task { await model.submit(text: "看看日志", serverContext: "probe") }
        let pending = await MobileFakeAgent.waitForToolCall(model, id: callID, in: [.pending])
        XCTAssertNotNil(pending, "假流没有吐出工具调用卡")
        let awaiting = await MobileFakeAgent.waitForState(model) { $0 == .awaitingApproval }
        XCTAssertTrue(awaiting, "状态机没有停在 .awaitingApproval")
        rig.layout()

        let cardBefore = counter.count
        let approveStart = CFAbsoluteTimeGetCurrent()

        // 批准。`approveAndRun` 里 `exec.run` 跑在不随驱动任务取消的 Task 上。
        let run = Task { await model.approveAndRun(id: callID) }

        // 「按节拍回吐」的证人：执行途中假执行器的 `emittedLines` 应当是**中间值**。
        var midFlight = -1
        for _ in 0..<200 {
            try await Task.sleep(for: .milliseconds(4))
            let n = fake.emittedLines
            if n > 0, n < fake.lines { midFlight = n; break }
            if fake.runCount > 0, n >= fake.lines { break }
        }

        let done = await MobileFakeAgent.waitForToolCall(model, id: callID,
                                                         in: [.done, .failed, .skipped])
        let approveMS = (CFAbsoluteTimeGetCurrent() - approveStart) * 1000
        rig.layout()
        let cardRedraws = counter.count - cardBefore

        XCTAssertNotNil(done, "工具调用没有走到终态")
        XCTAssertEqual(done?.status, .done, "应当是 .done（假执行器返回 exit 0）")
        XCTAssertEqual(done?.exitCode, 0)
        XCTAssertEqual(fake.runCount, 1, "执行器应当被调一次")
        XCTAssertFalse(done?.output?.isEmpty ?? true, "输出没有回填进卡片")
        XCTAssertEqual(done?.output?.split(separator: "\n").count, fake.lines,
                       "回填的行数与假执行器吐的行数对不上")

        // 完成后自动续轮 —— 客户端应当开过第二条流，且**不再**吐工具调用（否则死循环）。
        _ = await MobileFakeAgent.waitForState(model, timeout: .seconds(15)) { state in
            state == .idle || state == .streaming
        }
        let shot = await rig.snapshot()
        rig.report(nil, shot, nil)
        attachProbePNG(shot.png, name: "tool-exec")

        print(String(format: "[agent-tool] 批准→完成 %.1fms（%d 行 @ %.0f 行/s，理想 %.0fms）"
                     + " 卡片重绘 %d 次 中途行数=%d 续轮流=%d views=%d",
                     approveMS, fake.lines, fake.linesPerSecond,
                     Double(fake.lines) / fake.linesPerSecond * 1000,
                     cardRedraws, midFlight, client.streamCount, shot.views))

        XCTAssertGreaterThan(midFlight, 0, "执行器是瞬间返回的 —— 节拍没生效，端到端读数不成立")
        XCTAssertGreaterThan(cardRedraws, 0, "卡片一次都没重绘 —— 计数宿主没接上")
        XCTAssertLessThanOrEqual(client.streamCount, 2, "续轮吐了工具调用，会无限循环")

        submit.cancel(); run.cancel()
        await rig.close()
    }

    /// 失败 / 超时 / 取消三条负路径 —— 注入口要能表达它们，不然「可失败」只是句空话。
    func testToolExecutionFailureAndCancellation() async throws {
        defer { MobileProbeWindow.closeAll() }

        // ① 失败：吐 6 行后抛。卡片应当落到 .failed，输出里带错误文本。
        do {
            let bench = try makeBench()
            let fake = MobileFakeCommandExecutor(
                lines: 40, linesPerSecond: 400,
                outcome: .failure(message: "connection reset by peer", afterLines: 6))
            let callID = "probe-fail"
            let (model, _, executor) = MobileFakeAgent.toolCallScenario(callID: callID, executor: fake)
            model.attach(context: bench.context)
            defer { model.dispose() }
            let rig = MobileProbeRig(label: "tool-fail", size: Self.screen)
            rig.mount(chat(model, bench: bench, windowLimit: Self.windowedLimit, executor: executor))
            try await Task.sleep(for: .milliseconds(200))

            let submit = Task { await model.submit(text: "看看日志", serverContext: "probe") }
            _ = await MobileFakeAgent.waitForToolCall(model, id: callID, in: [.pending])
            // 必须等到 `.awaitingApproval`：`approveAndRun` 有门禁，流还在飞时点它是 no-op，
            // 卡片会永远停在 pending（这一条曾把超时臂拖成 10 秒假红）。
            let ready = await MobileFakeAgent.waitForState(model) { $0 == .awaitingApproval }
            XCTAssertTrue(ready, "状态机没有停在 .awaitingApproval")
            let start = CFAbsoluteTimeGetCurrent()
            let run = Task { await model.approveAndRun(id: callID) }
            let call = await MobileFakeAgent.waitForToolCall(model, id: callID, in: [.failed, .done])
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print(String(format: "[agent-tool-fail] %.1fms status=%@ output=%@",
                         ms, String(describing: call?.status),
                         (call?.output ?? "").prefix(60).description))
            XCTAssertEqual(call?.status, .failed, "抛错的命令应当落到 .failed")
            XCTAssertTrue((call?.output ?? "").contains("connection reset"),
                          "错误文本没有折回卡片")
            XCTAssertEqual(fake.emittedLines, 6, "应当在第 6 行上抛")
            submit.cancel(); run.cancel()
            await rig.close()
        }

        // ② 超时：假执行器一直不返回，探针把驱动 Task 取消掉。
        //    注意 `approveAndRun` 里那条 `exec.run` 的 Task **不随驱动取消**
        //    （产品有意为之：命令已经发出去了），所以这里断言的是「超时抛错
        //    最终落到 .failed」，而不是「取消立刻生效」。
        do {
            let bench = try makeBench()
            let fake = MobileFakeCommandExecutor(outcome: .timeout(after: .milliseconds(600)))
            let callID = "probe-timeout"
            let (model, _, executor) = MobileFakeAgent.toolCallScenario(callID: callID, executor: fake)
            model.attach(context: bench.context)
            defer { model.dispose() }
            let rig = MobileProbeRig(label: "tool-timeout", size: Self.screen)
            rig.mount(chat(model, bench: bench, windowLimit: Self.windowedLimit, executor: executor))
            try await Task.sleep(for: .milliseconds(200))

            let submit = Task { await model.submit(text: "看看日志", serverContext: "probe") }
            _ = await MobileFakeAgent.waitForToolCall(model, id: callID, in: [.pending])
            // 必须等到 `.awaitingApproval`：`approveAndRun` 有门禁，流还在飞时点它是 no-op，
            // 卡片会永远停在 pending（这一条曾把超时臂拖成 10 秒假红）。
            let ready = await MobileFakeAgent.waitForState(model) { $0 == .awaitingApproval }
            XCTAssertTrue(ready, "状态机没有停在 .awaitingApproval")
            let start = CFAbsoluteTimeGetCurrent()
            let run = Task { await model.approveAndRun(id: callID) }
            let call = await MobileFakeAgent.waitForToolCall(model, id: callID,
                                                             in: [.failed, .done], timeout: .seconds(10))
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print(String(format: "[agent-tool-timeout] %.1fms status=%@ output=%@",
                         ms, String(describing: call?.status),
                         (call?.output ?? "").prefix(60).description))
            XCTAssertEqual(call?.status, .failed, "超时应当落到 .failed")
            XCTAssertGreaterThan(ms, 500, "超时档必须真的等满")
            submit.cancel(); run.cancel()
            await rig.close()
        }
    }

    // MARK: - 4. 会话历史菜单

    /// 顶栏「⋯ → 历史会话」下拉的打开耗时。
    ///
    /// 屏幕侧的 `@Query(ChatSessionQueries.recent)` 已经钉了 `fetchLimit`
    /// （见 `docs/scroll-perf-findings.md`「Agent 会话历史下拉」），这条探针
    /// 量的是「钉住之后打开还要多久」，并**同轮**跟无界取数对照，
    /// 证明 `fetchLimit` 确实还在起作用（回归闸门）。
    func testSessionHistoryMenuOpenCost() async throws {
        defer { MobileProbeWindow.closeAll() }

        // 极端档：1000 条会话。只读，走共享容器。
        let container = try MobileFixtures.shared("agent-sessions-extreme", seed: .extreme)
        let context = container.mainContext

        // 取数两臂（同一份库、同一轮）：钉住 vs 无界。
        func fetchMS(_ descriptor: FetchDescriptor<ChatSession>) throws -> (Double, Int) {
            let start = CFAbsoluteTimeGetCurrent()
            let rows = try context.fetch(descriptor)
            return ((CFAbsoluteTimeGetCurrent() - start) * 1000, rows.count)
        }
        var unbounded = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        unbounded.fetchLimit = nil

        // 先跑一次热身，把 SwiftData 的一次性开销吃掉，两臂才可比。
        _ = try fetchMS(ChatSessionQueries.recent)

        let (pinnedMS, pinnedRows) = try fetchMS(ChatSessionQueries.recent)
        let (freeMS, freeRows) = try fetchMS(unbounded)
        print(String(format: "[agent-sessions] 取数 钉住 %.2fms/%d 条 · 无界 %.2fms/%d 条（%.1f×）",
                     pinnedMS, pinnedRows, freeMS, freeRows,
                     pinnedMS == 0 ? 0 : freeMS / pinnedMS))
        XCTAssertLessThanOrEqual(pinnedRows, ChatSessionQueries.recentLimit,
                                 "fetchLimit 没起作用 —— 下拉又变回全表")
        XCTAssertGreaterThan(freeRows, pinnedRows, "对照臂应当取到更多行，否则库里没数据")

        // 挂真屏幕，量「菜单出现在视图树里」这一下。菜单内容是懒建的（`Menu` 的 label
        // 先建，内容在点开时才求值），所以这里量的是：把 20 条 `Button` 的菜单内容
        // 建出来要多久 —— 用直接构造菜单内容视图的方式（`Menu` 的点击没法在
        // unit test bundle 里合成，README「四条滚动驱动」同因）。
        let bench = try makeBench()
        let sessions = try context.fetch(ChatSessionQueries.recent)
        let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                   provider: bench.provider, apiKey: "sk-probe")
        defer { model.dispose() }

        let rig = MobileProbeRig(label: "sessions-menu", size: Self.screen)
        let mountMS = rig.mount(
            SessionMenuProbeHost(sessions: Array(sessions.prefix(20)), model: model)
                .environment(\.mAccent, M.accent))
        let shot = await rig.snapshot()
        rig.report(nil, shot, nil)
        attachProbePNG(shot.png, name: "sessions-menu")
        print(String(format: "[agent-sessions] 菜单内容挂载 %.2fms（%d 条）views=%d ink=%.4f",
                     mountMS, min(sessions.count, 20), shot.views, shot.ink))
        XCTAssertGreaterThan(shot.views, 0)
        XCTAssertGreaterThan(shot.ink, 0, "菜单内容是空壳 —— 挂载读数不成立")
        await rig.close()
    }
}

// MARK: - 计数宿主

/// 采样盒：把局部数组换成引用类型，逃逸闭包里改写才不判数据竞争。
@MainActor
final class ProbeIntBag {
    var values: [Int] = []
}

/// SwiftUI body 求值计数器。
@MainActor
final class ProbeBodyCounter {
    private(set) var count = 0
    func bump() { count += 1 }
    func reset() { count = 0 }
}

/// 只观察 `AssistantModel` 的 `MToolCall` 宿主 —— 用来数「一次执行里卡片重绘几次」。
///
/// 为什么不直接数屏幕里那张卡：它在 `MobileAgentChat` 的 `LazyVStack` 深处，
/// 是 `messageRow(_:)` 里内联构造的，探针够不着它的 body，产品侧也不该为探针开洞。
/// 这个宿主吃的是**同一份 `@Observable` 依赖**（`model.messages` 里那条
/// `ToolCallState`），走的是**同一个产品视图**（`MToolCall`），所以它的重绘次数
/// 与屏幕里那张卡同源。
private struct ToolCardProbeHost: View {
    @Bindable var model: AssistantModel
    let callID: String
    let counter: ProbeBodyCounter

    var body: some View {
        counter.bump()
        let call = model.messages.flatMap(\.toolCalls).first { $0.id == callID }
        let status: MToolCall.Status = {
            switch call?.status {
            case .running: return .running
            case .done, .failed, .skipped: return .done(output: call?.output)
            default: return .pending
            }
        }()
        return MToolCall(label: call?.explanation ?? "运行命令",
                         command: call?.command ?? "",
                         status: status)
    }
}

/// 会话历史下拉的**内容**（`Menu` 点开后才求值的那一段）单独挂出来量。
/// `Menu` 的点击在 unit test bundle 里合成不了（没有 `XCUIElement`），
/// 所以按 README「四条滚动驱动」的同一条思路：绕过手势，直接量真正贵的那部分。
private struct SessionMenuProbeHost: View {
    let sessions: [ChatSession]
    @Bindable var model: AssistantModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sessions) { s in
                Button { model.load(s) } label: {
                    Label(s.title.isEmpty ? "新对话" : s.title,
                          systemImage: model.currentSession?.id == s.id ? "checkmark" : "")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
