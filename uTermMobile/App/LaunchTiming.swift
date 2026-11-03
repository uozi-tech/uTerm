import Darwin
import Foundation

/// 冷启动计时：把「进程起点 → App.init 结束 → 首屏出现」写进日志（category `launch`）。
///
/// 起点取内核记的进程创建时间（`kinfo_proc.p_starttime`），所以 dyld 加载与静态初始化也算在内，
/// 和用户点图标后盯着启动屏的那段时间对得上。日志与 `sync` 类的 CloudKit 事件同在一条流里，
/// 看先后就能判断 CloudKit setup / import 是否发生在首屏之前（它们在后台队列跑，本不该挡首屏）。
@MainActor
enum LaunchTiming {
    private static var didLogFirstScreen = false

    /// `MobileApp.init()` 末尾调用。
    static func initFinished() {
        log("App.init 完成")
    }

    /// 主界面第一次出现时调用；只记第一次。
    static func firstScreenAppeared() {
        guard !didLogFirstScreen else { return }
        didLogFirstScreen = true
        log("首屏出现")
    }

    private static func log(_ stage: String) {
        guard let start = processStartDate else { return }
        let ms = Int((Date().timeIntervalSince(start) * 1000).rounded())
        AppLogger.info("\(stage)：进程起点后 \(ms) ms", category: "launch")
    }

    /// 本进程的创建时间；读不到时为 nil（不记日志，避免写出无意义的数字）。
    private static let processStartDate: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }()
}
