import AppKit
import Foundation
import Observation
import ServiceManagement
import SwiftUI
import SwiftData

/// Process-level settings for keeping the local control service available without a window.
/// These switches are deliberately independent from the IPC and mutation gates.
@MainActor
@Observable
final class BackgroundServiceSettings {
    static let loginItemIdentifier = "com.uozi.uTerm.BackgroundLauncher"
    private enum Keys {
        static let launchAtLogin = "background.launchAtLogin"
        static let allowOnDemandLaunch = "background.allowOnDemandLaunch"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            updateLoginItem()
        }
    }

    var allowOnDemandLaunch: Bool {
        didSet {
            guard allowOnDemandLaunch != oldValue else { return }
            defaults.set(allowOnDemandLaunch, forKey: Keys.allowOnDemandLaunch)
        }
    }

    var loginItemError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        allowOnDemandLaunch = defaults.object(forKey: Keys.allowOnDemandLaunch) as? Bool ?? false
    }

    private func updateLoginItem() {
        let service = SMAppService.loginItem(identifier: Self.loginItemIdentifier)
        do {
            if launchAtLogin {
                try service.register()
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
    }
}

enum BackgroundLaunchMode {
    enum Presentation: Equatable { case background, foreground }

    static func presentation(arguments: [String]) -> Presentation {
        arguments.contains("--background") ? .background : .foreground
    }

    static func shouldStartHidden(arguments: [String]) -> Bool {
        presentation(arguments: arguments) == .background
    }

    static let reopenPresentation: Presentation = .foreground
    static var isRunningInTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }

    static let requestedByCLI = shouldStartHidden(arguments: ProcessInfo.processInfo.arguments)
    static var shouldStartHidden: Bool { requestedByCLI }
}

@MainActor
enum LaunchForwardingBootstrap {
    static func start(
        modelContainer: ModelContainer,
        model: GlobalForwardingModel,
        coordinator: ForwardingCoordinator,
        relay: HostKeyChallengeRelay
    ) {
        let context = modelContainer.mainContext
        let launchRules = ForwardingRuleStore(context: context).allRules().filter(\.launchAtAppStart)
        let profiles = (try? context.fetch(FetchDescriptor<ServerProfile>(
            sortBy: [SortDescriptor(\.sortOrder, order: .forward)]))) ?? []
        let items: [GlobalForwardingModel.LaunchItem] = profiles.flatMap { profile in
            launchRules
                .filter { $0.serverID == profile.id }
                .map { GlobalForwardingModel.LaunchItem(rule: $0.snapshot, server: profile) }
        }
        model.autoTriggerIfNeeded(
            items: items,
            coordinator: coordinator,
            relay: relay,
            container: context.container
        )
    }
}

@MainActor
final class UTermLifecycleDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if BackgroundLaunchMode.shouldStartHidden {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BackgroundLaunchMode.shouldStartHidden else { return }
        NSApp.windows.forEach { $0.orderOut(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        precondition(BackgroundLaunchMode.reopenPresentation == .foreground)
        Self.showGUI()
        return true
    }

    static func showGUI() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        let windows = NSApp.windows.filter { !($0 is NSPanel) }
        if let window = windows.first {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .showWelcomeWindow, object: nil)
        }
    }

    static func moveToBackground() {
        NSApp.windows.forEach { $0.orderOut(nil) }
        NSApp.setActivationPolicy(.accessory)
    }

    static func quitCompletely() {
        NSApp.terminate(nil)
    }
}

extension Notification.Name {
    static let showWelcomeWindow = Notification.Name("uterm.showWelcomeWindow")
}

struct BackgroundLifecycleCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("转入后台") { UTermLifecycleDelegate.moveToBackground() }
            Divider()
            Button("完全退出 uTerm") { UTermLifecycleDelegate.quitCompletely() }
                .keyboardShortcut("q", modifiers: .command)
        }
    }
}
