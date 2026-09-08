import AgentKit
import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 数据夹具的**自证**用例 —— 这里不评判任何 uTermMobile 视图的性能。
///
/// 被测对象是 `MobileFixtures` / `MobileFakeSFTP` / `MobileFakeAgent` /
/// `MobileFakeParallelRun` 四件夹具本身：播出来的东西是不是真的进了库、
/// 假目录列不列得出、假流按不按节拍吐、假并行的行数对不对得上。
///
/// 断言全部是**结构判据**（条数、前缀关系、类型分布），对机器负载免疫；
/// 播种耗时只 `print`，不当闸门（playbook §一）。
///
/// 隔离：`uTermMobileTests` 默认 `nonisolated`，所以整类 `@MainActor`，
/// 且**不覆写 `tearDown()`**（见 README「隔离」一节）。
@MainActor
final class MobileFixturesTests: XCTestCase {

    /// 拆窗只走 `MobileProbeWindow.closeAll()` 这一个入口 —— 它同时负责把
    /// `isolateHost` 压过的宿主窗口层级抬回去。这里曾经自己攒了一个 `windows`
    /// 数组、逐扇 `close(_:)`，宿主层级从此没人复原，全量跑一次就把
    /// `ProbeRigSelfTests.testCloseAllTearsDownAndRestoresHost` 拖红了
    /// （见 README「夹具跨用例契约」）。
    private func closeAllWindows() {
        MobileProbeWindow.closeAll()
    }

    // MARK: - 1. 播种：@Query / fetch 数量对得上

    func testSeedSmokeCountsMatch() throws {
        let seed = MobileFixtures.Seed.smoke
        let container = try MobileFixtures.emptyContainer()
        let counts = MobileFixtures.populate(container, seed: seed)

        print("[fixtures] smoke 播种 \(String(format: "%.1f", counts.elapsedMS))ms")
        assertStoreMatches(container, seed: seed, counts: counts)

        // 分布：三条「探针要它非空」的性质。
        XCTAssertGreaterThan(counts.keyBackedServers, 0, "必须有主机指向密钥，密钥页 usedCount 才非零")
        XCTAssertGreaterThan(counts.connectedServers, 0, "必须有主机连过，「最近」段才有内容")
        XCTAssertLessThan(counts.connectedServers, seed.servers, "也必须有从没连过的主机")
    }

