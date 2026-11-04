import AppKit
import CoreGraphics
import Network
import ServiceManagement
import UserNotifications

extension PermissionGuideEnvironment {
    static let live = PermissionGuideEnvironment(
        notificationStatus: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .notDetermined: return .notAsked
            case .authorized, .provisional, .ephemeral: return .granted
            default: return .notGranted
            }
        },
        requestNotifications: {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        },
        screenCaptureGranted: { await Task.detached { CGPreflightScreenCaptureAccess() }.value },
        requestScreenCapture: { RemoteDesktopPermissions.requestScreenCapture() },
        postEventsGranted: { await Task.detached { CGPreflightPostEventAccess() }.value },
        requestPostEvents: { RemoteDesktopPermissions.requestPostEvents() },
        loginItemNeedsApproval: {
            let identifier = BackgroundServiceSettings.loginItemIdentifier
            return await Task.detached {
                SMAppService.loginItem(identifier: identifier).status == .requiresApproval
            }.value
        },
        observeLocalNetwork: { update in
            let probe = LocalNetworkPermissionProbe(update: update)
            return { probe.cancel() }
        },
        openSettings: { kind in
            switch kind {
            case .notifications:
                let bundleID = Bundle.main.bundleIdentifier ?? "com.uozi.uTerm"
                openSystemSettings("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
            case .localNetwork:
                openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
            case .screenCapture:
                RemoteDesktopPermissions.openScreenCaptureSettings()
            case .accessibility:
                RemoteDesktopPermissions.openAccessibilitySettings()
            case .loginItem:
                SMAppService.openSystemSettingsLoginItems()
            }
        },
        relaunch: { RemoteDesktopPermissions.relaunch() })

    private static func openSystemSettings(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 本地网络授权没有查询接口，只能真去用一次看结果：浏览 uTerm 自己的 Bonjour 服务，
/// 被拦时 `NWBrowser` 停在 `.waiting(kDNSServiceErr_PolicyDenied)`。
///
/// 浏览不会多弹一次框：局域网同步启动时已经在浏览同一个服务，系统要问早就问过了。
/// 用户在系统设置里打开后浏览器自己转回 `.ready`，所以这里能实时跟上，不用重启。
final class LocalNetworkPermissionProbe {
    /// `.ready` 之后这么久没被拦，才算放行。刚起步时 `.ready` 可能先于拒绝到达。
    private static let settleDelay: Duration = .milliseconds(1500)

    private let browser: NWBrowser
    private let update: @MainActor (PermissionStatus) -> Void
    private var settle: Task<Void, Never>?

    init(update: @escaping @MainActor (PermissionStatus) -> Void) {
        self.update = update
        browser = NWBrowser(for: .bonjour(type: LANSyncConstants.serviceType, domain: nil), using: .tcp)
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.handle(state) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, !results.isEmpty else { return }
                self.settle?.cancel()
                self.update(.granted)
            }
        }
        update(.checking)
        browser.start(queue: .main)
    }

    func cancel() {
        settle?.cancel()
        browser.cancel()
    }

    nonisolated static func isPolicyDenied(_ error: NWError) -> Bool {
        guard case .dns(let code) = error else { return false }
        return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
    }

    private func handle(_ state: NWBrowser.State) {
        switch state {
        case .waiting(let error), .failed(let error):
            settle?.cancel()
            update(Self.isPolicyDenied(error) ? .notGranted : .checking)
        case .ready:
            settle?.cancel()
            settle = Task { [weak self] in
                try? await Task.sleep(for: Self.settleDelay)
                guard !Task.isCancelled else { return }
                self?.update(.granted)
            }
        default:
            break
        }
    }
}
