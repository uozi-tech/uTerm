import AppKit
import SwiftData
import XCTest
@testable import uTerm

@MainActor
final class DockMenuControllerTests: XCTestCase {
    private let serverA = DockMenuController.Server(id: UUID(), title: "web-01 · prod")
    private let serverB = DockMenuController.Server(id: UUID(), title: "db-01")

    func testMenuListsNewLocalShellThenRecentServers() throws {
        let menu = try XCTUnwrap(makeController(servers: [serverA, serverB]).makeMenu())

        XCTAssertEqual(menu.items.map(\.title), ["新建本机终端", "", "最近连接", "web-01 · prod", "db-01"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertNil(menu.items[2].action, "「最近连接」只是小标题，不能点")
    }

    func testMenuOmitsRecentSectionWithoutServers() throws {
        let menu = try XCTUnwrap(makeController(servers: []).makeMenu())

        XCTAssertEqual(menu.items.map(\.title), ["新建本机终端"])
    }

    func testLockedAppExposesNoCustomItems() {
        XCTAssertNil(makeController(servers: [serverA], isLocked: true).makeMenu())
    }

    func testItemsRunTheirActions() throws {
        var newShellCount = 0
        var opened: [UUID] = []
        let controller = makeController(
            servers: [serverA, serverB],
            onNewLocalShell: { newShellCount += 1 },
            onOpenServer: { opened.append($0) })
        let menu = try XCTUnwrap(controller.makeMenu())

        menu.performActionForItem(at: 0)
        menu.performActionForItem(at: 4)

        XCTAssertEqual(newShellCount, 1)
        XCTAssertEqual(opened, [serverB.id])
    }

    func testRecentServersAreNewestFirstAndLimited() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        let context = ModelContext(container)
        let base = Date(timeIntervalSince1970: 1_000_000)
        for (name, host, group, offset) in [
            ("old", "h1", nil, 1.0),
            ("", "only-host", "prod", 3.0),
            ("new", "h3", nil, 4.0),
            ("mid", "h4", nil, 2.0),
        ] as [(String, String, String?, Double)] {
            let profile = ServerProfile()
            profile.name = name
            profile.host = host
            profile.group = group
            profile.lastConnectedAt = base.addingTimeInterval(offset)
            context.insert(profile)
        }
        let neverConnected = ServerProfile()
        neverConnected.name = "never"
        context.insert(neverConnected)
        try context.save()

        let servers = DockMenuController.recentServers(in: context, limit: 3)

        XCTAssertEqual(servers.map(\.title), ["new", "only-host · prod", "mid"])
    }

    /// 真正的 `NSApp.delegate` 是 SwiftUI 的包装对象：它不转发，系统就拿不到自定义项。
    func testSwiftUIAppDelegateForwardsDockMenu() throws {
        let appDelegate = try XCTUnwrap(NSApp.delegate as? NSObject)
        XCTAssertTrue(appDelegate.responds(to: #selector(NSApplicationDelegate.applicationDockMenu(_:))))
    }

    func testLifecycleDelegateReturnsControllerMenu() {
        let delegate = UTermLifecycleDelegate()
        XCTAssertNil(delegate.applicationDockMenu(NSApp), "开窗入口装好之前没有自定义项")

        delegate.dockMenu = makeController(servers: [])
        XCTAssertEqual(delegate.applicationDockMenu(NSApp)?.items.first?.title, "新建本机终端")
    }

    private func makeController(
        servers: [DockMenuController.Server],
        isLocked: Bool = false,
        onNewLocalShell: @escaping @MainActor () -> Void = {},
        onOpenServer: @escaping @MainActor (UUID) -> Void = { _ in }
    ) -> DockMenuController {
        DockMenuController(
            isLocked: { isLocked },
            recentServers: { servers },
            onNewLocalShell: onNewLocalShell,
            onOpenServer: onOpenServer)
    }
}
