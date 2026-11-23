#if DEBUG
import Foundation
import GhosttyTerminal
import IOSurface
import ObjectiveC
import QuartzCore
import UIKit

/// 调试（只在 Debug 构建里认）：系统滚动途中引擎的 wakeup 要不要在主线程同步重画（libghostty-spm 补丁 #20 的 A/B），
/// 同一个包里凭手感比。启动参数：
/// - `-GhosttySyncDrawDuringScroll YES`：一律同步重画（补丁 #20 之前）；
/// - `-GhosttySyncDrawDuringScroll touching`：只在手指按着 / 拖着时不画，减速照旧画；
/// - `-GhosttySyncDrawDuringScroll moving`：滚动动着时都不画、wakeup 也不开 display link（补丁 #20，默认）；
/// - `-GhosttySyncDrawDuringScroll moving-link`：不画，但 wakeup 照旧开 display link（补丁 #20 的第一版）；
/// - 不写：用包里的默认（`UTermScrollTrace.defaultScrollWakeupSyncDraw`）。
/// 也可以 `defaults write` 同一个键（真机上就是启动参数）。
enum GhosttyScrollDebugSwitch {
    static func apply(_ defaults: UserDefaults = .standard) {
        guard var raw = defaults.string(forKey: DefaultsKey.ghosttySyncDrawDuringScroll)?.lowercased(), !raw.isEmpty else { return }
        // 末尾 `+wait毫秒`（如 `hold+wait3.5`、`auto:hold+wait3.5`）：打开「同一帧等渲染」的实验。
        if let range = raw.range(of: "+wait") {
            UTermScrollTrace.scrollSameFrameWaitMilliseconds = Double(raw[range.upperBound...]) ?? 0
            raw = String(raw[..<range.lowerBound])
        }
        // `auto:做法,做法,…`：App 自己按脚本滚，这几种做法轮着来（`GhosttyScrollAutoPilot`），打点写进 scroll-trace-auto.txt。
        if raw.hasPrefix("auto:") {
            let policies = raw.dropFirst(5).split(separator: ",").compactMap { UTermScrollTrace.ScrollWakeupSyncDraw(rawValue: String($0)) }
            guard !policies.isEmpty else { return }
            UTermScrollTrace.emitsSignposts = true
            startRecording(policy: "auto")
            GhosttyScrollAutoPilot.start(policies: policies)
            return
        }
        let policy: UTermScrollTrace.ScrollWakeupSyncDraw? = switch raw {
        case "yes", "1", "true": .always
        case "no", "0", "false": .deferWhileMoving
        default: UTermScrollTrace.ScrollWakeupSyncDraw(rawValue: raw)
        }
        guard let policy else { return }
        // 写了这个参数就是在比手感：顺带打开 signpost，外面随时可以用 xctrace 录真手滚动（没人录时每条约 1 µs）。
        UTermScrollTrace.emitsSignposts = true
        UTermScrollTrace.scrollWakeupSyncDraw = policy
        startRecording(policy: policy.rawValue)
        FileHandle.standardError.write(Data("[ghostty-scroll] wakeup sync draw during scroll: \(policy.rawValue)\n".utf8))
    }

    /// 真手录制：滚动打点（每次 didScroll 的位置、触摸阶段、同步重画、display link 起停、跨行，以及每次出帧时画面里
    /// 实际滚到的位置 `present`，见 `GhosttyScrollPresentProbe`）每秒写进 `Documents/scroll-trace-<做法>.txt`
    ///（每行「时刻 种类 值」，时刻是 `CACurrentMediaTime()`，和 xctrace 的时间零点同一个钟），外面用
    /// `devicectl device copy from` 取。每次启动重写这个文件。
    private static var recordingTimer: Timer?
    private static func startRecording(policy: String) {
        guard recordingTimer == nil,
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("scroll-trace-\(policy).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("# policy \(policy)\n".utf8))
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        UTermScrollTrace.isEnabled = true
        startMainBusyWatch()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            // 图层的类是第一个 surface 建出来时才注册的，装上为止每秒试一次。
            GhosttyScrollPresentProbe.installIfPossible()
            var text = GhosttyScrollPresentProbe.takeDiagnostics().map { "# \($0)\n" }.joined()
            text += GhosttyMainThreadSampler.take().map { "# \($0)\n" }.joined()
            for event in UTermScrollTrace.drain() { text += String(format: "%.6f %@ %.3f\n", event.time, event.kind, event.value) }
            guard !text.isEmpty else { return }
            handle.write(Data(text.utf8))
        }
    }
}

