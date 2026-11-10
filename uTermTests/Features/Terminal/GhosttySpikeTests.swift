import AppKit
import CoreImage
import IOSurface
import XCTest
import GhosttyTerminal
import SwiftTerm
@testable import uTerm

/// GhosttyKit 接入验证（spike，见 `docs/ghostty-eval/macos-spike.md`）。
///
/// 1. `testSessionPathRendersCorpus`：真 `TerminalSession` + 假后端，开 Ghostty 渲染，挂进真窗口，
///    把录制语料与一段大输出走真实的输出泵喂进去，逐行比对 Ghostty 可见区与影子 SwiftTerm 可见区，
///    并核对应答只来自 Ghostty、尺寸同步到后端、截图非空。
/// 2. `testThroughputSwiftTermVsGhostty`：同一份字节分别喂 SwiftTerm 视图与 Ghostty 视图，量吞吐、
///    峰值内存、主线程 CPU 与进程 CPU。读数打到标准输出（`[GhosttySpike]` 开头）。
@MainActor
final class GhosttySpikeTests: XCTestCase {

    // MARK: - 夹具

    private func corpus(_ name: String) throws -> [UInt8] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "terminal-corpus-\(name)", withExtension: "bin"))
        return [UInt8](try Data(contentsOf: url))
    }

    private func waitUntil(_ timeout: TimeInterval, _ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待超时：\(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 可见区逐行（SwiftTerm）。宽字符后的占位格跳过，与 Ghostty 读出来的文字同形。
    private func swiftTermVisible(_ terminal: SwiftTerm.Terminal) -> [String] {
        (0..<terminal.rows).map {
            // 光标跳过、从没写过的格子 SwiftTerm 译成 \0，Ghostty 译成空格：统一成空格再去尾。
            trimRight(Substring((terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "")
                .replacingOccurrences(of: "\u{0}", with: " ")))
        }
    }

    private func trimRight(_ s: Substring) -> String {
        var s = String(s)
        while let last = s.last, last == " " || last == "\u{0}" { s.removeLast() }
        return s
    }

    /// (逐字一致的行数, 去掉全部空白后一致的行数, 首个不一致)
    private var strictDiff: String?

    private func compare(_ a: [String], _ b: [String]) -> (strict: Int, loose: Int, firstDiff: String?) {
        var strict = 0, loose = 0
        strictDiff = nil
        var first: String?
        for i in 0..<min(a.count, b.count) {
            if a[i] == b[i] { strict += 1 } else if strictDiff == nil { strictDiff = "row \(i) swiftterm=\(a[i].debugDescription) ghostty=\(b[i].debugDescription)" }
            let la = a[i].filter { !$0.isWhitespace }, lb = b[i].filter { !$0.isWhitespace }
            if la == lb { loose += 1 } else if first == nil { first = "row \(i) swiftterm=\(a[i].debugDescription) ghostty=\(b[i].debugDescription)" }
        }
        return (strict, loose, first)
    }

    /// 大输出：混合 16 色 / 256 色 / 真彩逐字渐变 / 中文 / 盒线，确定性生成。
    nonisolated static func makeLoad(bytes target: Int) -> [UInt8] {
        var state: UInt64 = 0x7554_6572_6D00
        func next() -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int(truncatingIfNeeded: (z ^ (z >> 31)) & 0x7FFF_FFFF)
        }
        let words = ["alpha", "beta", "gamma", "delta", "build", "ok", "error", "warn", "main.swift", "uTerm"]
        let cjk = Array("终端渲染性能测试中文字符宽度对齐滚动历史选区复制光标样式最低对比度远程控制会话")
        var out = [UInt8]()
        out.reserveCapacity(target + 8192)
        var line = 0
        while out.count < target {
            var s = ""
            switch next() % 10 {
            case 0...2:
                for _ in 0..<8 { s += "\u{1B}[\(30 + next() % 8)m\(words[next() % words.count]) " }
            case 3, 4:
                for _ in 0..<8 { s += "\u{1B}[38;5;\(next() % 256)m\(words[next() % words.count]) " }
            case 5, 6:
                for i in 0..<60 {
                    s += "\u{1B}[38;2;\(i * 4);\(255 - i * 4);\(next() % 256);48;2;\(next() % 64);0;\(i)m"
                    s.append(Character(UnicodeScalar(UInt8(0x41 + i % 26))))
                }
            case 7, 8:
                s += "\u{1B}[1;3\(next() % 8)m"
                for _ in 0..<30 { s.append(cjk[next() % cjk.count]) }
            default:
                s += "\u{1B}[4m┌──────┬──────┐\u{1B}[24m │ \(line) │ \u{1B}[7mreverse\u{1B}[27m \u{1B}[2mdim\u{1B}[22m"
            }
            s += "\u{1B}[0m\r\n"
            out += Array(s.utf8)
            line += 1
        }
        return out
    }

    /// 同步跑一轮主 run loop（让 AppKit 画）。`RunLoop.run` 不能直接在 async 上下文里调。
    private static func spinRunLoopOnce() {
        RunLoop.main.run(mode: .default, before: Date())
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }

    // MARK: - 1. 会话路径

    func testConfigIsAcceptedByGhostty() {
        let controller = GhosttyTerminalConfig.controller
        print("[GhosttySpike] rendered config:\n\(controller.renderedConfig)")
        XCTAssertNil(controller.lastConfigurationIssue, "Ghostty 拒收了配置")
    }

    func testSessionPathRendersCorpus() async throws {
        let session = TerminalSession()
        let bridge = session.ghostty
        let container = GhosttyContainerView(surface: bridge.view)
        container.isActive = true
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                      contentView: container, placement: .transparentOnScreen)
        defer {
            session.dispose()
            window.orderOut(nil)
        }
        container.frame = window.contentView?.bounds ?? container.frame
        container.layoutSubtreeIfNeeded()

        try await waitUntil(10, "surface 挂上并完成快照对齐") { bridge.isLive && bridge.grid != nil }
        // 第一次 resize 回调可能是视图还没按窗口排好时的尺寸（实测先报 53×21 再报 120×43），等它停稳。
        var lastGrid = bridge.grid!
        var gridSince = Date()
        try await waitUntil(10, "Ghostty 网格停稳") {
            let g = bridge.grid!
            if g != lastGrid { lastGrid = g; gridSince = Date() }
            return Date().timeIntervalSince(gridSince) > 0.5
        }
        // 语料是在 100×30 里录的。程序按 30 行设的滚动区（vim 的 `1;30r`）在别的行数下语义会变：
        // xterm / Ghostty 的 DECSTBM 是整个终端一份，SwiftTerm 是每块缓冲区一份，退出备用屏后两边不同。
        // 所以把窗口调到恰好 100×30 再比，比的是同一份录制在原尺寸下的结果。
        let first = try XCTUnwrap(bridge.grid)
        // Ghostty 的格子是整像素（2x 屏上即 0.5pt 的整数倍），除出来的余数是排不下一格的边角。
        let scale = window.backingScaleFactor
        let cellW = (bridge.view.frame.width / CGFloat(first.cols) * scale).rounded(.down) / scale
        let cellH = (bridge.view.frame.height / CGFloat(first.rows) * scale).rounded(.down) / scale
        print("[GhosttySpike] first stable grid=\(first.cols)x\(first.rows) view=\(bridge.view.frame.size) cell=\(cellW)x\(cellH)pt")
        window.setContentSize(NSSize(width: cellW * 100 + 16 + cellW / 2, height: cellH * 30 + 6 + cellH / 2))
        container.frame = window.contentView?.bounds ?? container.frame
        container.layoutSubtreeIfNeeded()
        try await waitUntil(10, "Ghostty 网格变成 100×30") { bridge.grid.map { $0 == (100, 30) } ?? false }
        let grid = try XCTUnwrap(bridge.grid)
        print("[GhosttySpike] ghostty grid=\(grid.cols)x\(grid.rows) view=\(bridge.view.frame.size)")

        let backend = MockBackend()
        await session.connect(using: backend)
        XCTAssertEqual(session.connectionState, .connected)

        // 尺寸：影子 SwiftTerm 跟到 Ghostty 的网格，后端收到同一个尺寸。
        let shadow = session.terminalView.getTerminal()
        XCTAssertEqual(shadow.cols, grid.cols)
        XCTAssertEqual(shadow.rows, grid.rows)
        var resizes: [(cols: UInt16, rows: UInt16)] = []
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            resizes = await backend.resizes
            if !resizes.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        print("[GhosttySpike] backend resizes=\(resizes.map { "\($0.cols)x\($0.rows)" })")
        XCTAssertEqual(resizes.last.map { Int($0.cols) }, grid.cols)
        XCTAssertEqual(resizes.last.map { Int($0.rows) }, grid.rows)

        var report: [String] = []
        let load = Self.makeLoad(bytes: 4 * 1024 * 1024)
        // vim / htop / less 的录制以退出程序结尾（回到被 RIS 清过的主屏，几乎是空的），取前 60%（还在全屏程序里）。
        let inputs: [(String, [UInt8])] = try ["shell", "mixed"].map { ($0, try corpus($0)) }
            + ["vim", "htop", "less"].map { name in
                // 切在 60% 之前最后一个 ESC 上：不切断转义序列（切在序列中间时两边的出错恢复不同，比不出东西）。
                let c = try corpus(name)
                let cut = c[0..<c.count * 6 / 10].lastIndex(of: 0x1B) ?? c.count * 6 / 10
                return ("\(name)@60%", Array(c[0..<cut]))
            }
            + [("load4MB", load)]
        for (name, bytes) in inputs {
            // 每段之前清屏复位，让各段互不影响（RIS 两边都认）。
            await backend.emitOutput(Data("\u{1B}c".utf8))
            await backend.emitOutput(Data(bytes))
            try await waitUntil(60, "\(name) 喂完") {
                !session.outputBuffer.hasBufferedBytes && bridge.io.pendingOutputByteCount == 0
            }
            // 输出泵最后一拍喂完后 Ghostty 还要解析：等两边的可见区稳定。
            var last = ""
            var stableSince = Date()
            try await waitUntil(10, "\(name) 可见区稳定") {
                let now = bridge.viewportText() ?? ""
                if now != last { last = now; stableSince = Date() }
                return Date().timeIntervalSince(stableSince) > 0.3
            }
            let swift = swiftTermVisible(shadow)
            // 先按 Ghostty 当前视口读，再 scroll_to_bottom 后读一次：区分「内容不同」与「视口没跟到底」。
            let asIs = (bridge.viewportText() ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(trimRight)
            let asIsResult = compare(swift, asIs)
            bridge.view.performBindingAction("scroll_to_bottom")
            try await Task.sleep(for: .milliseconds(100))
            let ghostty = (bridge.viewportText() ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(trimRight)
            let result = compare(swift, ghostty)
            let line = "[GhosttySpike] corpus=\(name) bytes=\(bytes.count) rows=\(swift.count)/\(ghostty.count) asIs(strict=\(asIsResult.strict) loose=\(asIsResult.loose)) afterScrollToBottom(strict=\(result.strict) loose=\(result.loose))"
            print(line)
            if let diff = result.firstDiff { print("[GhosttySpike]   first diff \(diff)") }
            if let diff = strictDiff { print("[GhosttySpike]   first strict diff \(diff)") }
            report.append(line)
            XCTAssertGreaterThan(ghostty.joined().count, 0, "\(name)：Ghostty 可见区是空的")
            XCTAssertGreaterThanOrEqual(Double(result.loose), Double(swift.count) * 0.9,
                                        "\(name)：Ghostty 与 SwiftTerm 可见区差得太多")
        }

        // 应答：DA1 只由 Ghostty 回答（影子 SwiftTerm 的被丢掉），并到达后端。
        var ghosttyWrites = Data()
        bridge.onWriteForTesting = { ghosttyWrites.append($0) }
        await backend.emitOutput(Data("\u{1B}[c".utf8))
        try await waitUntil(10, "DA1 应答到达后端") {
            ghosttyWrites.range(of: Data("\u{1B}[?".utf8)) != nil
        }
        try await Task.sleep(for: .milliseconds(300))
        let written = await backend.writtenData.reduce(Data(), +)
        let replies = written.split(separator: UInt8(ascii: "c")).filter { $0.starts(with: Data("\u{1B}[?".utf8)) }
        print("[GhosttySpike] DA1 replies at backend=\(replies.map { String(decoding: $0, as: UTF8.self).debugDescription })")
        XCTAssertEqual(replies.count, 1, "DA1 只能有一个应答（Ghostty），影子 SwiftTerm 的必须丢掉")

        // 截图：AppKit 的 cacheDisplay 对 CAMetalLayer 是否有效。
        let image = bridge.view.snapshotImage()
        let rep = image?.representations.first as? NSBitmapImageRep
        let cacheInk = rep.map(VisionTextProbe.inkFraction) ?? -1
        let surfaceInk = ioSurfaceBitmap(of: bridge.view).map(VisionTextProbe.inkFraction) ?? -1
        print("[GhosttySpike] snapshot cacheDisplayInk=\(cacheInk) ioSurfaceInk=\(surfaceInk)")
        XCTAssertGreaterThan(surfaceInk, 0.01, "Ghostty 的 IOSurface 截图是空的")
    }

    // MARK: - 截图（Ghostty 画在 IOSurface 上，AppKit 的 cacheDisplay 抓不到）

    /// 在视图的图层树里找 Ghostty 渲染用的 IOSurface，转成位图。窗口 alpha 为 0 也能抓。
    private func ioSurfaceBitmap(of view: NSView) -> NSBitmapImageRep? {
        func find(_ layer: CALayer) -> IOSurfaceRef? {
            if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
                return (contents as! IOSurfaceRef)
            }
            for sub in layer.sublayers ?? [] { if let s = find(sub) { return s } }
            return nil
        }
        guard let root = view.layer, let surface = find(root) else { return nil }
        let image = CIImage(ioSurface: surface)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }

    /// 偏离背景（白）的像素里，平均饱和度与最暗亮度。
    nonisolated private static func inkStats(_ rep: NSBitmapImageRep) -> (count: Int, meanSaturation: Double, minLuma: Double, meanHue: Double) {
        var n = 0
        var sat = 0.0, hue = 0.0, minLuma = 1.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 1) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
                guard luma < 0.75 else { continue }
                n += 1
                sat += c.saturationComponent
                hue += c.hueComponent
                minLuma = min(minLuma, luma)
            }
        }
        return (n, n > 0 ? sat / Double(n) : 0, minLuma, n > 0 ? hue / Double(n) : 0)
    }

    /// 浅色底上的亮黄字（#FFD600 对白底约 1.4:1）在最低对比度 3.0 下被改成什么颜色：
    /// SwiftTerm 补丁 #1 保色相（压暗成橄榄 / 棕，仍有饱和度），Ghostty 换成黑 / 白（饱和度≈0）。
    func testMinimumContrastAlgorithmDiffers() async throws {
        let text = "\u{1B}[2J\u{1B}[H\u{1B}[38;2;255;214;0mWWWWWWWWWWWWWWWW\u{1B}[0m\r\n"
            + "\u{1B}[38;2;255;214;0m\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{2588}\u{1B}[0m\r\n"
        GhosttyTerminalBridge.applyAppearance(dark: false)
        defer { GhosttyTerminalBridge.applyAppearance(dark: true) }

        // Ghostty
        let io = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), contentView: view,
                                      placement: .transparentOnScreen)
        defer { window.orderOut(nil); view.removeFromSuperview() }
        io.receive(text)
        try await waitUntil(10, "Ghostty 出帧") { ioSurfaceBitmap(of: view).map { VisionTextProbe.inkFraction($0) > 0.005 } ?? false }
        try await Task.sleep(for: .milliseconds(300))
        let ghosttyRep = try XCTUnwrap(ioSurfaceBitmap(of: view))
        // 分别量文字行与块字符行（各取前两行的像素带）。
        func band(_ rep: NSBitmapImageRep, row: Int, rowPx: Int) -> NSBitmapImageRep {
            let cg = rep.cgImage!.cropping(to: CGRect(x: 0, y: row * rowPx, width: rep.pixelsWide, height: rowPx))!
            return NSBitmapImageRep(cgImage: cg)
        }

        // SwiftTerm（同一配色、同一最低对比度）
        let st = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        TerminalTheme.apply(to: st, settings: TerminalSettings.read(), dark: false)
        let stWindow = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120), contentView: st)
        defer { stWindow.orderOut(nil) }
        st.feed(text: text)
        st.flushPendingDisplay()
        st.displayIfNeeded()
        let stRep = try XCTUnwrap(st.bitmapImageRepForCachingDisplay(in: st.bounds))
        st.cacheDisplay(in: st.bounds, to: stRep)

        // 行高：两边都按「第一行 / 第二行」切带。Ghostty 的位图是像素、原点在上。
        let gCellH = Int((Double(ghosttyRep.pixelsHigh) / (120.0 / 15.0)).rounded())
        let sCellH = Int((Double(stRep.pixelsHigh) / (120.0 / 15.0)).rounded())
        let g1 = Self.inkStats(band(ghosttyRep, row: 0, rowPx: gCellH))
        let g2 = Self.inkStats(band(ghosttyRep, row: 1, rowPx: gCellH))
        let s1 = Self.inkStats(band(stRep, row: 0, rowPx: sCellH))
        let s2 = Self.inkStats(band(stRep, row: 1, rowPx: sCellH))
        print(String(format: "[GhosttySpike] min-contrast text   ghostty n=%d sat=%.2f hue=%.2f minLuma=%.2f | swiftterm n=%d sat=%.2f hue=%.2f minLuma=%.2f",
                     g1.count, g1.meanSaturation, g1.meanHue, g1.minLuma, s1.count, s1.meanSaturation, s1.meanHue, s1.minLuma))
        print(String(format: "[GhosttySpike] min-contrast blocks ghostty n=%d sat=%.2f hue=%.2f minLuma=%.2f | swiftterm n=%d sat=%.2f hue=%.2f minLuma=%.2f",
                     g2.count, g2.meanSaturation, g2.meanHue, g2.minLuma, s2.count, s2.meanSaturation, s2.meanHue, s2.minLuma))
        // 两边都确实把亮黄字钳暗了（不钳的话亮度 > 0.75，一个像素都数不到）。
        XCTAssertGreaterThan(g1.count, 0, "Ghostty 没有执行 minimum-contrast")
        XCTAssertGreaterThan(s1.count, 0, "SwiftTerm 补丁 #1 没生效")
    }

    // MARK: - 2. 吞吐

    private struct Reading {
        var engine: String
        var seconds: Double
        var mainCPU: Double
        var procCPU: Double
        var peakDeltaMB: Double
        var endDeltaMB: Double
        var mbps: Double { Double(GhosttySpikeTests.loadBytes) / 1_048_576 / seconds }
        var line: String {
            String(format: "[GhosttySpike] engine=%@ MB=%.0f wall=%.3fs MB/s=%.1f mainCPU=%.3fs procCPU=%.3fs peakΔ=%.0fMB endΔ=%.0fMB",
                   engine, Double(GhosttySpikeTests.loadBytes) / 1_048_576, seconds, mbps, mainCPU, procCPU, peakDeltaMB, endDeltaMB)
        }
    }

    private nonisolated final class ViewportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: InMemoryTerminalViewport?
        var value: InMemoryTerminalViewport? { lock.withLock { stored } }
        func set(_ v: InMemoryTerminalViewport) { lock.withLock { stored = v } }
    }

    nonisolated static let loadBytes = 32 * 1024 * 1024
    nonisolated static let chunk = 64 * 1024

    private func measureSwiftTerm(_ load: [UInt8], headless: Bool) async throws -> Reading {
        let view = CopyableTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        TerminalTheme.apply(to: view, settings: TerminalSettings.read(), dark: true)
        let window: NSWindow? = headless ? nil
            : ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), contentView: view,
                               placement: .transparentOnScreen)
        defer { window?.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let base = ProbeMetrics.footprintMB()
        var peak = base
        let main0 = ProbeMetrics.threadCPUSeconds(), proc0 = Self.processCPUSeconds()
        let t0 = CFAbsoluteTimeGetCurrent()
        var offset = 0
        var draws = 0
        defer { if !headless { print("[GhosttySpike] swiftterm-view draws=\(draws)") } }
        while offset < load.count {
            let end = min(offset + Self.chunk, load.count)
            view.feed(byteArray: load[offset..<end])
            offset = end
            // 让 AppKit 有机会画（SwiftTerm 的绘制节流在主线程 run loop 上）。
            // 每 512 KiB（Mac 输出泵一拍的上限）同步画一帧，近似积压时 SwiftTerm 的绘制节奏。
            if !headless, offset % (512 * 1024) == 0 {
                view.flushPendingDisplay()
                view.displayIfNeeded()
                draws += 1
                Self.spinRunLoopOnce()
            }
            peak = max(peak, ProbeMetrics.footprintMB())
        }
        if !headless { view.flushPendingDisplay(); view.displayIfNeeded() }
        let t1 = CFAbsoluteTimeGetCurrent()
        let reading = Reading(engine: headless ? "swiftterm-headless" : "swiftterm-view",
                              seconds: t1 - t0, mainCPU: ProbeMetrics.threadCPUSeconds() - main0,
                              procCPU: Self.processCPUSeconds() - proc0,
                              peakDeltaMB: peak - base, endDeltaMB: ProbeMetrics.footprintMB() - base)
        XCTAssertNotNil(view.getTerminal().getLine(row: 0))
        return reading
    }

    private func measureGhostty(_ load: [UInt8]) async throws -> (Reading, String?, InMemoryTerminalViewport?) {
        let base0 = ProbeMetrics.footprintMB()
        let box = ViewportBox()
        let io = InMemoryTerminalSession(write: { _ in }, resize: { box.set($0) })
        let view = GhosttySurfaceView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        view.controller = GhosttyTerminalConfig.controller
        view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
        let window = ProbeWindow.make(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), contentView: view,
                                      placement: .transparentOnScreen)
        defer { window.orderOut(nil); view.removeFromSuperview() }
        try await waitUntil(10, "Ghostty surface 建好") { box.value != nil }
        try await Task.sleep(for: .milliseconds(200))
        let base = ProbeMetrics.footprintMB()
        print(String(format: "[GhosttySpike] ghostty surface setup footprintΔ=%.0fMB", base - base0))
        var peak = base
        let main0 = ProbeMetrics.threadCPUSeconds(), proc0 = Self.processCPUSeconds()
        let t0 = CFAbsoluteTimeGetCurrent()
        var offset = 0
        // 宿主按 4 MiB 积压做反压（`receive` 自己从不阻塞，不压的话积压无上限）。
        while offset < load.count {
            while io.pendingOutputByteCount > 4 * 1024 * 1024 {
                try await Task.sleep(for: .milliseconds(1))
                peak = max(peak, ProbeMetrics.footprintMB())
            }
            let end = min(offset + Self.chunk, load.count)
            io.receive(Data(load[offset..<end]))
            offset = end
        }
        while io.pendingOutputByteCount > 0 {
            try await Task.sleep(for: .milliseconds(1))
            peak = max(peak, ProbeMetrics.footprintMB())
        }
        let t1 = CFAbsoluteTimeGetCurrent()
        let reading = Reading(engine: "ghostty-view", seconds: t1 - t0,
                              mainCPU: ProbeMetrics.threadCPUSeconds() - main0,
                              procCPU: Self.processCPUSeconds() - proc0,
                              peakDeltaMB: peak - base, endDeltaMB: ProbeMetrics.footprintMB() - base)
        return (reading, io.readViewportText(), box.value)
    }

    /// 六个窗格的内存账：各开 6 个 600×400 的视图、各喂 1 MiB 大输出，量进程足迹的增量。
    /// SwiftTerm 先量（Ghostty 的 Metal 工作集拆掉后不一定马上还）。
    func testFootprintSixPanes() async throws {
        let load = Self.makeLoad(bytes: 1024 * 1024)
        let size = NSRect(x: 0, y: 0, width: 600, height: 400)

        let base0 = ProbeMetrics.footprintMB()
        var stWindows: [NSWindow] = []
        for _ in 0..<6 {
            let view = CopyableTerminalView(frame: size)
            TerminalTheme.apply(to: view, settings: TerminalSettings.read(), dark: true)
            stWindows.append(ProbeWindow.make(contentRect: size, contentView: view, placement: .transparentOnScreen))
            view.feed(byteArray: load[...])
            view.flushPendingDisplay()
            view.displayIfNeeded()
        }
        try await Task.sleep(for: .milliseconds(500))
        let st = ProbeMetrics.footprintMB() - base0
        stWindows.forEach { $0.orderOut(nil) }
        stWindows.removeAll()
        try await Task.sleep(for: .milliseconds(500))

        let base1 = ProbeMetrics.footprintMB()
        var ghWindows: [NSWindow] = []
        var sessions: [InMemoryTerminalSession] = []
        var perPane: [Double] = []
        for _ in 0..<6 {
            let io = InMemoryTerminalSession(write: { _ in }, resize: { _ in })
            let view = GhosttySurfaceView(frame: size)
            view.controller = GhosttyTerminalConfig.controller
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(io))
            ghWindows.append(ProbeWindow.make(contentRect: size, contentView: view, placement: .transparentOnScreen))
            io.receive(Data(load))
            sessions.append(io)
            try await waitUntil(10, "Ghostty 窗格解析完") { io.pendingOutputByteCount == 0 }
            try await Task.sleep(for: .milliseconds(300))
            perPane.append(ProbeMetrics.footprintMB() - base1)
        }
        try await Task.sleep(for: .milliseconds(500))
        let gh = ProbeMetrics.footprintMB() - base1
        print(String(format: "[GhosttySpike] footprint 6 panes: swiftterm Δ=%.0fMB ghostty Δ=%.0fMB (cumulative per pane: %@)",
                     st, gh, perPane.map { String(format: "%.0f", $0) }.joined(separator: ",")))
        ghWindows.forEach { $0.orderOut(nil) }
        XCTAssertEqual(sessions.count, 6)
    }

    func testThroughputSwiftTermVsGhostty() async throws {
        let load = Self.makeLoad(bytes: Self.loadBytes)
        var readings: [String: [Reading]] = [:]
        var lastGhosttyText: String?
        var cell: InMemoryTerminalViewport?
        // 交替顺序跑三轮，只比同一进程内的相对值。
        for round in 0..<3 {
            let order = round % 2 == 0 ? ["swiftterm-view", "ghostty-view", "swiftterm-headless"]
                                       : ["swiftterm-headless", "ghostty-view", "swiftterm-view"]
            for engine in order {
                let r: Reading
                switch engine {
                case "ghostty-view":
                    let (reading, text, viewport) = try await measureGhostty(load)
                    r = reading; lastGhosttyText = text; cell = viewport
                case "swiftterm-headless": r = try await measureSwiftTerm(load, headless: true)
                default: r = try await measureSwiftTerm(load, headless: false)
                }
                print(r.line + " round=\(round)")
                readings[engine, default: []].append(r)
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        for (engine, rs) in readings.sorted(by: { $0.key < $1.key }) {
            let med = { (f: (Reading) -> Double) in ProbeMetrics.percentile(rs.map(f), 0.5) }
            print(String(format: "[GhosttySpike] MEDIAN engine=%@ MB/s=%.1f wall=%.3fs mainCPU=%.3fs procCPU=%.3fs peakΔ=%.0fMB endΔ=%.0fMB",
                         engine, med(\.mbps), med(\.seconds), med(\.mainCPU), med(\.procCPU), med(\.peakDeltaMB), med(\.endDeltaMB)))
        }
        if let cell {
            let font = TerminalSettings.textFont()
            let swiftCell = NSAttributedString(string: "W", attributes: [.font: font]).size()
            print("[GhosttySpike] ghostty grid=\(cell.columns)x\(cell.rows) cellPx=\(cell.cellWidthPixels)x\(cell.cellHeightPixels) "
                  + String(format: "swiftterm-advance(pt)=%.2f lineHeight(pt)=%.2f", swiftCell.width,
                           font.ascender - font.descender + font.leading))
        }
        XCTAssertFalse((lastGhosttyText ?? "").isEmpty, "Ghostty 解析完大输出后可见区是空的")
    }
}
