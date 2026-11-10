import AppKit
import Carbon.HIToolbox
import CoreImage
import IOSurface
import Metal
import ObjectiveC
import QuartzCore
import XCTest
import GhosttyTerminal
#if UTERM_LEGACY_SWIFTTERM_TESTS
import SwiftTerm
#endif
@testable import uTerm

// 测量门（`docs/ghostty-eval/measure-macos.md`）用的夹具。测试本身在 `GhosttyMeasureTests.swift`。
//
// 所有测量用例默认跳过：要 `TEST_RUNNER_GHOSTTY_MEASURE=1` 才跑（会切输入法、动系统剪贴板、开几十个窗口）。
// 参数一律走 `TEST_RUNNER_<名字>` 环境变量（xcodebuild 去掉前缀后传给测试进程）。

nonisolated enum MeasureEnv {
    static func string(_ key: String, _ fallback: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? fallback
    }
    static func int(_ key: String, _ fallback: Int) -> Int { Int(string(key, "")) ?? fallback }
    static func double(_ key: String, _ fallback: Double) -> Double { Double(string(key, "")) ?? fallback }
    static var enabled: Bool { string("GHOSTTY_MEASURE", "0") == "1" }
    /// 外部工具（footprint / vmmap / heap）和测试进程对时用的目录：测试只读它（沙盒对 `/` 有只读例外）。
    static var syncDirectory: String? { ProcessInfo.processInfo.environment["GHOSTTY_MEASURE_SYNC_DIR"] }
}

// MARK: - 内存构成