    func testSeedRealisticCountsMatch() throws {
        let seed = MobileFixtures.Seed.realistic
        let container = try MobileFixtures.emptyContainer()
        let counts = MobileFixtures.populate(container, seed: seed)

        print("[fixtures] realistic（100 台 / 10 组 / 20 密钥 / 50 命令 / 200 日志 / 50 会话）"
              + " 播种 \(String(format: "%.1f", counts.elapsedMS))ms")
        assertStoreMatches(container, seed: seed, counts: counts)

        // 运行日志：成功 / 失败混排，且 aiRecord 真的能解码回来。
        let runs = try container.mainContext.fetch(FetchDescriptor<QuickCommandRun>())
        XCTAssertGreaterThan(runs.filter { !$0.allSucceeded }.count, 0, "必须有失败的运行")
        XCTAssertGreaterThan(runs.filter { $0.allSucceeded }.count, 0, "必须有成功的运行")
        XCTAssertGreaterThan(runs.filter { $0.aiRecord != nil }.count, 0, "必须有带 AI 介入记录的运行")
        for run in runs.prefix(20) {
            XCTAssertFalse(run.results.isEmpty, "results JSON 必须解得出内容")
        }
        // 30 天窗口。
        let oldest = runs.map(\.startedAt).min() ?? Date()
        XCTAssertGreaterThan(oldest.timeIntervalSinceNow, -Double(seed.runWindowDays + 1) * 86_400,
                             "运行日志必须落在 \(seed.runWindowDays) 天窗口内")

        // 会话：updatedAt 严格递减（`@Query(order: .reverse)` 的排序前提）。
        let sessions = try container.mainContext.fetch(
            FetchDescriptor<ChatSession>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        XCTAssertEqual(sessions.count, seed.sessions)
        for i in 1..<sessions.count {
            XCTAssertLessThan(sessions[i].updatedAt, sessions[i - 1].updatedAt)
        }
        XCTAssertEqual(sessions.first?.orderedMessages.count, seed.messagesPerSession)

        // 分组颜色：全部来自产品自己的 10 色板。
        let groups = try container.mainContext.fetch(FetchDescriptor<ServerGroup>())
        for g in groups {
            XCTAssertTrue(ServerGroup.palette.contains(g.colorHex), "组色必须来自 GROUP_COLORS")
        }
    }

    func testSeedExtremeCountsMatch() throws {
        let seed = MobileFixtures.Seed.extreme
        let container = try MobileFixtures.emptyContainer()
        let counts = MobileFixtures.populate(container, seed: seed)

        print("[fixtures] extreme（2000 台 / 60 组 / 50 密钥 / 300 命令 / 3000 日志 / 1000 会话）"
              + " 播种 \(String(format: "%.1f", counts.elapsedMS))ms"
              + "，消息 \(counts.messages) 条")
        assertStoreMatches(container, seed: seed, counts: counts)
    }

    /// 同一份 `Seed` 播两次，逐字段一致 —— 确定性是前→后对照的前提。
    func testSeedIsDeterministic() throws {
        let seed = MobileFixtures.Seed.smoke
        let a = try MobileFixtures.emptyContainer()
        let b = try MobileFixtures.emptyContainer()
        MobileFixtures.populate(a, seed: seed)
        MobileFixtures.populate(b, seed: seed)

        let sortByOrder = [SortDescriptor(\ServerProfile.sortOrder)]
        let one = try a.mainContext.fetch(FetchDescriptor<ServerProfile>(sortBy: sortByOrder))
        let two = try b.mainContext.fetch(FetchDescriptor<ServerProfile>(sortBy: sortByOrder))
        XCTAssertEqual(one.count, two.count)
        for (x, y) in zip(one, two) {
            XCTAssertEqual(x.name, y.name)
            XCTAssertEqual(x.host, y.host)
            XCTAssertEqual(x.sftpOnly, y.sftpOnly)
            XCTAssertEqual(x.group, y.group)
            XCTAssertEqual(x.lastConnectedAt == nil, y.lastConnectedAt == nil)
        }
    }

    /// 共享容器：同一个 key 只播一次，第二次是同一个实例（省掉 extreme 档的几秒）。
    func testSharedContainerIsMemoized() throws {
        let first = try MobileFixtures.shared("fixtures-selftest", seed: .smoke)
        let start = CFAbsoluteTimeGetCurrent()
        let second = try MobileFixtures.shared("fixtures-selftest", seed: .smoke)
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[fixtures] 共享容器二次取用 \(String(format: "%.3f", ms))ms")
        XCTAssertTrue(first === second, "同 key 必须是同一个容器实例")
        XCTAssertEqual(MobileFixtures.count(ServerProfile.self, in: second),
                       MobileFixtures.Seed.smoke.servers)
    }

    /// `@Query` 那一侧真的读得到（不 `save()` 的话这条会红）。
    func testSeededStoreIsVisibleToQuery() throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        defer { closeAllWindows() }

        // 静态哨兵每次归零：不归零的话「视图压根没 onAppear」会被上一轮的残值盖过去，
        // 断言变成假绿（夹具跨用例契约：进程内 static 必须由用它的那条用例自己复位）。
        QueryCountProbe.lastSeenServers = -1
        let probe = QueryCountProbe()
        let (_, host) = MobileProbeWindow.make(
            size: CGSize(width: 390, height: 700),
            rootView: AnyView(probe.modelContainer(container)))
        host.view.layoutIfNeeded()
        CATransaction.flush()

        XCTAssertEqual(QueryCountProbe.lastSeenServers, MobileFixtures.Seed.smoke.servers,
                       "@Query 必须看得到播种数据 —— 数不上说明 populate 漏了 save()")
    }

    // MARK: - 2. 假 SFTP：20000 条能列出，子目录可进

