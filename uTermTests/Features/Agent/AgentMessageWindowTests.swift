import AgentKit
import AppKit
import Markdown
import SwiftUI
import XCTest
@testable import uTerm

/// 渲染窗口（`AgentMessageWindow` / `MarkdownBlockWindow`）的契约闸门。
///
/// 这一组钉的是「**只裁渲染，不裁数据**」以及一组被优化碰过的交互契约：
/// 文本可选中 / 可复制、工具卡的按钮还在、贴底跟随仍走 `AgentScrollPolicy`、
/// Markdown 语义（默认不裁块）逐像素不变。
final class AgentMessageWindowTests: XCTestCase {

    // MARK: - 窗口算术

    func testMessageWindowKeepsTheTailAndNeverDropsBelowZero() {
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 1000, limit: 200), 800)
        XCTAssertEqual(AgentMessageWindow.hiddenCount(count: 1000, limit: 200), 800)
        // 上限 ≥ 总数 / 非正 / 空列表都不裁。
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 200, limit: 200), 0)
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 10, limit: 200), 0)
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 1000, limit: Int.max), 0)
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 1000, limit: 0), 0)
        XCTAssertEqual(AgentMessageWindow.startIndex(count: 0, limit: 200), 0)
        XCTAssertEqual(AgentMessageWindow.hiddenCount(count: 200, limit: 200), 0)
    }

    func testMessageWindowExpansionSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(AgentMessageWindow.expanded(200, count: 1000), 400)
        // 剩下不足一步就直接放开全部，别留一个「显示更早的 3 条」的尾巴。
        XCTAssertEqual(AgentMessageWindow.expanded(200, count: 300), 300)
        XCTAssertEqual(AgentMessageWindow.expanded(1000, count: 1000), 1000)
        XCTAssertEqual(AgentMessageWindow.expanded(Int.max, count: 1000), 1000)
        XCTAssertEqual(AgentMessageWindow.expanded(Int.max - 1, count: Int.max), Int.max)
    }

    func testMarkdownBlockWindowArithmetic() {
        XCTAssertEqual(MarkdownBlockWindow.remaining(total: 50_000, limit: 800), 49_200)
        XCTAssertEqual(MarkdownBlockWindow.remaining(total: 600, limit: 800), 0)
        XCTAssertEqual(MarkdownBlockWindow.remaining(total: 600, limit: Int.max), 0)
        XCTAssertEqual(MarkdownBlockWindow.expanded(800, total: 50_000), 1600)
        XCTAssertEqual(MarkdownBlockWindow.expanded(800, total: 1000), 1000)
        XCTAssertEqual(MarkdownBlockWindow.expanded(Int.max - 1, total: Int.max), Int.max)
    }

    /// 真实档 600 块的 README 一次就挂完 —— 分段对常规文件必须无感。
    func testRealisticReadmeFitsInOneMarkdownChunk() {
        XCTAssertGreaterThan(MarkdownBlockWindow.defaultLimit, 600,
                             "一份 2000 行 README（≈600 块）必须一次挂完，"
                             + "不该让常规文件也长出「继续渲染」按钮")
    }

    // MARK: - 只裁渲染，不裁数据

    /// 渲染窗口只作用在视图上：`AssistantModel.messages` 仍是全量，
    /// 于是持久化、模型上下文、「显示更早」都还拿得到旧消息。
    @MainActor
    func testRenderWindowNeverTruncatesTheModel() async throws {
        let provider = AIProvider(name: "Probe", kind: .anthropic,
                                  baseURL: ProviderPreset.anthropicBaseURL, model: "m")
        let model = AssistantModel(client: MockLLMClient(deltas: []),
                                   provider: provider, apiKey: "sk-probe")
        let session = ChatSession(title: "probe")
        var records: [ChatMessageRecord] = []
        for i in 0..<1000 {
            let record = ChatMessageRecord(roleRaw: i % 2 == 0 ? "user" : "assistant",
                                           text: "message \(i)", orderIndex: i)
            record.session = session
            records.append(record)
        }
        session.messages = records
        model.load(session)

        XCTAssertEqual(model.messages.count, 1000,
                       "渲染窗口不许动 model.messages —— 会话数据、持久化与模型上下文都靠它")
        let start = AgentMessageWindow.startIndex(count: model.messages.count,
                                                  limit: AgentMessageWindow.defaultLimit)
        let mounted = model.messages[start...]
        XCTAssertEqual(mounted.count, AgentMessageWindow.defaultLimit)
        XCTAssertEqual(mounted.last?.text, "message 999", "挂载的必须是最新的那一段")
        XCTAssertEqual(mounted.first?.text, "message 800")
    }

    // MARK: - 交互契约（源码闸门）

    /// 被优化碰过的三处交互必须都还在：Markdown 文本可选中、工具卡的
    /// 运行 / 跳过 / 复制命令仍是 `Button`、代码块的复制也仍是 `Button`
    /// （换成 `onTapGesture` 的那一轮读数是反的，见 docs/scroll-perf-findings.md）。
    func testInteractionContractsSurvivedTheOptimisation() throws {
        let assistant = try source("uTerm/Features/Agent/Views/AssistantView.swift")
        let terminalAgent = try source("uTerm/Features/Terminal/Views/TerminalAgentView.swift")
        let codeBlock = try source("uTerm/Features/Preview/Views/Markdown/ChatCodeBlock.swift")

        XCTAssertTrue(assistant.contains("StreamingMarkdownView(text: message.text, "
                                         + "isStreaming: isStreamingTail)\n"
                                         + "                                    .textSelection(.enabled)"),
                      "助手消息的 Markdown 必须仍可选中")
        XCTAssertTrue(assistant.contains("Button(action: onRun)"), "工具卡的「运行」必须仍是按钮")
        XCTAssertTrue(assistant.contains("Button(action: onSkip)"), "工具卡的「跳过」必须仍是按钮")
        XCTAssertTrue(assistant.contains("Button(action: copyCommand)"),
                      "工具卡的「复制命令」必须仍是按钮")
        XCTAssertTrue(codeBlock.contains("Button(action: copy)"),
                      "代码块的「复制」必须仍是按钮：换成 onTapGesture 的那一轮 "
                      + "hitTest 473 → 664µs、NSView 803 → 817，读数是反的")
        XCTAssertTrue(codeBlock.contains(".textSelection(.enabled)"), "代码正文必须仍可选中")

        // 贴底跟随仍走共享策略，且合并延迟没有被改动。
        for file in [assistant, terminalAgent] {
            XCTAssertTrue(file.contains("AgentScrollPolicy.isNearBottom"))
            XCTAssertTrue(file.contains("AgentScrollPolicy.coalescingDelay"))
        }
        // 两个 Agent 面板都挂了渲染窗口，且窗口只切视图不切 model。
        for file in [assistant, terminalAgent] {
            XCTAssertTrue(file.contains("AgentMessageWindow.startIndex"))
            XCTAssertTrue(file.contains("earlierMessagesButton"))
            XCTAssertFalse(file.contains("model.messages = "),
                           "视图不许改写 model.messages")
        }
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Agent
            .deletingLastPathComponent()   // Features
            .deletingLastPathComponent()   // uTermTests
            .deletingLastPathComponent()   // repo
    }
}