/// 进程内存的一次快照。全部是 MB。
///
/// - `footprint`：`phys_footprint`，活动监视器的「内存」列、jetsam 看的那个数。
/// - `graphics`：footprint 里记在 graphics 账上的部分（`ledger_tag_graphics_footprint`，含压缩）：
///   Metal 的 buffer / texture、IOSurface 都记在这里。
/// - `malloc`：所有 malloc zone 的 `size_in_use`（Swift 对象、SwiftTerm 的行缓冲都在这里）。
/// - `metal`：系统默认 Metal 设备的 `currentAllocatedSize`（只在 Ghostty 已经建过 surface 后才读，免得
///   SwiftTerm 那边为了读数平白建一个 Metal 设备）。
/// - `tags`：按 VM 区域的 `user_tag` 汇总的 dirty + swapped（vmmap 的口径）。Ghostty 的回滚页由 Zig 的
///   page allocator 直接 mmap，不带 tag，落在 0（`VM_ALLOCATE`）。
nonisolated struct MemSnapshot: Sendable {
    var footprint = 0.0
    var footprintPeak = 0.0
    var internalMB = 0.0
    var compressed = 0.0
    var graphics = 0.0
    var graphicsNoFootprint = 0.0
    var malloc = 0.0
    var metal = 0.0
    var tags: [Int: Double] = [:]

    static func take(includeMetal: Bool = false) -> MemSnapshot {
        var s = MemSnapshot()
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            s.footprint = mb(info.phys_footprint)
            s.footprintPeak = mb(UInt64(max(0, info.ledger_phys_footprint_peak)))
            s.internalMB = mb(info.internal)
            s.compressed = mb(info.compressed)
            s.graphics = mb(UInt64(max(0, info.ledger_tag_graphics_footprint + info.ledger_tag_graphics_footprint_compressed)))
            s.graphicsNoFootprint = mb(UInt64(max(0, info.ledger_tag_graphics_nofootprint + info.ledger_tag_graphics_nofootprint_compressed)))
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        s.malloc = mb(UInt64(stats.size_in_use))
        if includeMetal, let device = MTLCreateSystemDefaultDevice() {
            s.metal = mb(UInt64(device.currentAllocatedSize))
        }
        s.tags = regionTags()
        return s
    }

    private static func mb(_ bytes: UInt64) -> Double { Double(bytes) / 1_048_576 }

    private static func regionTags() -> [Int: Double] {
        var out: [Int: Double] = [:]
        var address: mach_vm_address_t = 0
        var depth: natural_t = 0
        let page = Double(getpagesize())
        while true {
            var size: mach_vm_size_t = 0
            var info = vm_region_submap_info_data_64_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_submap_info_data_64_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: Int32.self, capacity: Int(count)) {
                    mach_vm_region_recurse(mach_task_self_, &address, &size, &depth, $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { break }
            if info.is_submap != 0 { depth += 1; continue }
            let dirty = (Double(info.pages_dirtied) + Double(info.pages_swapped_out)) * page / 1_048_576
            if dirty > 0 { out[Int(info.user_tag), default: 0] += dirty }
            address += size
        }
        return out
    }

    static func tagName(_ tag: Int) -> String {
        switch tag {
        case 0: "untagged(VM_ALLOCATE)"
        case 1: "MALLOC"
        case 2: "MALLOC_SMALL"
        case 3: "MALLOC_LARGE"
        case 4: "MALLOC_HUGE"
        case 7: "MALLOC_TINY"
        case 8, 9: "MALLOC_LARGE_REUSE"
        case 11: "MALLOC_NANO"
        case 12: "MALLOC_MEDIUM"
        case 21: "IOKit"
        case 30: "STACK"
        case 40: "AppKit"
        case 41: "Foundation"
        case 42: "CoreGraphics"
        case 51: "CoreAnimation"
        case 52: "CGImage"
        case 54...58: "CoreGraphics(\(tag))"
        case 61: "dyld-malloc"
        case 82: "Swift-runtime"
        case 83: "Swift-metadata"
        case 88: "IOSurface"
        case 100: "IOAccelerator"
        default: "tag\(tag)"
        }
    }

    var line: String {
        String(format: "fp=%.1f int=%.1f cmp=%.1f gfx=%.1f gfxNoFp=%.1f malloc=%.1f metal=%.1f",
               footprint, internalMB, compressed, graphics, graphicsNoFootprint, malloc, metal)
    }

    /// 与另一个快照的差：每一项 + 变化最大的 6 个 tag。
    func delta(from base: MemSnapshot) -> String {
        var parts = [String(format: "Δfp=%+.1f Δint=%+.1f Δcmp=%+.1f Δgfx=%+.1f Δmalloc=%+.1f",
                            footprint - base.footprint, internalMB - base.internalMB, compressed - base.compressed,
                            graphics - base.graphics, malloc - base.malloc)]
        if metal > 0 || base.metal > 0 { parts.append(String(format: "Δmetal=%+.1f", metal - base.metal)) }
        let keys = Set(tags.keys).union(base.tags.keys)
        let diffs = keys.map { ($0, (tags[$0] ?? 0) - (base.tags[$0] ?? 0)) }
            .filter { abs($0.1) >= 0.5 }
            .sorted { abs($0.1) > abs($1.1) }
            .prefix(6)
        if !diffs.isEmpty {
            parts.append("tags{" + diffs.map { String(format: "%@=%+.1f", MemSnapshot.tagName($0.0), $0.1) }.joined(separator: " ") + "}")
        }
        return parts.joined(separator: " ")
    }
}

/// 后台线程按固定间隔采 footprint 峰值（主线程忙着喂 SwiftTerm 时也采得到）。
nonisolated final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true
    private var thread: Thread?

    func start(intervalMicroseconds: UInt32 = 5_000) {
        let t = Thread { [self] in
            while lock.withLock({ running }) {
                let f = ProbeMetrics.footprintMB()
                lock.withLock { peak = max(peak, f) }
                usleep(intervalMicroseconds)
            }
        }
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    func stop() -> Double {
        lock.withLock { running = false }
        usleep(20_000)
        return lock.withLock { peak }
    }
}

// MARK: - 出帧

/// IOSurface 上一块区域里「偏离背景」的像素比例。背景取右下角那个像素。
nonisolated enum SurfacePixels {
    static func inkFraction(_ surface: IOSurfaceRef, x: Int, y: Int, width: Int, height: Int, threshold: Int = 48) -> Double {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface), bpe = max(4, IOSurfaceGetBytesPerElement(surface))
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        let bgOffset = (h - 3) * bpr + (w - 3) * bpe
        let bg = (Int(base[bgOffset]), Int(base[bgOffset + 1]), Int(base[bgOffset + 2]))
        let x0 = max(0, x), y0 = max(0, y), x1 = min(w, x + width), y1 = min(h, y + height)
        guard x1 > x0, y1 > y0 else { return 0 }
        var ink = 0
        for row in y0..<y1 {
            let rowBase = row * bpr
            for col in x0..<x1 {
                let o = rowBase + col * bpe
                let d = max(abs(Int(base[o]) - bg.0), abs(Int(base[o + 1]) - bg.1), abs(Int(base[o + 2]) - bg.2))
                if d > threshold { ink += 1 }
            }
        }
        return Double(ink) / Double((x1 - x0) * (y1 - y0))
    }

    /// 整张 IOSurface 里接近某个颜色（RGB，0–255）的像素数，以及它们的包围盒（像素，原点左上）。
    static func colorCount(_ surface: IOSurfaceRef, rgb: (Int, Int, Int), tolerance: Int = 40) -> (count: Int, bbox: CGRect) {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let bpr = IOSurfaceGetBytesPerRow(surface), bpe = max(4, IOSurfaceGetBytesPerElement(surface))
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        // Ghostty 的 IOSurface 是 BGRA。
        var n = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for row in 0..<h {
            for col in 0..<w {
                let o = row * bpr + col * bpe
                let b = Int(base[o]), g = Int(base[o + 1]), r = Int(base[o + 2])
                if abs(r - rgb.0) <= tolerance, abs(g - rgb.1) <= tolerance, abs(b - rgb.2) <= tolerance {
                    n += 1
                    minX = min(minX, col); maxX = max(maxX, col); minY = min(minY, row); maxY = max(maxY, row)
                }
            }
        }
        let box = n > 0 ? CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : .zero
        return (n, box)
    }

    static func cgImage(_ surface: IOSurfaceRef) -> CGImage? {
        let image = CIImage(ioSurface: surface)
        return CIContext().createCGImage(image, from: image.extent)
    }
}