    func testFakeSFTPListsExtremeDirectory() async throws {
        for count in [500, 20_000] {
            let provider = MobileFakeSFTPProvider(entries: count)
            let start = CFAbsoluteTimeGetCurrent()
            let entries = try await provider.list(path: "/")
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[fixtures] 假 SFTP \(count) 条列目录 \(String(format: "%.1f", ms))ms")

            XCTAssertEqual(entries.count, count)
            XCTAssertEqual(Set(entries.map(\.name)).count, count, "文件名必须互不相同（Identifiable 按 name）")
            // 类型分布：目录 / 普通文件 / 符号链接都要有。
            XCTAssertGreaterThan(entries.filter(\.isSymlink).count, 0)
            XCTAssertGreaterThan(entries.filter { !$0.isDirectory && !$0.isSymlink }.count, 0)
            // 名字长短散开：最短 < 12 字符，最长 > 60 字符。
            let lengths = entries.map(\.name.count)
            XCTAssertLessThan(lengths.min() ?? 99, 12)
            XCTAssertGreaterThan(lengths.max() ?? 0, 60)
            // 大小与权限也要散开。
            XCTAssertGreaterThan(Set(entries.compactMap(\.permissions)).count, 2)
            XCTAssertGreaterThan(entries.compactMap(\.size).max() ?? 0, 1_000_000_000)
        }
    }

    func testFakeSFTPSubdirectoriesAreEnterable() async throws {
        let provider = MobileFakeSFTPProvider(entries: 200, subdirectories: 6,
                                              childCount: 40, depth: 3)
        let controller = await MobileFakeSFTP.controller(provider: provider)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.path, "/")
        XCTAssertEqual(controller.entries.count, 200)
        // 产品的排序：目录在前。
        XCTAssertTrue(controller.entries[0].isDirectory)

        let dir = try XCTUnwrap(controller.entries.first { $0.isDirectory })
        let child = await MobileFakeSFTP.enter(controller, provider: provider, path: "/\(dir.name)")
        XCTAssertEqual(child.count, 40, "子目录必须真的进得去")
        XCTAssertEqual(controller.path, "/\(dir.name)")

