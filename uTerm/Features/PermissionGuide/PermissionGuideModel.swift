import Foundation
import Observation

/// 授权引导窗口的标识，以及「启动时自动弹一次」的判定。
nonisolated enum PermissionGuideWindow {
    static let id = "permission-guide"
    /// 引导内容的版本。以后加了新的授权项就 +1，升级上来的用户会再看到一次。
    static let revision = 1
    static let presentedRevisionKey = "permissionGuide.presentedRevision"

    /// 后台启动（CLI 按需唤起、登录项）不弹：那时用户不在看屏幕，等下次正常打开再说。
    static func shouldPresentAtLaunch(presentedRevision: Int, startsHidden: Bool, isTestHost: Bool) -> Bool {
        !startsHidden && !isTestHost && presentedRevision < revision
    }
}

enum PermissionKind: CaseIterable, Identifiable {
    case notifications, localNetwork, screenCapture, accessibility, loginItem

    var id: Self { self }

    /// 屏幕录制和辅助功能的授权缓存在进程里，系统设置里打开后要重启 uTerm 才生效（见 `RemoteDesktopPermissions`）。
    var takesEffectAfterRelaunch: Bool {
        self == .screenCapture || self == .accessibility
    }
}

enum PermissionStatus: Equatable {
    case checking
    /// 还没问过。只有通知分得清这一态，其余几项系统不告诉我们。
    case notAsked
    case granted
    /// 拒绝过，或系统还在等用户去设置里打开。
    case notGranted
    /// 这次运行里请求过、还没生效：系统设置里打开后要重启 uTerm。
    case needsRelaunch
}

/// 引导窗口依赖的系统能力。生产用 `live`，测试换成假的。
///
/// 几项查询都是 async：屏幕录制 / 辅助功能的 preflight 各要同步等 tccd 15–40 ms，
/// `live` 把它们放到后台线程并行跑，窗口打开和切回前台时主线程不卡。
struct PermissionGuideEnvironment {
    var notificationStatus: @MainActor () async -> PermissionStatus
    var requestNotifications: @MainActor () async -> Void
    var screenCaptureGranted: @MainActor () async -> Bool
    var requestScreenCapture: @MainActor () -> Void
    var postEventsGranted: @MainActor () async -> Bool
    var requestPostEvents: @MainActor () -> Void
    var loginItemNeedsApproval: @MainActor () async -> Bool
    /// 开始观察本地网络授权，返回停止观察的闭包。
    var observeLocalNetwork: @MainActor (_ update: @escaping @MainActor (PermissionStatus) -> Void) -> @MainActor () -> Void
    var openSettings: @MainActor (PermissionKind) -> Void
    var relaunch: @MainActor () -> Void
}

@MainActor
@Observable
final class PermissionGuideModel {
    private(set) var statuses: [PermissionKind: PermissionStatus] = [:]
    private(set) var requestedThisRun: Set<PermissionKind> = []

    @ObservationIgnored private let environment: PermissionGuideEnvironment
    @ObservationIgnored private var stopObservingLocalNetwork: (@MainActor () -> Void)?
    /// 切回前台和点按钮都会触发刷新，可能叠在一起；只认最后一次发起的结果。
    @ObservationIgnored private var refreshGeneration = 0

    init(environment: PermissionGuideEnvironment) {
        self.environment = environment
    }

    /// 登录项只在用户开了「登录时启动」、系统还没批准时才出现；其余几项一直列着。
    var visibleKinds: [PermissionKind] {
        PermissionKind.allCases.filter { $0 != .loginItem || status(of: .loginItem) != .granted }
    }

    var grantedCount: Int {
        visibleKinds.count { status(of: $0) == .granted }
    }

    var needsRelaunch: Bool {
        visibleKinds.contains { status(of: $0) == .needsRelaunch }
    }

    func status(of kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .checking
    }

    func start() {
        if stopObservingLocalNetwork == nil {
            stopObservingLocalNetwork = environment.observeLocalNetwork { [weak self] status in
                self?.set(.localNetwork, status)
            }
        }
        Task { await refresh() }
    }

    func stop() {
        stopObservingLocalNetwork?()
        stopObservingLocalNetwork = nil
    }

    /// 本地网络由观察者实时推送，这里不碰。
    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        async let screenCapture = environment.screenCaptureGranted()
        async let postEvents = environment.postEventsGranted()
        async let loginItemNeedsApproval = environment.loginItemNeedsApproval()
        async let notifications = environment.notificationStatus()
        let results = await (screenCapture, postEvents, loginItemNeedsApproval, notifications)
        guard generation == refreshGeneration else { return }
        set(.screenCapture, relaunchAware(.screenCapture, granted: results.0))
        set(.accessibility, relaunchAware(.accessibility, granted: results.1))
        set(.loginItem, results.2 ? .notGranted : .granted)
        set(.notifications, results.3)
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .notifications:
            await environment.requestNotifications()
        case .screenCapture:
            requestedThisRun.insert(kind)
            environment.requestScreenCapture()
        case .accessibility:
            requestedThisRun.insert(kind)
            environment.requestPostEvents()
        case .localNetwork, .loginItem:
            environment.openSettings(kind)
        }
        await refresh()
    }

    func openSettings(_ kind: PermissionKind) {
        environment.openSettings(kind)
    }

    func relaunch() {
        environment.relaunch()
    }

    /// 值没变就不写：`@Observable` 对同值赋值也会通知，整个窗口会白白重算一遍。
    private func set(_ kind: PermissionKind, _ status: PermissionStatus) {
        guard statuses[kind] != status else { return }
        statuses[kind] = status
    }

    private func relaunchAware(_ kind: PermissionKind, granted: Bool) -> PermissionStatus {
        if granted { return .granted }
        return requestedThisRun.contains(kind) ? .needsRelaunch : .notGranted
    }
}