nonisolated enum BitmapPixels {
    /// 位图里接近某个颜色的像素数（sRGB）。
    static func colorCount(_ rep: NSBitmapImageRep, rgb: (Int, Int, Int), tolerance: Int = 40) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let r = Int(c.redComponent * 255), g = Int(c.greenComponent * 255), b = Int(c.blueComponent * 255)
                if abs(r - rgb.0) <= tolerance, abs(g - rgb.1) <= tolerance, abs(b - rgb.2) <= tolerance { n += 1 }
            }
        }
        return n
    }
}

/// 一个 Ghostty 视图的「出帧」计数：Ghostty 每画完一帧，把 IOSurface 设成图层的 `contents`
/// （渲染线程画完后 dispatch 到主线程设）。这里 KVO 这个属性，以它为「交给 Core Animation」的时刻。
///
/// `probe` 非 nil 时，每帧在回调里对新的 IOSurface 调一次，第一次返回 true 的时刻记进 `hitTime`。
nonisolated final class GhosttyFrameWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var _last: CFTimeInterval = 0
    private var _probe: (@Sendable (IOSurfaceRef) -> Bool)?
    private var _hit: CFTimeInterval?
    private var _offMain = 0
    private var observation: NSKeyValueObservation?
    private(set) weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
        observation = layer.observe(\.contents, options: [.new]) { [weak self] _, change in
            self?.didChange(change.newValue ?? nil)
        }
    }

    deinit { observation?.invalidate() }

    var count: Int { lock.withLock { _count } }
    var lastFrameTime: CFTimeInterval { lock.withLock { _last } }
    /// 回调不在主线程上的次数（判断 Ghostty 在哪个线程设 contents）。
    var offMainCount: Int { lock.withLock { _offMain } }
    var hitTime: CFTimeInterval? { lock.withLock { _hit } }

    func arm(_ probe: @escaping @Sendable (IOSurfaceRef) -> Bool) {
        lock.withLock { _probe = probe; _hit = nil }
    }

    func disarm() { lock.withLock { _probe = nil } }

    private func didChange(_ value: Any?) {
        let now = CACurrentMediaTime()
        let probe = lock.withLock { () -> (@Sendable (IOSurfaceRef) -> Bool)? in
            _count += 1
            _last = now
            if !Thread.isMainThread { _offMain += 1 }
            return _hit == nil ? _probe : nil
        }
        guard let probe, let value, CFGetTypeID(value as CFTypeRef) == IOSurfaceGetTypeID() else { return }
        let surface = value as! IOSurfaceRef
        if probe(surface) { lock.withLock { if _hit == nil { _hit = now } } }
    }

    /// 视图图层树里承载 Ghostty 画面的那个图层（`contents` 是 IOSurface，或类名带 IOSurface）。
    @MainActor static func contentLayer(of view: NSView) -> CALayer? {
        func walk(_ layer: CALayer) -> CALayer? {
            if let c = layer.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() { return layer }
            if NSStringFromClass(type(of: layer)).contains("IOSurface") { return layer }
            for sub in layer.sublayers ?? [] { if let found = walk(sub) { return found } }
            return nil
        }
        return view.layer.flatMap(walk)
    }

    @MainActor static func currentSurface(of view: NSView) -> IOSurfaceRef? {
        guard let c = contentLayer(of: view)?.contents, CFGetTypeID(c as CFTypeRef) == IOSurfaceGetTypeID() else { return nil }
        return (c as! IOSurfaceRef)
    }
}