        await MobileFakeSFTP.goUp(controller, provider: provider)
        XCTAssertEqual(controller.path, "/")
        XCTAssertEqual(controller.entries.count, 200)
        // 每次换目录正好一次 list（外加建控制器时的那一次）。
        let listCalls = await provider.listCallCount
        XCTAssertEqual(listCalls, 3, "每次换目录正好一次 list")
    }

    /// 假会话现在实现的是产品协议 `SFTPProviding`，控制器的写路径也真的落到树上。
    func testFakeSFTPMutationsGoThroughController() async throws {
        let provider = MobileFakeSFTPProvider(entries: 40)
        let controller = await MobileFakeSFTP.controller(provider: provider)
        XCTAssertEqual(controller.entries.count, 40)

        // 1. 重命名：产品的 `rename` → 假会话改树 → 产品自己重列目录。
        let target = try XCTUnwrap(controller.entries.first { $0.isRegularFileForProbe })
        controller.rename(target, to: "renamed-by-probe.bin")
        try await MobileFakeSFTP.settle("重命名后列表刷新") {
            controller.entries.contains { $0.name == "renamed-by-probe.bin" }
        }
        XCTAssertEqual(controller.entries.count, 40, "改名不改条目数")
        XCTAssertFalse(controller.entries.contains { $0.name == target.name })

        // 2. chmod：低 9 位真的变了，文件类型位保留。
        let renamed = try XCTUnwrap(controller.entries.first { $0.name == "renamed-by-probe.bin" })
        controller.chmod(renamed, mode: 0o600)
        try await MobileFakeSFTP.settle("chmod 后列表刷新") {
            (controller.entries.first { $0.name == "renamed-by-probe.bin" }?
                .permissions ?? 0) & 0o777 == 0o600
        }

        // 3. 删除：条目数真的少一条。
        let victim = try XCTUnwrap(controller.entries.first { $0.name == "renamed-by-probe.bin" })
        controller.delete(victim)
        try await MobileFakeSFTP.settle("删除后列表刷新") { controller.entries.count == 39 }
        XCTAssertFalse(controller.entries.contains { $0.name == "renamed-by-probe.bin" })

        // 4. 上传 + 下载往返：产品的 upload(from:) / download(_:) 都真的走通。
        let payload = Data((0..<8_192).map { UInt8($0 % 251) })
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-upload-\(UUID().uuidString).bin")
        try payload.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        controller.upload(from: localURL)
        try await MobileFakeSFTP.settle("上传后列表刷新") {
            controller.entries.contains { $0.name == localURL.lastPathComponent }
        }
        let uploaded = try XCTUnwrap(
            controller.entries.first { $0.name == localURL.lastPathComponent })
        let downloadedURL = await controller.download(uploaded)
        let downloaded = try XCTUnwrap(downloadedURL)
        XCTAssertEqual(try Data(contentsOf: downloaded), payload, "上传下载必须字节一致")

        // 5. 失败注入：删除失败要落到 `.failed` 态。
        await provider.inject(.removeFile, message: "权限不足")
        let another = try XCTUnwrap(controller.entries.first { $0.isRegularFileForProbe })
        controller.delete(another)
        try await MobileFakeSFTP.settle("失败注入后进入 failed 态") {
            if case .failed = controller.state { return true }
            return false
        }
    }

    /// 目录进出走产品的 `open` / `goUp`（发射后不管的 `Task`），不再靠夹具回填。
    func testControllerOpenAndGoUpUseProductPath() async throws {
        let provider = MobileFakeSFTPProvider(entries: 120, subdirectories: 4,
                                              childCount: 30, depth: 2)
        let controller = await MobileFakeSFTP.controller(provider: provider)
        let dir = try XCTUnwrap(controller.entries.first { $0.isDirectory })

        controller.open(dir)
        try await MobileFakeSFTP.settle("进子目录") { controller.path == "/\(dir.name)" }
        XCTAssertEqual(controller.entries.count, 30)

        controller.goUp()
        try await MobileFakeSFTP.settle("返回上级") { controller.path == "/" }
        XCTAssertEqual(controller.entries.count, 120)
    }

    /// 时延档：50ms 的假网络真的会 sleep。
    func testFakeSFTPLatencyIsHonored() async throws {
        let provider = MobileFakeSFTPProvider(entries: 20, latency: .milliseconds(50))
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await provider.list(path: "/")
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[fixtures] 假 SFTP 50ms 时延档实测 \(String(format: "%.1f", ms))ms")
        XCTAssertGreaterThan(ms, 40)
    }

    /// `SFTPScreen` 能用假会话挂起 500 / 20000 两档 —— 且**不发起任何真实连接**。
    func testSFTPScreenMountsFakeSession() async throws {
        for count in [500, 20_000] {
            let container = try MobileFixtures.modelContainer(seed: .smoke)
            let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
            let provider = MobileFakeSFTPProvider(entries: count)
            let session = await MobileFakeSFTP.session(host: host, provider: provider)
            defer { closeAllWindows() }   // 每档一拆窗（playbook：拆窗才不背上一档的账）

            let store = MobileStore()
            store.sftpTarget = host.persistentModelID
            store.tab = .sftp

            let root = AnyView(
                SFTPScreen()
                    .environment(store)
                    .environment(HostKeyChallengeRelay())
                    .environment(session)
                    .modelContainer(container))
            let start = CFAbsoluteTimeGetCurrent()
            let (_, hostVC) = MobileProbeWindow.make(
                size: CGSize(width: 390, height: 844), rootView: root)
            hostVC.view.layoutIfNeeded()
            CATransaction.flush()
            let mountMS = (CFAbsoluteTimeGetCurrent() - start) * 1000

            // 关键断言：屏幕挂载没有把控制器换掉、也没有触发 start()。
            // `activeTarget` 预设成与 `store.sftpTarget` 相等，`consumeSFTPTarget` 整条跳过。
            XCTAssertEqual(session.activeTarget, host.persistentModelID)
            XCTAssertEqual(session.controller.state, .connected)
            XCTAssertEqual(session.controller.entries.count, count)
            let scroll = try XCTUnwrap(hostVC.view.firstScrollView(),
                                       "浏览态必须有 UIScrollView（列表真的挂上了）")
            // 行高 56pt（`SFTPRow`），内容高度必须随条数线性涨 —— 结构判据。
            XCTAssertEqual(scroll.contentSize.height, CGFloat(count) * 56, accuracy: 1)
            print("[fixtures] SFTPScreen 挂 \(count) 条：挂载 \(String(format: "%.1f", mountMS))ms "
                  + "contentHeight=\(Int(scroll.contentSize.height)) "
                  + "views=\(hostVC.view.recursiveViewCount())")
        }
    }

    // MARK: - 3. 假 Agent：3 秒按节拍追加

    func testFakeAgentStreamsAtConfiguredRate() async throws {
        let seconds = 3.0
        let rate = 20.0
        // 多备一倍块，好让 3 秒切断时流还没吐完 —— 否则量到的是「吐完了」不是「节拍」。
        let chunks = MobileFakeAgent.pacedChunks(seconds: seconds * 2, chunksPerSecond: rate)
        let (model, client) = MobileFakeAgent.streamingModel(chunks: chunks, chunksPerSecond: rate)
        defer { model.dispose() }

        model.input = "帮我看看这台机器"
        let task = Task { await model.send(serverContext: "probe") }
        try await Task.sleep(for: .seconds(seconds))

        let delivered = client.deliveredChunks
        let expected = Int(seconds * rate)
        print("[fixtures] 假 Agent 流 \(seconds)s @ \(Int(rate))chunk/s：投递 \(delivered) 块"
              + "（理想 \(expected)），模型文本 \(model.messages.last?.text.count ?? 0) 字符")

        XCTAssertEqual(model.state, .streaming, "3 秒时流还应该在跑")
        // 节拍闸门放宽到 [0.5x, 1.2x]：`Task.sleep` 只保证「不早于」，
        // 模拟器上偏慢是常态，偏快则不可能。
        XCTAssertGreaterThan(delivered, Int(Double(expected) * 0.5))
        XCTAssertLessThanOrEqual(delivered, Int(Double(expected) * 1.2))

        // 前缀关系：模型里的文本必须是「已投递块拼起来」的前缀
        // （`StreamingTextBuffer` 每 50ms 发布一次，最多落后一块）。
        let text = model.messages.last?.text ?? ""
        XCTAssertTrue(client.deliveredText.hasPrefix(text) || text.hasPrefix(client.deliveredText),
                      "模型文本与已投递文本必须同源")
        XCTAssertFalse(text.isEmpty)

        task.cancel()
        _ = await task.result
    }

    /// Markdown 语料真的含代码块 / 表格 / 列表 / 标题。
    func testFakeAgentMarkdownHasAllBlockKinds() {
        let md = MobileFakeAgent.assistantMarkdown(index: 7)
        XCTAssertTrue(md.contains("```bash"), "必须有代码块")
        XCTAssertTrue(md.contains("| 指标 |"), "必须有表格")
        XCTAssertTrue(md.contains("\n- "), "必须有列表")
        XCTAssertTrue(md.contains("### "), "必须有标题")
        // 切块不丢字符。
        let pieces = MobileFakeAgent.chunks(md, size: 24)
        XCTAssertEqual(pieces.joined(), md)
        XCTAssertGreaterThan(pieces.count, 10)
    }

    func testFakeAgentReplaysHistory() throws {
        for count in [200, 1_000] {
            let container = try MobileFixtures.emptyContainer()
            let context = container.mainContext
            context.autosaveEnabled = false
            let model = AssistantModel(client: MobilePacedLLMClient(chunks: []),
                                       provider: MobileFakeAgent.provider(),
                                       apiKey: "sk-probe")
            model.attach(context: context)

            let start = CFAbsoluteTimeGetCurrent()
            let session = MobileFakeAgent.replayHistory(into: model, context: context,
                                                        messages: count)
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
            print("[fixtures] 假 Agent 回放 \(count) 条历史 \(String(format: "%.1f", ms))ms")

            XCTAssertEqual(model.messages.count, count)
            XCTAssertEqual(session.orderedMessages.count, count)
            XCTAssertEqual(model.messages.first?.role, .user)
            XCTAssertEqual(model.messages[1].role, .assistant)
            // 每 8 条挂一个工具调用。
            XCTAssertGreaterThan(model.messages.filter { !$0.toolCalls.isEmpty }.count, count / 10)
            // 每条 assistant 回复 ~36 块。
            let blocks = model.messages[1].text.components(separatedBy: "\n\n").count
            XCTAssertGreaterThanOrEqual(blocks, 30)
            model.dispose()
        }
    }

    // MARK: - 4. 假并行执行：行数对得上

    func testFakeParallelRunEmitsExpectedLines() {
        let config = MobileFakeParallelRun.Config.standard(hosts: 8, failing: 3)
        let run = MobileFakeParallelRun(config: config)
        XCTAssertEqual(config.outputLinesPerHost, 500, "50 行/秒 × 10 秒 = 500 行")

        let start = CFAbsoluteTimeGetCurrent()
        let total = run.emitAll()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("[fixtures] 假并行 8 台 × 500 行 生成 \(String(format: "%.1f", ms))ms，合计 \(total) 行")

        XCTAssertEqual(run.total, 8)
        XCTAssertEqual(total, 8 * config.totalLinesPerHost)
        for state in run.states {
            XCTAssertEqual(state.lines.count, config.totalLinesPerHost)
            XCTAssertEqual(state.lines.first?.kind, .cmd, "首行必须是命令，与 runLane 一致")
        }
        XCTAssertEqual(run.failedCount, 3)
        XCTAssertEqual(run.okCount, 5)
        XCTAssertTrue(run.allDone)
        // 退出码语义：失败台非 0、成功台 0。
        for (i, state) in run.states.enumerated() {
            XCTAssertEqual(state.exitCode == 0, i >= 3)
            XCTAssertNotNil(state.durationMs)
        }
        // 四种行类型都出现过。
        let kinds = Set(run.states[0].lines.map(\.kind).map(String.init(describing:)))
            .union(Set(run.states[0].lines.map(\.kind).map(String.init(describing:))))
        XCTAssertGreaterThanOrEqual(kinds.count, 3)
    }

    /// 真实节拍档：跑 1 秒，行数落在 50 行/秒的合理区间。
    func testFakeParallelRunRealTimePacing() async throws {
        let config = MobileFakeParallelRun.Config(hosts: 4, linesPerSecond: 50,
                                                  duration: .seconds(10), failingHosts: 1)
        let run = MobileFakeParallelRun(config: config)
        run.start()
        try await Task.sleep(for: .seconds(1))
        run.stop()

        let produced = (run.states[0].lines.count) - 1   // 减掉首行 cmd
        print("[fixtures] 假并行真实节拍 1s：每台 \(produced) 行（理想 50）")
        XCTAssertGreaterThan(produced, 25, "节拍太慢")
        XCTAssertLessThanOrEqual(produced, 60, "节拍不该超发")
        XCTAssertFalse(run.allDone, "提前 stop 不该收尾")
        XCTAssertEqual(run.states[0].tone, .running)
    }

    /// 用真主机造泳道（`ServerProfile` 的名字 / 端点要如实带过去）。
    func testFakeParallelRunUsesSeededHosts() throws {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let hosts = try container.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)]))
        let run = MobileFakeParallelRun(config: .standard(hosts: 5), targets: hosts)
        XCTAssertEqual(run.total, 5)
        XCTAssertEqual(run.states.map(\.name), hosts.prefix(5).map(\.name))
        XCTAssertEqual(run.states[0].endpointDisplay, "\(hosts[0].username)@\(hosts[0].host)")
    }

    // MARK: - 公共断言

    private func assertStoreMatches(_ container: ModelContainer,
                                    seed: MobileFixtures.Seed,
                                    counts: MobileFixtures.Counts) {
        XCTAssertEqual(MobileFixtures.count(ServerProfile.self, in: container), seed.servers)
        XCTAssertEqual(MobileFixtures.count(ServerGroup.self, in: container), seed.groups)
        XCTAssertEqual(MobileFixtures.count(SSHKey.self, in: container), seed.keys)
        XCTAssertEqual(MobileFixtures.count(QuickCommand.self, in: container), seed.commands)
        XCTAssertEqual(MobileFixtures.count(QuickCommandRun.self, in: container), seed.runs)
        XCTAssertEqual(MobileFixtures.count(ChatSession.self, in: container), seed.sessions)
        XCTAssertEqual(MobileFixtures.count(ChatMessageRecord.self, in: container),
                       seed.sessions * seed.messagesPerSession)
        XCTAssertEqual(MobileFixtures.count(KnownHost.self, in: container), seed.knownHosts)
        XCTAssertEqual(MobileFixtures.count(ForwardingRule.self, in: container), seed.forwardingRules)

        // Counts 与库里实际条数是同一个数（返回值可直接当断言依据）。
        XCTAssertEqual(counts.servers, seed.servers)
        XCTAssertEqual(counts.runs, seed.runs)
        XCTAssertEqual(counts.messages, seed.sessions * seed.messagesPerSession)
    }
}

/// `@Query` 的读数出口 —— SwiftUI 视图里读到的条数写进静态变量，
/// 好在测试里断言「视图那一侧真的看得见」。
private struct QueryCountProbe: View {
    nonisolated(unsafe) static var lastSeenServers = -1

    @Query private var servers: [ServerProfile]

    var body: some View {
        Text("\(servers.count)")
            .onAppear { Self.lastSeenServers = servers.count }
    }
}
