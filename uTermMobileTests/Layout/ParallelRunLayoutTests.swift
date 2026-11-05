import AgentKit
import Foundation
import SwiftData
import SwiftUI
import XCTest
@testable import uTermMobile

/// 并行执行页的大屏 / 窄屏版式：大屏 Shell 每页 2×2 横向翻页，窄屏保持一列。
///
/// 每档附一张截图（xcresult 附件）；设了 `TEST_RUNNER_PARALLEL_SHOT_DIR` 时另存一份 PNG 到该目录，
/// 方便直接打开看。
@MainActor
final class ParallelRunLayoutTests: XCTestCase {

    /// iPhone Pro Max 横屏近似（超过 `ParallelRunView.wideThreshold`）。
    private let wideSize = CGSize(width: 932, height: 430)
    private let narrowSize = CGSize(width: 390, height: 780)
    /// iPad mini / iPhone Duo 展开横屏近似：输出区够放两行。
    private let tallWideSize = CGSize(width: 1024, height: 700)

    /// 输出区够高（iPad / Duo 展开横屏）：2×2 一页。
    func testTallWideShellPagesFourPerPage() async throws {
        try await assertPages(size: tallWideSize, hosts: 12, expectedPages: 3, overflows: false,
                              label: "par-wide-shell")
    }

    /// 手机横屏（430pt 高）：两行的话每格只露三四行输出，退成一行两台。
    func testShortWideShellPagesTwoPerPage() async throws {
        try await assertPages(size: wideSize, hosts: 12, expectedPages: 6, overflows: true,
                              label: "par-wide-short-shell")
    }

    /// - Parameter overflows: 这一档的格子是否矮到装不下输出（装不下才量得到贴底）。
    private func assertPages(size: CGSize, hosts: Int, expectedPages: Int, overflows: Bool,
                             label: String) async throws {
        let screen = try makeScreen(hosts: hosts, aiAssisted: false, size: size, label: label)
        defer { screen.controller.cancel() }
        try await waitUntilDone(screen.controller)
        try await Task.sleep(for: .milliseconds(300))
        screen.rig.layout()

        let pager = try XCTUnwrap(scrollViews(in: screen.rig.hostView).first {
            $0.contentSize.width > $0.bounds.width + 1
        }, "大屏 Shell 应当是横向翻页的 ScrollView")
        XCTAssertEqual(pager.contentSize.width, pager.bounds.width * CGFloat(expectedPages), accuracy: 2,
                       "\(hosts) 台应为 \(expectedPages) 页")
        // 格内贴底：每格的纵向 ScrollView 停在最底部（看得到最新输出）。
        // 按 adjustedContentInset 算：格子挨着底栏时，系统会给滚动视图加上底栏那段内边距。
        func maxOffset(_ v: UIScrollView) -> CGFloat {
            v.contentSize.height + v.adjustedContentInset.bottom - v.bounds.height
        }
        let cells = scrollViews(in: pager).filter {
            $0 !== pager && maxOffset($0) > -$0.adjustedContentInset.top + 1
        }
        if overflows { XCTAssertFalse(cells.isEmpty, "格内输出没溢出，这一档量不到贴底") }
        for cell in cells where cell.window != nil && cell.frame.minX < pager.bounds.width {
            let gap = maxOffset(cell) - cell.contentOffset.y
            XCTAssertLessThan(gap, 4, "格内输出没贴底（离底 \(gap)pt）")
        }
        save(screen.rig.capturePNG(), label)
        await screen.rig.close()
    }

    /// 深色模式各截一张：画布纯黑、卡片 #141414，失败卡的淡红在深底上也要看得出来。
    func testDarkSnapshots() async throws {
        for ai in [false, true] {
            let screen = try makeScreen(hosts: 6, aiAssisted: ai, size: tallWideSize,
                                        label: "par-dark", colorScheme: .dark)
            try await waitUntilDone(screen.controller)
            try await Task.sleep(for: .milliseconds(400))
            save(screen.rig.capturePNG(), ai ? "par-dark-ai" : "par-dark-shell")
            screen.controller.cancel()
            await screen.rig.close()
        }
    }

