import Foundation
import Observation
import ServiceManagement

@MainActor
@Observable
final class BackgroundServiceSettings {
    enum LoginItemStatus: Equatable {
        case notRegistered, enabled, requiresApproval, notFound
    }

    protocol LoginItemServicing: AnyObject {
        var status: LoginItemStatus { get }
        func register() throws
        func unregister() throws
    }

    private final class SystemLoginItemService: LoginItemServicing {
        private let service = SMAppService.loginItem(identifier: BackgroundServiceSettings.loginItemIdentifier)
        var status: LoginItemStatus {
            switch service.status {
            case .notRegistered: .notRegistered
            case .enabled: .enabled
            case .requiresApproval: .requiresApproval
            case .notFound: .notFound
            @unknown default: .notFound
            }
        }
        func register() throws { try service.register() }
        func unregister() throws { try service.unregister() }
    }

    static let loginItemIdentifier = "com.uozi.uTerm.BackgroundLauncher"
    private enum Keys {
        static let launchAtLogin = "background.launchAtLogin"
        static let allowOnDemandLaunch = "background.allowOnDemandLaunch"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let loginItemService: any LoginItemServicing
    private(set) var launchAtLogin: Bool
    var allowOnDemandLaunch: Bool {
        didSet {
            guard allowOnDemandLaunch != oldValue else { return }
            defaults.set(allowOnDemandLaunch, forKey: Keys.allowOnDemandLaunch)
        }
    }
    var loginItemError: String?
    private(set) var loginItemStatus: LoginItemStatus = .notRegistered
    var needsLoginItemApproval: Bool { loginItemStatus == .requiresApproval }

    init(defaults: UserDefaults = .standard, loginItemService: (any LoginItemServicing)? = nil) {
        self.defaults = defaults
        self.loginItemService = loginItemService ?? SystemLoginItemService()
        launchAtLogin = false
        allowOnDemandLaunch = defaults.object(forKey: Keys.allowOnDemandLaunch) as? Bool ?? false
        refreshLoginItemStatus()
    }

    func setLaunchAtLogin(_ requested: Bool) {
        guard requested != launchAtLogin else {
            refreshLoginItemStatus()
            return
        }
        loginItemError = nil
        do {
            if requested {
                try loginItemService.register()
            } else if loginItemService.status != .notRegistered {
                try loginItemService.unregister()
            }
        } catch {
            loginItemError = requested
                ? "无法启用登录后台启动：\(error.localizedDescription)"
                : "无法关闭登录后台启动：\(error.localizedDescription)"
        }
        refreshLoginItemStatus(preserveError: true)
    }

    func refreshLoginItemStatus(preserveError: Bool = false) {
        loginItemStatus = loginItemService.status
        launchAtLogin = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        if !preserveError { loginItemError = nil }
    }
}
