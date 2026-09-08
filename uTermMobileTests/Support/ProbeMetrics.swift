import Darwin
import UIKit

// 三把尺（`percentile` / `threadCPUSeconds` / `footprintMB`）抄自 uTable 的
// `uTableTests/ProbeMetrics.swift`（uTable commit 65fb6eb），经 uTerm 的
// `uTermTests/Support/ProbeMetrics.swift`（uTerm commit 2791b0b5）转手，**一字未改**。
// 它们是纯 Darwin API（`thread_info` / `task_info`），与 AppKit / UIKit 无关，
// 所以 iOS 端不需要任何移植改动。
//
// 移动端这一份相对桌面那份的差异只有两处，都是平台名字的替换：
// 1. `import AppKit` → `import UIKit`；
// 2. `NSView.firstScrollView()` → `UIView.firstScrollView()`（`NSScrollView` →
//    `UIScrollView`，取子树里面积最大的那个，理由与桌面版相同）。
// 桌面版里那段 uTerm 专有的 `ProbeWindow.terminationAnchor` / `isolateHostWindows`
// **没有搬**：iOS 宿主是 `UIApplicationMain` 驱动的，窗口数归零不会让进程 `exit(0)`
// （见 `MobileProbeWindow` 顶部注释）。

/// 性能探针共用的三把尺。
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

extension UIView {
    /// 子树里**面积最大**的那个 `UIScrollView`。
    ///
    /// 取最大而不是第一个：SwiftUI 宿主里常有别的小滚动视图（横向 chip 条、
    /// 输入框内滚），按遍历顺序取会拿到错的那个，而「量到一个空视图」是这类探针
    /// 最常见的假结论。
    func firstScrollView() -> UIScrollView? {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { found.append(scroll) }
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return found.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// 子树里的 `UIView` 总数（含自己）。结构判据用，`LazyVStack` 是否真懒看它。
    func recursiveViewCount() -> Int {
        var n = 0
        func walk(_ view: UIView) { n += 1; for sub in view.subviews { walk(sub) } }
        walk(self)
        return n
    }

    /// 子树里出现最多的 5 个视图类，用来一眼看出「谁在长」。
    func classHistogram(top: Int = 5) -> String {
        var counts: [String: Int] = [:]
        func walk(_ view: UIView) {
            counts[String(describing: type(of: view)), default: 0] += 1
            for sub in view.subviews { walk(sub) }
        }
        walk(self)
        return counts.sorted { $0.value > $1.value }.prefix(top)
            .map { "\($0.key)×\($0.value)" }.joined(separator: "  ")
    }
}
