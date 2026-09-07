import AppKit
import Darwin

// 抄自 uTable commit 65fb6eb（`git -C <workspace>/uTable log -1 --format=%h -- uTableTests/ProbeMetrics.swift`）。
//
// 移植到 uTerm 时的改动（只做编译所需的最小改动）：
// 1. 去掉 `@testable import uTable`。
// 2. 去掉 `DataGridTableView.Callbacks.inert` 扩展 —— 它依赖 uTable 专有类型，
//    在 uTerm 里没有对应物。通用的 `NSView.firstScrollView()` 原样保留。
// 三把尺（`percentile` / `threadCPUSeconds` / `footprintMB`）与 uTable 一字不差。

/// 性能探针共用的三把尺 + 一件夹具零件。
///
/// 以前每个探针文件各抄一份 —— 抄出来的口径不一样（分位数有的取
/// `sorted[count/2]` 有的取 `sorted[Int(count*0.5)]`，内存有的读 RSS 有的读
/// `phys_footprint`），于是两份报告里的同一个名字讲的不是同一件事。这里收一处。
enum ProbeMetrics {

    /// 分位数。**统一口径**：升序后取 `sorted[min(count-1, Int(count * q))]`。
    ///
    /// 它不是插值分位数，样本少的时候会偏保守（`q = 0.5`、4 个样本时取第 3 个）。
    /// 探针只做同一次运行内的相对比较，口径一致比绝对正确重要。
    static func percentile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    /// 当前线程累计消耗的 CPU 秒数（user + system）。
    ///
    /// `mach_thread_self()` 每次调用都 +1 一个 send right，必须还回去，
    /// 否则 3 秒 × 120Hz 的循环会漏掉几百个端口引用。
    static func threadCPUSeconds() -> Double {
        let port = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, port) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// 进程**物理内存足迹**（MB，`TASK_VM_INFO.phys_footprint`）。
    ///
    /// 与 `mach_task_basic_info.resident_size`（RSS）不是一回事：RSS 把已经归还
    /// 内核但还没被回收的页也算进去，所以「拆完窗口内存没降」经常是 RSS 的假象。
    /// 图层后备存储这类账要拿 footprint 当刹车。
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}

extension ProbeWindow {
    /// **uTerm 专有的坑**（uTable 没有）：`uTermApp` 是纯 SwiftUI `WindowGroup` 的
    /// app，最后一个窗口一消失整个宿主进程就 `exit(0)`。于是
    /// `isolateHostWindows` 把宿主窗口卸掉、探针再把自己的窗口拆掉的那一瞬，
    /// 测试宿主直接没了 —— xcresult 里只有一句
    /// 「The test runner exited with code 0 before finishing running tests」，
    /// 既没有断言消息也没有崩溃栈。
    ///
    /// 所以留一个 1×1 的锚窗口常驻屏外：它永远不卸，窗口数就永远不归零。
    /// 尺寸小、无内容、在屏幕之外，对读数没有可测量的影响。
    @MainActor
    static let terminationAnchor: NSWindow = {
        let window = Unconstrained(contentRect: NSRect(origin: offScreenOrigin,
                                                       size: NSSize(width: 1, height: 1)),
                                   styleMask: [.borderless],
                                   backing: .buffered,
                                   defer: false)
        window.setFrameOrigin(offScreenOrigin)
        window.orderFrontRegardless()
        return window
    }()

    /// 宿主自带的窗口里跑着真实应用逻辑（欢迎页 / 连接列表探活之类），不卸会污染读数
    /// （playbook §二 坑⑥）。
    @MainActor
    static func isolateHostWindows(keeping kept: [NSWindow]) {
        let anchor = terminationAnchor
        anchor.orderFrontRegardless()
        for window in NSApp.windows where window !== anchor && !kept.contains(window) {
            window.orderOut(nil)
        }
    }
}

extension NSView {
    /// 子树里**面积最大**的那个 `NSScrollView`。
    ///
    /// 取最大而不是第一个：SwiftUI 宿主里常有别的小滚动视图（表头、气泡），
    /// 按遍历顺序取会拿到错的那个，而「量到一个空视图」是这类探针最常见的假结论。
    func firstScrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }
}