// 【迁移中，暂未编译】SwiftTerm 的出帧探针（拿 SwiftTerm 当对照的那一半），随对照用例一起去掉。
#if UTERM_LEGACY_SWIFTTERM_TESTS
/// SwiftTerm 的「出帧」：把 `SwiftTerm.TerminalView.draw(_:)` 换成「原实现 + 回调」，以 draw 返回为准。
@MainActor
enum SwiftTermDrawProbe {
    private static var installed = false
    private static var hooks: [ObjectIdentifier: (SwiftTerm.TerminalView) -> Void] = [:]

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = SwiftTerm.TerminalView.self
        let sel = #selector(NSView.draw(_:))
        guard let method = class_getInstanceMethod(cls, sel),
              method != class_getInstanceMethod(NSView.self, sel) else {
            XCTFail("SwiftTerm.TerminalView 没有自己的 draw(_:)，换不了")
            return
        }
        typealias DrawFn = @convention(c) (AnyObject, Selector, NSRect) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: DrawFn.self)
        let block: @convention(block) (AnyObject, NSRect) -> Void = { object, rect in
            original(object, sel, rect)
            guard let view = object as? SwiftTerm.TerminalView else { return }
            MainActor.assumeIsolated { hooks[ObjectIdentifier(view)]?(view) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    static func hook(_ view: SwiftTerm.TerminalView, _ body: @escaping (SwiftTerm.TerminalView) -> Void) {
        install()
        hooks[ObjectIdentifier(view)] = body
    }

    static func unhook(_ view: SwiftTerm.TerminalView) { hooks[ObjectIdentifier(view)] = nil }
}

#endif

// MARK: - 后端

/// 收到什么就原样回什么（本地回环 echo）。
actor EchoBackend: TerminalBackend {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    private nonisolated let output: AsyncStream<Data>.Continuation
    private nonisolated let exit: AsyncStream<Void>.Continuation
    nonisolated(unsafe) var onWrite: (@Sendable (Data) -> Void)?

    init() {
        (outputStream, output) = AsyncStream<Data>.makeStream()
        (exitStream, exit) = AsyncStream<Void>.makeStream()
    }

    func connect() async throws {}
    func write(_ data: Data) async {
        onWrite?(data)
        output.yield(data)
    }
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async { output.finish(); exit.finish() }
    nonisolated func emit(_ data: Data) { output.yield(data) }
}

/// 记录写入、能收图的后端（M14）。
actor CaptureBackend: TerminalImageReceiving {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    nonisolated let programsCanReadMacClipboard = false
    private nonisolated let output: AsyncStream<Data>.Continuation
    private nonisolated let exit: AsyncStream<Void>.Continuation
    private(set) var written = Data()
    private(set) var delivered = 0

    init() {
        (outputStream, output) = AsyncStream<Data>.makeStream()
        (exitStream, exit) = AsyncStream<Void>.makeStream()
    }

    func connect() async throws {}
    func write(_ data: Data) async { written.append(data) }
    func resize(cols: UInt16, rows: UInt16) async {}
    func close() async { output.finish(); exit.finish() }
    func deliverImage(_ image: uTerm.TerminalImage) async throws -> TerminalImageDelivery {
        delivered += 1
        return .file(path: "/tmp/shot.png")
    }
    func clear() { written = Data() }
    nonisolated func emit(_ data: Data) { output.yield(data) }
}

// 【迁移中，暂未编译】测量窗格还带着 SwiftTerm 那一半；`GhosttyMeasureTests` 改写时把它改成只有 Ghostty。
#if UTERM_LEGACY_SWIFTTERM_TESTS
// MARK: - 窗格

/// 一个测量用窗格：SwiftTerm 视图、Ghostty 视图，或 Ghostty + 不上屏的 SwiftTerm 影子（spike 的形态）。
@MainActor
final class MeasurePane {
    enum Engine: String, CaseIterable {
        case swiftterm
        case ghostty
        case ghosttyShadow = "ghostty+shadow"
    }

    nonisolated final class ViewportBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: InMemoryTerminalViewport?
        var value: InMemoryTerminalViewport? { lock.withLock { stored } }
        func set(_ v: InMemoryTerminalViewport) { lock.withLock { stored = v } }
    }

    nonisolated final class IOBox: @unchecked Sendable {
        weak var io: InMemoryTerminalSession?
        var onWrite: (@Sendable (Data) -> Void)?
    }

    /// 测 Ghostty 回滚行数用：滚动条回调报的 total（回滚 + 屏）。
    final class ScrollbarProxy: TerminalSurfaceScrollbarDelegate {
        var last: TerminalScrollbar?
        func terminalDidUpdateScrollbar(_ scrollbar: TerminalScrollbar) { last = scrollbar }
    }

    let engine: Engine
    let view: NSView
    private(set) var swiftTerm: CopyableTerminalView?
    private(set) var ghostty: GhosttySurfaceView?
    private(set) var io: InMemoryTerminalSession?
    let viewport: ViewportBox
    let ioBox: IOBox
    let scrollbar: ScrollbarProxy
    private(set) var watch: GhosttyFrameWatch?
    private(set) var draws = 0
    var window: NSWindow?

    init(engine: Engine, frame: NSRect, controller: GhosttyTerminal.TerminalController?, scrollbackLines: Int) {
        self.engine = engine
        let box = ViewportBox(), ioBox = IOBox(), proxy = ScrollbarProxy()
        viewport = box
        self.ioBox = ioBox
        scrollbar = proxy
        var settings = TerminalSettings.read()
        settings.scrollback = scrollbackLines
        switch engine {
        case .swiftterm:
            let st = CopyableTerminalView(frame: frame)
            TerminalTheme.apply(to: st, settings: settings, dark: true)
            swiftTerm = st
            view = st
        case .ghostty, .ghosttyShadow:
            let session = InMemoryTerminalSession(
                write: { data in ioBox.onWrite?(data) },
                resize: { box.set($0) })
            ioBox.io = session
            io = session
            let gh = GhosttySurfaceView(frame: frame)
            gh.controller = controller ?? GhosttyTerminalConfig.controller
            gh.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            gh.delegate = proxy
            ghostty = gh
            view = gh
            if engine == .ghosttyShadow {
                // 影子：不进窗口、不上屏，只解析（spike 的「Ghostty 渲染 + 影子 SwiftTerm」）。
                let st = CopyableTerminalView(frame: frame)
                TerminalTheme.apply(to: st, settings: settings, dark: true)
                swiftTerm = st
            }
        }
        if engine == .swiftterm, let st = swiftTerm {
            SwiftTermDrawProbe.hook(st) { [weak self] _ in self?.draws += 1 }
        }
    }

    /// 视图进了窗口之后调：Ghostty 建好 surface、开始 KVO 出帧。
    func attachWatchIfNeeded() {
        guard watch == nil, let gh = ghostty, let layer = GhosttyFrameWatch.contentLayer(of: gh) else { return }
        watch = GhosttyFrameWatch(layer: layer)
    }

    var isReady: Bool {
        switch engine {
        case .swiftterm: return view.window != nil
        case .ghostty, .ghosttyShadow: return viewport.value != nil
        }
    }

    func feed(_ bytes: ArraySlice<UInt8>) {
        if let io { io.receive(Data(bytes)) }
        swiftTerm?.feed(byteArray: bytes)
    }

    var pending: Int { io?.pendingOutputByteCount ?? 0 }

    /// 已出帧数：Ghostty 数 contents 变化，SwiftTerm 数 draw。
    var frames: Int { engine == .swiftterm ? draws : (watch?.count ?? 0) }

    /// 回滚里实际留下的行数（不含屏幕本身）。
    var scrollbackRows: Int? {
        switch engine {
        case .swiftterm:
            return swiftTerm.map { $0.getTerminal().getTopVisibleRow() }
        case .ghostty, .ghosttyShadow:
            guard let s = scrollbar.last else { return nil }
            return Int(s.total) - Int(s.len)
        }
    }

    func setVisible(_ visible: Bool) { ghostty?.setSurfaceVisible(visible) }

    /// 视图移出窗口，但对象（以及 Ghostty 的 surface、回滚）留着。
    func detachFromWindow() {
        if let window, window.contentView === view { window.contentView = NSView() } else { view.removeFromSuperview() }
    }

    func dispose() {
        if let st = swiftTerm { SwiftTermDrawProbe.unhook(st) }
        watch = nil
        ghostty?.delegate = nil
        detachFromWindow()
        window?.orderOut(nil)
        window = nil
    }
}

