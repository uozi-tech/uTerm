import Darwin
import Foundation
import QuartzCore
import UIKit
import XCTest

/// 主线程卡住时它在干什么：一条旁路线程每毫秒看一眼，主线程这一轮 runloop 已经忙过 `threshold` 了就把它停一下、
/// 沿帧指针抄一份调用栈（地址），放开；事后用 `dladdr` 换成符号名。
///
/// 帧率类探针只知道「这一拍主线程忙了 30 ms、不在我们记的那几项里」（`GhosttyFrameBudgetTests` 的 other），
/// 不知道是谁。这个夹具回答「是谁」。只在 arm64 上能抄栈（真机、Apple 芯片上的模拟器）；别的架构只记时长。
///
/// 抄栈那一小段主线程是被挂起的：期间不能分配内存、不能拿锁（主线程可能正握着 malloc 的锁），所以栈先抄进
/// 预先分好的缓冲区，放开主线程之后再搬进数组。
nonisolated final class MainThreadStallSampler: @unchecked Sendable {
    struct Sample {
        /// 抄栈的时刻（`CACurrentMediaTime`）。
        let time: Double
        /// 那一刻主线程这一轮已经忙了多久（ms）。
        let busyMS: Double
        /// 调用栈，叶子在前。
        let frames: [UInt]
    }

    private let threshold: Double
    private let interval: Double
    private let maxFrames = 256
    private let scratch: UnsafeMutablePointer<UInt>
    /// 主线程这一轮 runloop 从什么时候开始忙（0 = 在睡）。主线程写、旁路线程读，对齐的 8 字节，读到撕裂值的后果只是多 / 少抄一次。
    private let busySince: UnsafeMutablePointer<Double>
    private let running: UnsafeMutablePointer<Bool>
    private var observers: [CFRunLoopObserver] = []
    private var thread: Thread?
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var mainThread: thread_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0

    /// `threshold`：这一轮忙过多久开始抄（秒）；`interval`：同一次卡住里每隔多久再抄一份。
    init(threshold: Double = 0.006, interval: Double = 0.004) {
        self.threshold = threshold
        self.interval = interval
        scratch = .allocate(capacity: maxFrames)
        busySince = .allocate(capacity: 1)
        busySince.initialize(to: 0)
        running = .allocate(capacity: 1)
        running.initialize(to: false)
    }

    deinit {
        scratch.deallocate()
        busySince.deallocate()
        running.deallocate()
    }

    @MainActor
    func start() {
        guard !running.pointee else { return }
        let me = pthread_self()
        mainThread = pthread_mach_thread_np(me)
        let top = UInt(bitPattern: pthread_get_stackaddr_np(me))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(me))
        let since = busySince
        func add(_ activity: CFRunLoopActivity, _ order: CFIndex, _ body: @escaping () -> Void) {
            let observer = CFRunLoopObserverCreateWithHandler(nil, activity.rawValue, true, order) { _, _ in body() }
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer!)
        }
        since.pointee = CACurrentMediaTime()
        add(.afterWaiting, CFIndex.min) { since.pointee = CACurrentMediaTime() }
        add(.beforeWaiting, CFIndex.max) { since.pointee = 0 }
        running.pointee = true
        let thread = Thread { [self] in sampleLoop() }
        thread.name = "uterm-stall-sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    @MainActor
    func stop() {
        running.pointee = false
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers.removeAll()
        thread = nil
    }

    private func sampleLoop() {
        var lastSample = 0.0
        while running.pointee {
            usleep(1000)
            let since = busySince.pointee
            guard since > 0 else { continue }
            let now = CACurrentMediaTime()
            guard now - since >= threshold, now - lastSample >= interval else { continue }
            lastSample = now
            let count = capture()
            let frames = Array(UnsafeBufferPointer(start: scratch, count: count))
            lock.lock()
            samples.append(Sample(time: now, busyMS: (now - since) * 1000, frames: frames))
            lock.unlock()
        }
    }

    /// 停住主线程、抄栈、放开。返回抄到几帧。
    private func capture() -> Int {
        #if arch(arm64)
            guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
            defer { thread_resume(mainThread) }
            var state = arm_thread_state64_t()
            var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &state) {
                $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                    thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return 0 }
            let mask: UInt = 0x0000_000F_FFFF_FFFF
            var n = 0
            scratch[n] = UInt(state.__pc) & mask; n += 1
            scratch[n] = UInt(state.__lr) & mask; n += 1
            var fp = UInt(state.__fp)
            while n < maxFrames, fp >= stackLow, fp + 16 <= stackHigh, fp & 0x7 == 0 {
                guard let record = UnsafePointer<UInt>(bitPattern: fp) else { break }
                let next = record[0], lr = record[1] & mask
                if lr == 0 { break }
                scratch[n] = lr; n += 1
                if next <= fp { break }
                fp = next
            }
            return n
        #else
            return 0
        #endif
    }

    /// 取出并清空。
    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll()
        return out
    }

    // MARK: 报告

    /// 一次卡住 = 主线程连续忙着的一段里抄到的那几份栈（相邻两份隔不到 `interval` 的 3 倍算同一段）。
    struct Stall {
        let start: Double
        /// 这一段里抄到的最后一份栈那一刻主线程已经忙了多久（ms）：卡住时长的下限。
        let busyMS: Double
        let samples: [Sample]
    }

    func stalls(from samples: [Sample]) -> [Stall] {
        var out: [Stall] = []
        var current: [Sample] = []
        for sample in samples {
            if let last = current.last, sample.time - last.time > interval * 3 || sample.busyMS < last.busyMS {
                out.append(Stall(start: current[0].time - current[0].busyMS / 1000, busyMS: last.busyMS, samples: current))
                current = []
            }
            current.append(sample)
        }
        if let last = current.last {
            out.append(Stall(start: current[0].time - current[0].busyMS / 1000, busyMS: last.busyMS, samples: current))
        }
        return out
    }

    /// 一个地址 → `镜像名`符号名`（Swift 符号是没还原的，拿 `xcrun swift-demangle` 过一遍）。
    static func symbol(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { URL(fileURLWithPath: String(cString: $0)).lastPathComponent } ?? "?"
        let name = info.dli_sname.map { String(cString: $0) } ?? String(format: "0x%lx", address)
        return "\(image)`\(name)"
    }

    /// 每次卡住一行：开始时刻（相对 `origin`，ms）、时长下限、抄到几份、然后是其中三份（头、中、尾）的栈，
    /// 每份从叶子往上列 `depth` 帧。
    func report(_ samples: [Sample], origin: Double, depth: Int = 22, limit: Int = 16) -> [String] {
        stalls(from: samples).sorted { $0.busyMS > $1.busyMS }.prefix(limit).map { stall in
            let picks = stall.samples.count <= 3 ? stall.samples
                : [stall.samples[0], stall.samples[stall.samples.count / 2], stall.samples[stall.samples.count - 1]]
            let stacks = picks.map { sample in
                String(format: "@%.0fms: ", sample.busyMS)
                    + sample.frames.prefix(depth).map(Self.symbol).joined(separator: " < ")
            }
            return String(format: "t=%+.0fms busy>=%.0fms samples=%d || ", (stall.start - origin) * 1000, stall.busyMS,
                          stall.samples.count) + stacks.joined(separator: " || ")
        }
    }
}

