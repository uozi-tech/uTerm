import Foundation
import Observation

/// 「我的设备」的 App 级单例：App 开着就在后台读名册（`RemoteSiblingDevices.refresh`），不依赖用户开着哪一页。
///
/// 这样新设备不用先打开「我的设备」也会写好承诺、回答别的设备发来的确认（由 App 弹窗请你核对，见
/// `RemoteSiblingPrompt` / `RemoteSiblingConfirmHandler`）、收下别的设备替它开通的 Mac；已有设备也会在后台补着
/// 替确认过的设备开通、替丢了的设备撤销。全 App 只有这一个 `RemoteSiblingDevices`：两个实例同时跑会互相清掉
/// 对方发出去的确认（每个实例启动时都清本机发出的 challenge）。
///
/// 轮询间隔：有页面开着、有确认在进行、有别的设备在确认本机、本机在等别的设备的下一步时 2 秒，否则 10 秒（读一次名册是一次本地钥匙串查询）。
/// Mac 一直跑；iOS 只在前台跑（`start` / `stop` 跟着前后台）。
@MainActor
@Observable
final class RemoteSiblingService {
    static let activeInterval: Duration = .seconds(2)
    static let idleInterval: Duration = .seconds(10)

    /// 本机还没有远控身份（从没用过远程控制）时是 nil：后台不生成身份，等打开「我的设备」或身份出现。
    private(set) var model: RemoteSiblingDevices?

    @ObservationIgnored private let makeModel: (_ createsIdentity: Bool) -> RemoteSiblingDevices?
    @ObservationIgnored private weak var hosts: (any RemoteSiblingHostAccess)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    /// 有几处界面要它勤快些（「我的设备」开着）。
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var sleepGeneration = 0

    init(makeModel: @escaping (_ createsIdentity: Bool) -> RemoteSiblingDevices? = { RemoteSiblingDevices.live(createsIdentity: $0) }) {
        self.makeModel = makeModel
    }

    /// 开始后台轮询。重复调用无害。
    func start(hosts: any RemoteSiblingHostAccess) {
        self.hosts = hosts
        model?.hosts = hosts
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                await self.sleep(self.interval)
            }
        }
    }

    /// 停止后台轮询（iOS 退到后台）。正在问 Mac 的那一次一并取消，回前台再补。
    func stop() {
        loop?.cancel()
        loop = nil
        wakeUp()
        model?.vouchTask?.cancel()
        model?.vouchTask = nil
    }

    /// 「我的设备」打开时：还没有身份就生成一个（用户要用了），马上读一次。
    @discardableResult
    func ensureModel() -> RemoteSiblingDevices? {
        if model == nil, let made = makeModel(true) {
            made.hosts = hosts
            model = made
        }
        model?.refresh()
        return model
    }

    /// 页面可见期间挂着它（`.task { await service.keepActive() }`）：轮询改成 2 秒一次，任务取消就恢复。
    func keepActive() async {
        demand += 1
        wakeUp()
        defer { demand -= 1 }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
    }

    /// 别的设备正在确认本机、本机还没表态的那一次（App 据此弹窗）。
    var pendingIncoming: RemoteSiblingDevices.Incoming? {
        Self.pending(in: model?.incoming ?? [])
    }

    nonisolated static func pending(in incoming: [RemoteSiblingDevices.Incoming]) -> RemoteSiblingDevices.Incoming? {
        // 点了「允许」或「拒绝」的会从列表里拿掉；剩下的第一个就是要问的。核对通过的优先：那台设备上的人正等着。
        incoming.first(where: \.verified) ?? incoming.first
    }

    var interval: Duration {
        let busy = demand > 0 || model?.confirmation != nil || !(model?.incoming.isEmpty ?? true)
            || model?.isAwaitingOthers == true
        return busy ? Self.activeInterval : Self.idleInterval
    }

    func tick() {
        if model == nil, let made = makeModel(false) {
            made.hosts = hosts
            model = made
        }
        model?.refresh()
    }

    /// 睡到下一拍，或被 `wakeUp` 提前叫醒（页面刚打开、刚点了按钮）。
    private func sleep(_ duration: Duration) async {
        sleepGeneration &+= 1
        let generation = sleepGeneration
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            wake = continuation
            Task { [weak self] in
                try? await Task.sleep(for: duration)
                // 只叫醒自己这一觉：提前醒过之后，这个计时器不能把下一觉也叫醒。
                guard let self, self.sleepGeneration == generation else { return }
                self.wakeUp()
            }
        }
    }

    private func wakeUp() {
        wake?.resume()
        wake = nil
    }
}