extension GhosttyScrollDebugSwitch {
    /// 主线程每一轮 run loop 从醒来到再睡花了多久，≥ 2 ms 的记成打点 `main-busy`（时刻 = 醒来那一刻，值 = 毫秒）。
    nonisolated(unsafe) private static var wokeAt: CFTimeInterval = 0
    fileprivate static func startMainBusyWatch() {
        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true, 0
        ) { _, activity in
            let now = CACurrentMediaTime()
            if activity == .afterWaiting {
                wokeAt = now
                GhosttyMainThreadSampler.wokeAt = now
            } else if wokeAt > 0 {
                let ms = (now - wokeAt) * 1000
                if ms >= 2 { UTermScrollTrace.noteSpan("main-busy", start: wokeAt, milliseconds: ms) }
                wokeAt = 0
                GhosttyMainThreadSampler.wokeAt = 0
            }
        }
        GhosttyMainThreadSampler.start()
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// 进程内采样（vphone 里 Instruments 的 Time Profiler 采不到 App）：主线程这一轮 run loop 醒了超过 3 ms 还没睡，
/// 就每 0.5 ms 挂起它、沿帧指针抓一次调用栈，符号化后攒着，由录制的定时器写进文件（`S 时刻 这轮已忙毫秒 帧|帧|…`）。
nonisolated enum GhosttyMainThreadSampler {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) static var wokeAt: CFTimeInterval = 0

    static func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = lines
        lines.removeAll()
        return out
    }

    /// 在主线程上调。
    static func start() {
        guard !started else { return }
        started = true
        let main = mach_thread_self()
        let thread = Thread {
            var names: [UInt: String] = [:]
            while true {
                usleep(500)
                let woke = wokeAt
                guard woke > 0 else { continue }
                let busy = CACurrentMediaTime() - woke
                guard busy > 0.003, busy < 1 else { continue }
                var frames: [UInt] = []
                guard thread_suspend(main) == KERN_SUCCESS else { continue }
                var state = arm_thread_state64_t()
                var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &state) {
                    $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                        thread_get_state(main, ARM_THREAD_STATE64, $0, &count)
                    }
                }
                if result == KERN_SUCCESS {
                    frames.append(UInt(state.__pc) & 0x0000_000F_FFFF_FFFF)
                    var fp = UInt(state.__fp)
                    var depth = 0
                    while fp > 0x1000, fp & 0x7 == 0, depth < 48 {
                        var pair: (UInt, UInt) = (0, 0)
                        var size: vm_size_t = 0
                        let read = withUnsafeMutablePointer(to: &pair) {
                            vm_read_overwrite(mach_task_self_, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &size)
                        }
                        guard read == KERN_SUCCESS, size == 16 else { break }
                        frames.append(pair.1 & 0x0000_000F_FFFF_FFFF)
                        if pair.0 <= fp { break }
                        fp = pair.0
                        depth += 1
                    }
                }
                thread_resume(main)
                guard !frames.isEmpty else { continue }
                var parts: [String] = []
                for address in frames.prefix(40) {
                    if let known = names[address] { parts.append(known); continue }
                    var info = Dl_info()
                    var name = String(address, radix: 16)
                    if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 {
                        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
                        let symbol = info.dli_sname.map { String(cString: $0) } ?? name
                        name = "\(image)`\(symbol.prefix(110))"
                    }
                    names[address] = name
                    parts.append(name)
                }
                let line = String(format: "S %.6f %.1f ", woke + busy, busy * 1000) + parts.joined(separator: "|")
                lock.lock(); lines.append(line); lock.unlock()
            }
        }
        thread.name = "uterm.main-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