#endif

// MARK: - 负载

nonisolated enum MeasureLoad {
    struct RNG {
        var state: UInt64
        mutating func next() -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int(truncatingIfNeeded: (z ^ (z >> 31)) & 0x7FFF_FFFF)
        }
    }

    static let words = ["alpha", "beta", "gamma", "delta", "build", "ok", "error", "warn", "main.swift", "uTerm",
                        "Compiling", "Linking", "src/renderer/metal.zig", "200", "GET", "/api/v1/users", "→", "✓"]
    static let cjk = Array("终端渲染性能测试中文字符宽度对齐滚动历史选区复制光标样式最低对比度远程控制会话")

    /// 「日常」内容：每行不超过 `cols` 列、不折行。60% 纯文本日志，25% 少量 16 / 256 色片段，10% 中文，5% 盒线 + 粗体。
    static func typicalLines(count: Int, cols: Int, seed: UInt64 = 0x5EED) -> [UInt8] {
        var rng = RNG(state: seed)
        var out = [UInt8]()
        out.reserveCapacity(count * 90)
        for i in 0..<count {
            var s = ""
            var width = 0
            func add(_ w: String) { s += w; width += w.count }
            switch rng.next() % 20 {
            case 0..<12:
                add(String(format: "%06d ", i))
                while width < cols - 14 { add(words[rng.next() % words.count] + " ") }
            case 12..<17:
                add(String(format: "%06d ", i))
                while width < cols - 14 {
                    let w = words[rng.next() % words.count]
                    if rng.next() % 3 == 0 {
                        s += rng.next() % 2 == 0 ? "\u{1B}[3\(1 + rng.next() % 6)m" : "\u{1B}[38;5;\(rng.next() % 256)m"
                        add(w)
                        s += "\u{1B}[0m "
                        width += 1
                    } else {
                        add(w + " ")
                    }
                }
            case 17, 18:
                add(String(format: "%06d ", i))
                for _ in 0..<min(30, (cols - 10) / 2) { s.append(cjk[rng.next() % cjk.count]); width += 2 }
            default:
                s += "\u{1B}[1m"
                add(String(format: "%06d ┌──────┬──────┐ │ ok │", i))
                s += "\u{1B}[0m"
            }
            s += "\r\n"
            out += Array(s.utf8)
        }
        return out
    }

    #if UTERM_LEGACY_SWIFTTERM_TESTS
    /// 「重」内容：GhosttySpikeTests.makeLoad 的分布（每行最多 60 个不同真彩样式），按行数截取。
    static func heavyLines(count: Int) -> [UInt8] {
        let load = GhosttySpikeTests.makeLoad(bytes: count * 400)
        var lines = 0
        var end = load.count
        for (i, b) in load.enumerated() where b == 0x0A {
            lines += 1
            if lines == count { end = i + 1; break }
        }
        return Array(load[0..<end])
    }
    #endif

    /// Claude Code 式的一帧：同步更新（DEC 2026）里重画底部 12 行的活动区（转圈、计数、输入框、状态行），
    /// 每 4 帧先提交 2 行新内容（活动区随之下移，触发滚动）。
    static func claudeFrame(tick: Int, cols: Int) -> [UInt8] {
        let live = 12
        let spinner = ["✻", "✽", "✶", "✳", "✢", "·"]
        var s = "\u{1B}[?2026h\u{1B}[\(live - 1)A\r"
        if tick % 4 == 0 {
            for k in 0..<2 {
                s += "\u{1B}[2K\u{1B}[38;5;\(70 + (tick + k) % 60)m⏺\u{1B}[0m Updated \u{1B}[1msrc/file\(tick % 97).swift\u{1B}[0m with \(tick % 13 + k) additions and \(tick % 7) removals\r\n"
            }
        }
        let bar = String(repeating: "─", count: max(10, cols - 2))
        let lines = [
            "\u{1B}[38;5;208m\(spinner[tick % spinner.count]) Thinking… \u{1B}[0m\u{1B}[2m(\(tick / 10)s · ↑ \(1200 + tick * 7) tokens · esc to interrupt)\u{1B}[0m",
            "",
            "\u{1B}[2m╭\(bar)╮\u{1B}[0m",
            "\u{1B}[2m│\u{1B}[0m > 帮我把这个函数改成异步的，顺便补上测试\(String(repeating: " ", count: max(0, cols - 40)))\u{1B}[2m│\u{1B}[0m",
            "\u{1B}[2m╰\(bar)╯\u{1B}[0m",
            "  \u{1B}[38;5;141m⏵⏵ accept edits on\u{1B}[0m \u{1B}[2m(shift+tab to cycle)\u{1B}[0m",
            "",
            "  \u{1B}[2m? for shortcuts\u{1B}[0m",
            "", "", "",
            "  \u{1B}[38;5;244mcontext \(tick % 100)%\u{1B}[0m",
        ]
        for (i, line) in lines.enumerated() {
            s += "\u{1B}[2K" + line
            if i < lines.count - 1 { s += "\r\n" }
        }
        s += "\u{1B}[?2026l"
        return Array(s.utf8)
    }

    /// 整屏刷新：同步更新里从左上角重写每一格（像 btop / cmatrix）。
    static func fullScreenFrame(tick: Int, cols: Int, rows: Int) -> [UInt8] {
        var rng = RNG(state: UInt64(tick) &* 0x1234_5678)
        var s = "\u{1B}[?2026h\u{1B}[H"
        let glyphs = Array("abcdefghijklmnopqrstuvwxyz0123456789#%&*+=-")
        for r in 0..<rows {
            s += "\u{1B}[38;5;\(16 + (r + tick) % 216)m"
            var line = ""
            for _ in 0..<cols { line.append(glyphs[rng.next() % glyphs.count]) }
            s += line
            if r < rows - 1 { s += "\r\n" }
        }
        s += "\u{1B}[0m\u{1B}[?2026l"
        return Array(s.utf8)
    }
}