/// Markdown 语义不变的**像素**闸门：默认 `maxBlocks` 不裁块，
/// 「限到恰好等于块数」与「完全不限」必须逐位相同的图。
/// 像素判据走 `.offScreen`（playbook §十：屏外档给结构 / 几何 / 像素判据）。
@MainActor
final class MarkdownBlockWindowPixelTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    private static let source = """
    # 标题

    段落带 **强调**、`inline code` 与 [链接](https://example.com)。

    - 列表 A
    - 列表 B

    ```swift
    let x = 1
    ```

    > 引用一句。

    | a | b |
    | - | - |
    | 1 | 2 |
    """

    private func render(limit: Int) throws -> Data {
        let size = NSSize(width: 520, height: 720)
        let root = AnyView(MarkdownRenderer(source: Self.source, initialBlockLimit: limit)
            .frame(width: size.width, height: size.height))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = ProbeWindow.make(contentRect: NSRect(origin: .zero, size: size),
                                      styleMask: [.titled], contentView: host,
                                      key: false, placement: .offScreen)
        windows.append(window)
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    func testDefaultLimitRendersEveryBlockPixelForPixel() throws {
        defer { closeAllWindows() }
        let blocks = Array(Document(parsing: Self.source).blockChildren).count
        XCTAssertGreaterThan(blocks, 5, "样张必须有足够多的块，否则闸门是空的")

        let unlimited = try render(limit: .max)
        let exact = try render(limit: blocks)
        let alsoDefault = try render(limit: MarkdownBlockWindow.defaultLimit)
        XCTAssertEqual(unlimited, exact, "限到块数 == 不限：Markdown 语义必须逐像素相同")
        XCTAssertEqual(unlimited, alsoDefault,
                       "默认上限（\(MarkdownBlockWindow.defaultLimit)）远大于样张块数，"
                       + "渲染结果必须与不限一致")

        // 反证：真的裁到一半时图必须不同（否则上面两条是「两张空图相等」）。
        let truncated = try render(limit: 2)
        XCTAssertNotEqual(unlimited, truncated, "裁到 2 块的图必须与全量不同")

        // 自证：图不是全白空壳。
        let rep = try XCTUnwrap(NSBitmapImageRep(data: unlimited))
        XCTAssertGreaterThan(VisionTextProbe.inkFraction(rep), 0.005,
                             "样张必须真的画出了内容")
    }
}