    func testPerPageFollowsGridHeight() {
        XCTAssertEqual(ParallelRunView.shellPerPage(gridHeight: 240), 2)
        XCTAssertEqual(ParallelRunView.shellPerPage(gridHeight: 520), 4)
    }

    func testNarrowShellStaysSingleColumn() async throws {
        let screen = try makeScreen(hosts: 6, aiAssisted: false, size: narrowSize, label: "par-narrow-shell")
        defer { screen.controller.cancel() }
        try await waitUntilDone(screen.controller)
        screen.rig.layout()
        XCTAssertFalse(scrollViews(in: screen.rig.hostView).contains { $0.contentSize.width > $0.bounds.width + 1 },
                       "窄屏不该出现横向翻页")
        save(screen.rig.capturePNG(), "par-narrow-shell")
        await screen.rig.close()
    }

    /// AI 页：跑到一半（有的台在跑、有的落定）和全部落定各截一张，大屏 + 窄屏。
    func testAIPageSnapshots() async throws {
        for (size, tag) in [(wideSize, "wide"), (tallWideSize, "tall"), (narrowSize, "narrow")] {
            let screen = try makeScreen(hosts: 6, aiAssisted: true, size: size, label: "par-\(tag)-ai")
            try await Task.sleep(for: .milliseconds(700))
            save(screen.rig.capturePNG(), "par-\(tag)-ai-running")
            try await waitUntilDone(screen.controller)
            try await Task.sleep(for: .milliseconds(300))
            save(screen.rig.capturePNG(), "par-\(tag)-ai-done")
            XCTAssertEqual(screen.controller.failedCount, 1)
            XCTAssertFalse(screen.controller.synthesis.isEmpty)
            screen.controller.cancel()
            await screen.rig.close()
        }
    }

    // MARK: - 装配

    private struct Screen {
        let rig: MobileProbeRig
        let controller: ParallelRunController
    }

