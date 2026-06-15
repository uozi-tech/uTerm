#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
import Network

/// 注册到 `ConnectionWatchdog` 的对象：在系统唤醒 / 网络恢复后被要求探测
/// 自己的连接，判死时自行触发恢复或状态翻转。实现必须幂等 —— 唤醒与网络
/// 恢复几乎总是先后到来，一次睡醒可能被探测两次。
///
/// `Sendable`：约束实现者为 `@MainActor` 类（全局 actor 隔离类型隐式
/// Sendable），使存在量可安全跨入 `sweep()` 的并发探测子任务。
@MainActor
protocol ConnectionHealthProbing: AnyObject, Sendable {
    func probeConnectionHealth() async
}

/// 连接看门狗。
///
/// 长时间待机断网后，半死 TCP 不会自己报错：对端没机会发 FIN/RST，SwiftNIO
/// 看到的通道仍是 active —— 终端徽标停在「已连接」、输入字节静默进内核缓冲，
/// SFTP 操作要么挂死要么报 "I/O on closed channel" 且刷新无法恢复
/// （v1.2.3 及之前的实况）。Citadel 0.12.1 没有 SSH 层 keepalive，
/// 唯一可靠的判活手段是主动发一笔需要对端应答的流量。
///
/// 本服务在两个「高度可疑」时刻出手：
///   1. 系统从睡眠唤醒（`NSWorkspace.didWakeNotification`）；
///   2. 网络路径从不可用恢复为可用（`NWPathMonitor` unsatisfied → satisfied）。
/// 等网络 settle 几秒后，对注册表里所有存活对象并发探测；判死的连接由各自的
/// `probeConnectionHealth` 走既有恢复通道（终端：exitStream → 「重新连接」
/// 覆盖层；SFTP：自动重连并保留当前目录）。
///
/// 注册表持弱引用：窗格关闭 / 窗口销毁后条目自动失效，无需显式注销。
@MainActor
final class ConnectionWatchdog {
    static let shared = ConnectionWatchdog()

    /// 触发探测前等网络 settle 的时长。唤醒后 Wi-Fi 重新关联需要数秒，
    /// 立即探测会把「网络还没回来」误判成「连接已死」。
    var settleDelay: Duration = .seconds(3)

    private struct WeakEntry {
        weak var value: (any ConnectionHealthProbing)?
    }

    private var entries: [ObjectIdentifier: WeakEntry] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lastPathSatisfied = true
    private var pendingSweep: Task<Void, Never>?
    private var observersInstalled = false
    private let observesSystemEvents: Bool

    /// - Parameter observingSystemEvents: 测试传 `false`，不挂系统通知 /
    ///   NWPathMonitor，探测由测试直接调 `sweep()` 驱动。
    init(observingSystemEvents: Bool = true) {
        self.observesSystemEvents = observingSystemEvents
    }

    /// 幂等注册（按对象身份去重）。首次注册时才安装系统观察者。
    func register(_ probe: any ConnectionHealthProbing) {
        entries[ObjectIdentifier(probe)] = WeakEntry(value: probe)
        installObserversIfNeeded()
    }

    /// 合并窗口内的重复触发（唤醒 + 网络恢复几乎总是同时来），settle 后扫一遍。
    func scheduleSweep() {
        guard pendingSweep == nil else { return }
        pendingSweep = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            self.pendingSweep = nil
            await self.sweep()
        }
    }

    /// 立即对所有注册对象并发探测（测试直接调用）。单个探测内部自带超时，
    /// 不会让整轮扫描挂死。
    func sweep() async {
        entries = entries.filter { $0.value.value != nil }
        let targets = entries.values.compactMap(\.value)
        guard !targets.isEmpty else { return }
        // 非结构化 Task 数组（而非 withTaskGroup）：探测对象是 MainActor 隔离的
        // Sendable 存在量，region 隔离检查器目前无法理解 for-in + addTask 的
        // 捕获模式（"please file a bug"）。语义不变：并发起跑、全部等完。
        let probes = targets.map { target in
            Task { @MainActor in
                await target.probeConnectionHealth()
            }
        }
        for probe in probes {
            await probe.value
        }
    }

    private func installObserversIfNeeded() {
        guard observesSystemEvents, !observersInstalled else { return }
        observersInstalled = true

        // 系统唤醒（macOS 睡眠 → 唤醒；iOS 后台 → 前台）后都视为「高度可疑」时刻。
        #if canImport(AppKit)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { @Sendable _ in
            Task { @MainActor in
                ConnectionWatchdog.shared.scheduleSweep()
            }
        }
        #elseif canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { @Sendable _ in
            Task { @MainActor in
                ConnectionWatchdog.shared.scheduleSweep()
            }
        }
        #endif

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { @Sendable path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in
                ConnectionWatchdog.shared.handlePathUpdate(satisfied: satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "uTerm.ConnectionWatchdog.path"))
        pathMonitor = monitor
    }

    /// 只在「断 → 通」的恢复沿触发：网络刚回来的瞬间正是既有 TCP 状态最可疑、
    /// 探测又能得到真实应答的时刻。监视器启动时会立刻回调一次当前状态 ——
    /// `lastPathSatisfied` 初始为 true，应用带网启动不会触发无谓扫描。
    private func handlePathUpdate(satisfied: Bool) {
        defer { lastPathSatisfied = satisfied }
        if satisfied && !lastPathSatisfied {
            scheduleSweep()
        }
    }
}