// MARK: - 格子几何

@MainActor
enum GhosttyGeometry {
    /// Ghostty 格子的尺寸（点）。`InMemoryTerminalViewport.cellWidthPixels / cellHeightPixels` 实测恒为 0，
    /// 所以用公开的 `viewportCell(at:)` 扫出来：x / y 每 0.25 pt 走一步，列号 / 行号第一次变成 1 的位置就是一格。
    static func cellPoints(_ view: AppTerminalView) -> CGSize? {
        let h = view.bounds.height
        var w: CGFloat?, ch: CGFloat?
        var x: CGFloat = 0.25
        while x < 60 {
            if let c = view.viewportCell(at: NSPoint(x: x, y: h - 1)), c.column >= 1 { w = x; break }
            x += 0.25
        }
        var y: CGFloat = 0.25
        while y < 80 {
            if let c = view.viewportCell(at: NSPoint(x: 1, y: h - y)), c.row >= 1 { ch = y; break }
            y += 0.25
        }
        guard let w, let ch else { return nil }
        return CGSize(width: w, height: ch)
    }
}

// MARK: - 事件

@MainActor
enum RealEvents {
    static func key(_ type: NSEvent.EventType, window: NSWindow, characters: String, ignoring: String? = nil,
                    keyCode: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
                         isARepeat: false, keyCode: UInt16(keyCode))!
    }

    /// 一次按键（down + up）走窗口的 `sendEvent`。带 ⌘ / ⌃ 的先按 NSApplication 的顺序给窗口
    /// `performKeyEquivalent`（菜单之外的那一段），没人接再 `sendEvent`。返回是否被 key equivalent 接走。
    @discardableResult
    static func press(window: NSWindow, characters: String, ignoring: String? = nil, keyCode: Int,
                      modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let down = key(.keyDown, window: window, characters: characters, ignoring: ignoring, keyCode: keyCode, modifiers: modifiers)
        var handled = false
        if !modifiers.intersection([.command, .control]).isEmpty {
            handled = window.performKeyEquivalent(with: down)
        }
        if !handled { window.sendEvent(down) }
        window.sendEvent(key(.keyUp, window: window, characters: characters, ignoring: ignoring, keyCode: keyCode, modifiers: modifiers))
        return handled
    }

    static func mouse(_ type: NSEvent.EventType, window: NSWindow, at point: NSPoint, clickCount: Int = 1,
                      modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseUp ? 0 : 1)!
    }

    static let letterKeyCodes: [(Character, Int)] = [
        ("a", kVK_ANSI_A), ("s", kVK_ANSI_S), ("d", kVK_ANSI_D), ("f", kVK_ANSI_F), ("g", kVK_ANSI_G),
        ("h", kVK_ANSI_H), ("j", kVK_ANSI_J), ("k", kVK_ANSI_K), ("l", kVK_ANSI_L), ("q", kVK_ANSI_Q),
        ("w", kVK_ANSI_W), ("e", kVK_ANSI_E), ("r", kVK_ANSI_R), ("t", kVK_ANSI_T), ("y", kVK_ANSI_Y),
        ("u", kVK_ANSI_U), ("i", kVK_ANSI_I), ("o", kVK_ANSI_O), ("p", kVK_ANSI_P), ("n", kVK_ANSI_N),
        ("m", kVK_ANSI_M), ("z", kVK_ANSI_Z), ("x", kVK_ANSI_X), ("c", kVK_ANSI_C), ("v", kVK_ANSI_V), ("b", kVK_ANSI_B),
    ]

    static func keyCode(for c: Character) -> Int {
        letterKeyCodes.first { $0.0 == c }?.1 ?? kVK_Space
    }
}

/// 同步跑主 run loop 直到条件成立或超时（`RunLoop.run` 不能在 async 上下文里直接调）。
@MainActor
enum Spin {
    @discardableResult
    static func until(_ timeout: TimeInterval, step: TimeInterval = 0.0005, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(step))
        }
        return true
    }

    static func `for`(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    }
}