/// 按 120 Hz 的显示节拍判定的探针（每拍 8.3 ms、每拍位移、一段时间里 link 回调了几次）在刷新率不到 120 Hz 的屏上
/// 没法判定——模拟器恒为 60 Hz。这种屏上跳过并写明原因，真机上照常判定。
@MainActor
func skipUnlessHighRefreshDisplay(file: StaticString = #filePath, line: UInt = #line) throws {
    let fps = UIScreen.main.maximumFramesPerSecond
    try XCTSkipUnless(fps >= 120, "这条按 120 Hz 的显示节拍判定（每拍 8.3 ms），这块屏最高 \(fps) Hz（模拟器恒为 60 Hz），"
        + "在真机上跑", file: file, line: line)
}

/// 夹具自证：主线程故意卡 60 ms，抄到的栈里要有卡住它的那个函数；主线程闲着时一份也不抄。
@MainActor
final class MainThreadStallSamplerTests: XCTestCase {
    @inline(never)
    private func uTermStallProbeBusyWait(_ seconds: Double) -> Int {
        let deadline = CACurrentMediaTime() + seconds
        var spins = 0
        while CACurrentMediaTime() < deadline { spins &+= 1 }
        return spins
    }

    func testCapturesWhatTheMainThreadWasDoing() async throws {
        #if !arch(arm64)
            throw XCTSkip("只在 arm64 上抄得到主线程的栈")
        #else
            let sampler = MainThreadStallSampler()
            sampler.start()
            defer { sampler.stop() }
            // 闲着：让主线程睡 150 ms，一份也不该抄到。
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(sampler.drain().isEmpty, "主线程闲着也被当成卡住了")
            let origin = CACurrentMediaTime()
            XCTAssertGreaterThan(uTermStallProbeBusyWait(0.06), 0)
            try await Task.sleep(for: .milliseconds(30))
            let samples = sampler.drain()
            XCTAssertGreaterThanOrEqual(samples.count, 5, "卡了 60 ms，每 4 ms 抄一份，至少该有几份")
            let symbols = samples.flatMap { $0.frames.map(MainThreadStallSampler.symbol) }
            // 符号名是没还原的 Swift 名字，里面的词会被压缩替换，只认得出后半截。
            XCTAssertTrue(symbols.contains { $0.contains("ProbeBusyWait") },
                          "栈里没有卡住主线程的那个函数：\(sampler.report(samples, origin: origin).first ?? "-")")
            let stall = try XCTUnwrap(sampler.stalls(from: samples).max { $0.busyMS < $1.busyMS })
            XCTAssertGreaterThan(stall.busyMS, 40, "卡住的时长量短了")
        #endif
    }
}