/// 真手录制：Ghostty 每交一帧（给 `IOSurfaceLayer` 设 contents）就从那张画面里读出它滚到了哪，记成打点 `present`
///（值 = 画面顶边在回滚内容里的像素位置，按 128 行回绕；读不出来记 -1；不在主线程上交的记 `present-off`）。
/// 要配滚动测试终端（`-LiveActivityDebugDemo scroll`）：它每行开头 7 格是行号的二进制条码。只在录制时装。
nonisolated enum GhosttyScrollPresentProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false
    nonisolated(unsafe) private static var diagnostics: [String] = []
    nonisolated(unsafe) private static var cells: [ObjectIdentifier: (width: Int, height: Int)] = [:]
    nonisolated(unsafe) private static var diagnosed = 0
    static let bits = 7

    static func takeDiagnostics() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = diagnostics
        diagnostics.removeAll()
        return out
    }

    @discardableResult
    static func installIfPossible() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if installed { return true }
        guard let cls = NSClassFromString("IOSurfaceLayer") else { return false }
        let selector = NSSelectorFromString("setContents:")
        guard let inherited = class_getInstanceMethod(cls, selector) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(inherited), to: Setter.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in
            GhosttyScrollPresentProbe.presented(layer: layer, contents: contents)
            original(layer, selector, contents)
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, selector, imp, method_getTypeEncoding(inherited)) {
            method_setImplementation(inherited, imp)
        }
        installed = true
        diagnostics.append("present probe installed")
        return true
    }

    private static func presented(layer: AnyObject, contents: AnyObject?) {
        guard let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() else { return }
        guard Foundation.Thread.isMainThread else {
            UTermScrollTrace.note("present-off", 0)
            return
        }
        let id = ObjectIdentifier(layer)
        lock.lock()
        var cell = cells[id]
        lock.unlock()
        if cell == nil {
            nonisolated(unsafe) let target = layer
            cell = MainActor.assumeIsolated { cellPixels(of: target) }
            if let cell {
                lock.lock(); cells[id] = cell; lock.unlock()
            }
        }
        guard let cell else {
            UTermScrollTrace.note("present", -1)
            return
        }
        let surface = unsafeBitCast(contents, to: IOSurfaceRef.self)
        UTermScrollTrace.note("present", position(of: surface, cellWidth: cell.width, cellHeight: cell.height) ?? -1)
    }

    /// 图层往上找到终端视图，取它一个格子的物理像素尺寸。
    @MainActor
    private static func cellPixels(of layer: AnyObject) -> (width: Int, height: Int)? {
        var current = layer as? CALayer
        while let candidate = current {
            if let view = candidate.delegate as? UITerminalView, let size = view.uTermCellPixels {
                return (Int(size.width), Int(size.height))
            }
            current = candidate.superlayer
        }
        return nil
    }

    /// 同 `GhosttyOnScreenScrollTests.BarcodeDecoder`：第 0 列逐行交替，扫一列像素找到第一条行界，读它下面那一行的条码。
    private static func position(of surface: IOSurfaceRef, cellWidth: Int, cellHeight: Int) -> Double? {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let element = IOSurfaceGetBytesPerElement(surface)
        let lum: (Int, Int) -> Double
        switch element {
        case 4:
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            lum = { x, y in
                let p = bytes + y * rowBytes + x * 4
                return Double(Int(p[0]) + Int(p[1]) + Int(p[2])) / 765
            }
        case 8:
            lum = { x, y in
                let p = (base + y * rowBytes + x * 8).assumingMemoryBound(to: UInt16.self)
                return Double(Float(Float16(bitPattern: p[0])) + Float(Float16(bitPattern: p[1]))
                    + Float(Float16(bitPattern: p[2]))) / 3
            }
        default:
            return nil
        }
        guard width > cellWidth * (bits + 1), height > cellHeight * 3 else { return nil }
        let background = lum(width - 3, height / 2)
        let ink: (Int, Int) -> Bool = { x, y in abs(lum(x, y) - background) > 0.3 }
        let x0 = cellWidth / 2
        var previous = ink(x0, 0)
        var edge = -1
        for y in 1 ..< min(height, cellHeight * 3) {
            let now = ink(x0, y)
            if now != previous { edge = y; break }
            previous = now
        }
        if diagnosed < 3 {
            diagnosed += 1
            let column = stride(from: 0, to: min(height, cellHeight * 3), by: 3).map { String(format: "%.2f", lum(x0, $0)) }
            let row = stride(from: 0, to: min(width, cellWidth * 10), by: 4).map {
                String(format: "%.2f", lum($0, max(0, edge) + cellHeight / 2))
            }
            lock.lock()
            diagnostics.append("size=\(width)x\(height) cell=\(cellWidth)x\(cellHeight) element=\(element) bg=\(background) "
                + "edge=\(edge) col0=\(column.joined(separator: ",")) row=\(row.joined(separator: ","))")
            lock.unlock()
        }
        guard edge > 0, edge + cellHeight / 2 < height else { return nil }
        let middle = edge + cellHeight / 2
        var row = 0
        for bit in 0 ..< bits where ink(bit * cellWidth + cellWidth / 2, middle) {
            row |= 1 << bit
        }
        return Double(row * cellHeight - edge)
    }
}
#endif
