import SwiftData
import XCTest
@testable import uTerm

/// 欢迎页和 Dock 菜单的「连接这台主机」共用的入口。
@MainActor
final class ServerWindowOpenerTests: XCTestCase {
    private var context: ModelContext!
    private var sftpWindows: [SFTPWindowID] = []
    private var workspaceWindows: [WorkspaceWindowID] = []

    override func setUpWithError() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, configurations: config)
        context = ModelContext(container)
        sftpWindows = []
        workspaceWindows = []
    }

    private func insertProfile(sftpOnly: Bool) -> ServerProfile {
        let profile = ServerProfile()
        profile.name = "web"
        profile.host = "h"
        profile.sftpOnly = sftpOnly
        context.insert(profile)
        return profile
    }

    private func connect(_ profile: ServerProfile) {
        ServerWindowOpener.connect(profile, context: context,
                                   openSFTP: { sftpWindows.append($0) },
                                   openWorkspace: { workspaceWindows.append($0) })
    }

    func testNormalHostOpensWorkspace() {
        let profile = insertProfile(sftpOnly: false)
        connect(profile)
        XCTAssertEqual(workspaceWindows.map(\.serverID), [profile.id])
        XCTAssertTrue(sftpWindows.isEmpty)
    }

    func testSFTPOnlyHostNeverOpensATerminalWindow() {
        let profile = insertProfile(sftpOnly: true)
        connect(profile)
        XCTAssertEqual(sftpWindows.map(\.serverID), [profile.id])
        XCTAssertTrue(workspaceWindows.isEmpty)
    }

    func testEachSFTPConnectionGetsItsOwnWindow() {
        let profile = insertProfile(sftpOnly: true)
        connect(profile)
        connect(profile)
        XCTAssertEqual(Set(sftpWindows.map(\.id)).count, 2)
    }

    /// Dock 的最近连接按它排序，两种主机都要记。
    func testConnectingUpdatesRecentServersForBothKinds() throws {
        let older = insertProfile(sftpOnly: false)
        let newer = insertProfile(sftpOnly: true)
        XCTAssertNil(older.lastConnectedAt)

        connect(older)
        let first = try XCTUnwrap(older.lastConnectedAt)
        connect(newer)
        XCTAssertNotNil(newer.lastConnectedAt)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(newer.lastConnectedAt), first)

        XCTAssertFalse(context.hasChanges, "要落盘，不能只改内存")
        XCTAssertEqual(Set(DockMenuController.recentServers(in: context).map(\.id)), [older.id, newer.id])
    }
}