    private func makeScreen(hosts: Int, aiAssisted: Bool, size: CGSize, label: String,
                            colorScheme: ColorScheme = .light) throws -> Screen {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let profiles = Array(try container.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).prefix(hosts))
        XCTAssertEqual(profiles.count, hosts)
        let command = aiAssisted ? "" : "apt-get update && apt-get -y upgrade"
        var doctor: ParallelAIDoctor?
        if aiAssisted {
            var d = ParallelAIDoctor(client: LaneLLM(failing: profiles[1].name), model: "t",
                                   baseURL: URL(string: "https://example.invalid")!, apiKey: "k")
            d.retryDelay = { _ in .zero }
            doctor = d
        }
        let controller = ParallelRunController(
            commandID: UUID(), commandName: "更新软件包", command: command,
            intent: aiAssisted ? "更新软件包和内核、执行 autoremove 清理，必要时重启服务器" : "",
            aiAssisted: aiAssisted, targets: profiles, doctor: doctor,
            store: QuickCommandStore(context: container.mainContext), container: container,
            executor: LayoutExecutor(slowHost: profiles.last?.id, failHost: profiles[1].id))
        let request = ParallelRunRequest(commandID: UUID(), name: "更新软件包", command: command,
                                         intent: controller.intent, aiAssisted: aiAssisted,
                                         serverIDs: profiles.map(\.id))
        let rig = MobileProbeRig(label: label, size: size)
        controller.start()
        rig.mount(ParallelRunView(request: request, controller: controller, onClose: {})
            .modelContainer(container)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme))
        return Screen(rig: rig, controller: controller)
    }

    private func waitUntilDone(_ c: ParallelRunController) async throws {
        for _ in 0..<300 where !(c.allDone && (!c.aiAssisted || !c.synthesis.isEmpty)) {
            try await Task.sleep(for: .milliseconds(40))
        }
        XCTAssertTrue(c.allDone, "12 秒内没跑完")
    }

    private func scrollViews(in view: UIView?) -> [UIScrollView] {
        guard let view else { return [] }
        var out: [UIScrollView] = []
        if let s = view as? UIScrollView { out.append(s) }
        for sub in view.subviews { out += scrollViews(in: sub) }
        return out
    }

    private func save(_ png: Data?, _ name: String) {
        guard let png else { return XCTFail("\(name) 没截到图") }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["PARALLEL_SHOT_DIR"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}

// MARK: - 假模型：每台按对话轮数走「升级 → 清理 → 结论」，指定那台给失败结论

private nonisolated struct LaneLLM: LLMClient {
    let failing: String

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let events: [LLMEvent]
        if !system.contains("run_command") {
            events = [.text("6 台中 5 台已完成更新与清理；\(failing) 的软件源证书过期导致升级失败，建议更新 CA 证书后重试。")]
        } else {
            let fails = messages.first?.text.contains(failing) ?? false
            switch messages.count {
            case 1:
                events = [.toolCall(Self.call("DEBIAN_FRONTEND=noninteractive apt-get -y upgrade", "升级软件包"))]
            case 2:
                events = fails
                    ? [.toolCall(Self.call("apt-get update", "刷新软件源后重试"))]
                    : [.toolCall(Self.call("apt-get -y autoremove", "清理不再需要的包"))]
            default:
                events = [.text(fails
                    ? #"{"status":"failed","summary":"软件源 HTTPS 证书校验失败，刷新后仍无法下载；需要更新 ca-certificates 或更换镜像源。"}"#
                    : #"{"status":"ok","summary":"已升级 23 个软件包并清理旧内核，需重启后生效。"}"#)]
            }
        }
        return AsyncThrowingStream { c in
            Task {
                try? await Task.sleep(for: .milliseconds(120))
                for e in events { c.yield(e) }
                c.finish()
            }
        }
    }

    static func call(_ command: String, _ explanation: String) -> LLMToolCall {
        let args = (try? JSONSerialization.data(withJSONObject: ["command": command, "explanation": explanation]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return LLMToolCall(id: UUID().uuidString, name: "run_command", argumentsJSON: args)
    }
}

// MARK: - 假执行：每条命令吐几行输出；指定那台慢，用来截「运行中」

private struct LayoutExecutor: ParallelCommandExecuting {
    let slowHost: UUID?
    /// Shell 模式下这一台的广播命令以非 0 退出，截图里要有一张失败卡。
    let failHost: UUID?
    func makeSession(for profile: ServerProfile, trustNewKeys: Bool) async -> ParallelExecutionSession {
        LayoutSession(slow: profile.id == slowHost, failsBroadcast: profile.id == failHost)
    }
}

private nonisolated struct LayoutSession: ParallelExecutionSession {
    let slow: Bool
    let failsBroadcast: Bool
    var setupErrorText: String? { nil }

    func run(_ command: String,
             onLines: @escaping @Sendable ([PLine]) -> Void) async throws -> CommandResult {
        try await Task.sleep(for: .milliseconds(slow ? 2500 : 150))
        if command == "true" { return CommandResult(output: "", exitCode: 0) }
        let fail = command == "apt-get update" || (failsBroadcast && command.hasPrefix("apt-get update &&"))
        let lines = fail
            ? ["Hit:1 http://archive.ubuntu.com/ubuntu noble InRelease",
               "Err:2 https://mirror.example.com noble-security InRelease",
               "  Certificate verification failed: The certificate is NOT trusted."]
            : ["Reading package lists... Done", "Building dependency tree... Done",
               "Calculating upgrade... Done",
               "The following packages will be upgraded:",
               "  libssl3t64 linux-image-generic openssh-server python3.12 tzdata",
               "23 upgraded, 0 newly installed, 2 to remove and 0 not upgraded.",
               "Processing triggers for man-db (2.12.0-4build2) ..."]
        return CommandResult(output: lines.joined(separator: "\n"), exitCode: fail ? 100 : 0)
    }

    func takeHostKeyChallenge() -> HostKeyChallenge? { nil }
    func close() async {}
}
