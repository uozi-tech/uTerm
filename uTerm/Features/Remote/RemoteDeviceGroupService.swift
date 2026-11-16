import Foundation
import Observation

/// 设备组（「我的设备」）的 App 级单例：App 开着就在后台调 `RemoteDeviceGroup.refresh()`，不依赖你开着哪一页。
///
/// 这样别的设备想加入时，组里每台设备都会弹输码框（Mac 是 `RemoteDeviceGroupPrompt`，iOS 是
/// `RemoteGroupJoinSheet`）；新设备核对通过后的回执、补签、移除也在后台照常推进。全 App 只有这一个
/// `RemoteDeviceGroup`：两个实例会各自记一份「我在等谁的 Ta」，互相清掉对方回出去的记录。
///
/// 轮询间隔：有页面开着、本机在显示核对码、有别的设备想加入、本机在等别的设备的下一步（`isAwaitingOthers`）时
/// 2 秒，否则 10 秒（读一次名册是一次本地钥匙串查询）。Mac 一直跑；iOS 只在前台跑（`start` / `stop` 跟着前后台）。
@MainActor
@Observable
final class RemoteDeviceGroupService {
    static let activeInterval: Duration = .seconds(2)
    static let idleInterval: Duration = .seconds(10)

    /// 本机还没有远控身份（从没用过远程控制）时是 nil：后台不生成身份，等打开「我的设备」或身份出现。
    private(set) var model: RemoteDeviceGroup?
    /// 你在弹窗上点了「关闭」时那个请求的状态：状态没变就不再弹（比如「正在核对」），变了（输错了、要输新数）再弹。
    private(set) var hiddenRequests: [UUID: RemoteDeviceGroup.JoinRequest.Status] = [:]

    @ObservationIgnored private let makeModel: (_ createsIdentity: Bool) -> RemoteDeviceGroup?
    /// 本机配对过的 Mac。G1b 只是拿着：替组员开通（G2）要用。
    @ObservationIgnored private(set) weak var hosts: (any RemoteGroupHostAccess)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    /// 有几处界面要它勤快些（「我的设备」开着）。
    @ObservationIgnored private var demand = 0
    @ObservationIgnored private var sleepGeneration = 0

    init(makeModel: @escaping (_ createsIdentity: Bool) -> RemoteDeviceGroup? = { RemoteDeviceGroup.live(createsIdentity: $0) }) {
        self.makeModel = makeModel
    }

    /// 开始后台轮询。重复调用无害。
    func start(hosts: any RemoteGroupHostAccess) {
        self.hosts = hosts
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tick()
                await self.sleep(self.interval)
            }
        }
    }

    /// 停止后台轮询（iOS 退到后台）。
    func stop() {
        loop?.cancel()
        loop = nil
        wakeUp()
    }

    /// 「我的设备」打开时：还没有身份就生成一个（你要用了），马上读一次。
    @discardableResult
    func ensureModel() -> RemoteDeviceGroup? {
        if model == nil { model = makeModel(true) }
        refresh()
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

    /// 点了按钮（「加入」、输了码）之后：马上读一次，下一拍也提前。
    func poke() {
        refresh()
        wakeUp()
    }

    // MARK: - 弹窗

    /// 弹窗此刻该问的那个加入请求（组员一侧）：没有就关掉弹窗。
    var pendingRequest: RemoteDeviceGroup.JoinRequest? {
        Self.pending(in: model?.joinRequests ?? [], hidden: hiddenRequests)
    }

    /// 核对通过的（`.admitted`）不弹：弹窗在成功时自己关；你关掉过、状态也没变的不弹。其余按名单顺序取第一个。
    static func pending(in requests: [RemoteDeviceGroup.JoinRequest],
                        hidden: [UUID: RemoteDeviceGroup.JoinRequest.Status]) -> RemoteDeviceGroup.JoinRequest? {
        requests.first { $0.status != .admitted && hidden[$0.id] != $0.status }
    }

    /// 弹窗上的「关闭」：后台继续核对，状态变了再弹。
    func hidePrompt(_ request: RemoteDeviceGroup.JoinRequest) {
        hiddenRequests[request.id] = request.status
    }

    /// 弹窗上的「拒绝」：这一轮不再显示，本机等着的核对也作废。
    func reject(_ request: RemoteDeviceGroup.JoinRequest) {
        model?.dismissJoin(request.id)
        hiddenRequests[request.id] = nil
    }

    /// 弹窗上的「核对」。返回有没有发出去（格式不对、请求过期、次数用完时为 false）。
    @discardableResult
    func submit(_ code: String, for request: RemoteDeviceGroup.JoinRequest) -> Bool {
        guard let model else { return false }
        let sent = model.submitCode(code, for: request.id)
        wakeUp()
        return sent
    }

    // MARK: - 轮询

    var interval: Duration {
        Self.isBusy(demand: demand, model: model) ? Self.activeInterval : Self.idleInterval
    }

    static func isBusy(demand: Int, model: RemoteDeviceGroup?) -> Bool {
        guard let model else { return demand > 0 }
        if demand > 0 || model.isAwaitingOthers { return true }
        if case .showingCode = model.joinState { return true }
        return model.joinRequests.contains { $0.status != .admitted }
    }

    func tick() {
        if model == nil { model = makeModel(false) }
        refresh()
    }

    private func refresh() {
        guard let model else { return }
        model.refresh()
        // 核对通过的请求收起来：弹窗已经关了，名单里看得到它。不收的话它一直在列表里，轮询也一直是快的。
        for request in model.joinRequests where request.status == .admitted {
            model.dismissJoin(request.id)
        }
        // 关掉过的请求没了，就不用再记着。
        let live = Set(model.joinRequests.map(\.id))
        let kept = hiddenRequests.filter { live.contains($0.key) }
        if kept != hiddenRequests { hiddenRequests = kept }
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
