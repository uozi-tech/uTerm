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
    /// 网络路径刚变，不等网络稳定就通知。断了能自己接回的连接（判错只是多重连一次）借此立刻处置；
    /// 其余的不用实现，仍然等稳定后的 `probeConnectionHealth`。
    /// `lostInterface`：变之前走的那块网卡没了（Wi-Fi 关了改走蜂窝），上面的连接不可能再通。
    func networkPathChanged(lostInterface: Bool)
}

extension ConnectionHealthProbing {
    func networkPathChanged(lostInterface: Bool) {}
}

/// 连接看门狗。
///
/// 长时间待机断网后，半死 TCP 不会自己报错：对端没机会发 FIN/RST，SwiftNIO
/// 看到的通道仍是 active —— 终端徽标停在「已连接」、输入字节静默进内核缓冲，
/// SFTP 操作要么挂死要么报 "I/O on closed channel" 且刷新无法恢复
/// （v1.2.3 及之前的实况）。唯一可靠的判活手段是主动发一笔需要对端应答的流量
/// （当时的 Citadel 没有 SSH 层 keepalive；USSHCore 有，但 App 的连接不开，靠这里）。
///
/// 本服务在三类时刻出手：
///   1. 系统从睡眠唤醒（`NSWorkspace.didWakeNotification`）；
///   2. 网络路径变动后的可用状态（`NWPathMonitor` satisfied 更新，含
///      unsatisfied → satisfied，以及 Wi-Fi / 热点 / VPN 这类 satisfied → satisfied
///      的网络环境切换）；
///   3. **周期心跳**（`probeInterval`，默认 30s）—— 因为机器一直醒着、网也没断时，
///      空闲连接仍可能被中间 NAT / 防火墙的空闲超时、或服务器端 `ClientAliveInterval`
///      静默掐断；只靠 1/2 的反应式探测盖不住这个场景。周期探测发的 `exec true`
///      流量同时充当 keepalive（重置对端 / NAT 空闲计时）与判死手段，等价于
///      `ssh -o ServerAliveInterval`。
/// 等网络 settle 几秒后（周期心跳无需 settle，直接扫），对注册表里所有存活对象并发
/// 探测；判死的连接由各自的 `probeConnectionHealth` 走既有恢复通道（终端：exitStream
/// → 「重新连接」覆盖层；SFTP：自动重连并保留当前目录；转发：拆隧道并亮「重试」）。
///
/// 注册表持弱引用：窗格关闭 / 窗口销毁后条目自动失效，无需显式注销。
@MainActor
final class ConnectionWatchdog {
    static let shared = ConnectionWatchdog()

    /// 触发探测前等网络 settle 的时长。唤醒后 Wi-Fi 重新关联需要数秒，
    /// 立即探测会把「网络还没回来」误判成「连接已死」。
    var settleDelay: Duration = .seconds(3)

    /// 周期心跳间隔（keepalive + 判死）。够短以在 NAT/服务端空闲超时前发流量保活、
    /// 并较快发现僵尸连接；够长以免 exec 探测开销可感。仅在 `observesSystemEvents`
    /// 为真时启动（测试关闭，由测试直接驱动 `sweep()`）。
    var probeInterval: Duration = .seconds(30)

    private struct WeakEntry {
        weak var value: (any ConnectionHealthProbing)?
    }

    private var entries: [ObjectIdentifier: WeakEntry] = [:]
    private var pathMonitor: NWPathMonitor?
    private var hasSeenPathUpdate = false
    /// 上一次网络可用时排在最前的网卡（新连接走它）。
    private var lastPrimaryInterface: String?
    private var pendingSweep: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?
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
        // 周期心跳在注册表空了之后会自己停（见 `startPeriodicProbing`），有新连接登记时再开。
        if observersInstalled { startPeriodicProbing() }
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
            let interfaces = path.availableInterfaces.map(\.name)
            Task { @MainActor in
                ConnectionWatchdog.shared.handlePathUpdate(satisfied: satisfied, interfaces: interfaces)
            }
        }
        monitor.start(queue: DispatchQueue(label: "uTerm.ConnectionWatchdog.path"))
        pathMonitor = monitor

        startPeriodicProbing()
    }

    /// 启动周期心跳：每 `probeInterval` 直接扫一遍（不走 settleDelay —— 那是给
    /// 唤醒/网络恢复留的网络收敛窗口，周期心跳无此需要）。`sweep()` 在无注册目标
    /// 时立即返回，故空闲（无连接）期的开销仅是一次定时唤醒。系统睡眠期间进程
    /// 冻结、`Task.sleep` 自然挂起，醒来由 didWake 处理、本循环继续计时。
    private func startPeriodicProbing() {
        guard periodicTask == nil else { return }
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.probeInterval else { return }
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.sweep()
                // 一条连接都没登记了（全关了）：停下这个 30 秒一拍的唤醒，别在没有任何 SSH 连接时空转；
                // 下次 `register` 时重新开始。有连接时的探测节拍（即保活）不变。
                if self.entries.isEmpty {
                    self.periodicTask = nil
                    return
                }
            }
        }
    }

    /// 网络路径更新时触发：除「断 → 通」外，Wi-Fi / 热点 / VPN 切换经常表现为
    /// satisfied → satisfied，既有 TCP 连接同样高度可疑。监视器启动时的首次回调
    /// 只记录状态，不扫描，避免应用带网启动立刻做一次无谓探测。
    ///
    /// `interfaces`：此刻可用的网卡名，按系统的优先顺序。扫描要等网络稳定；在那之前先把「网络变了」
    /// 告诉每个对象（`networkPathChanged`），能自己接回的连接不用等。
    func handlePathUpdate(satisfied: Bool, interfaces: [String] = []) {
        defer {
            hasSeenPathUpdate = true
        }
        guard satisfied else { return }
        let previous = lastPrimaryInterface
        lastPrimaryInterface = interfaces.first
        guard hasSeenPathUpdate else { return }
        let lostInterface = previous.map { !interfaces.contains($0) } ?? false
        for probe in entries.values.compactMap(\.value) {
            probe.networkPathChanged(lostInterface: lostInterface)
        }
        scheduleSweep()
    }
}
