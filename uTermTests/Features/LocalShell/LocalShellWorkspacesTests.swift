import XCTest
@testable import uTerm

/// 最近工作区的记账。不起 shell，用私有 UserDefaults 套件。
@MainActor
final class LocalShellWorkspacesTests: XCTestCase {
    private let suite = "uTerm.tests.local-shell-workspaces-store"

    private func makeStore() throws -> LocalShellWorkspaces {
        LocalShellWorkspaces(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
    }

    override func setUp() async throws {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    func test_latest_directory_comes_first_without_duplicates() throws {
        let store = try makeStore()
        store.note("/a")
        store.note("/b")
        store.note("/a")
        XCTAssertEqual(store.recent, ["/a", "/b"])
    }

    func test_list_survives_a_relaunch() throws {
        try makeStore().note("/a")
        XCTAssertEqual(try makeStore().recent, ["/a"])
    }

    func test_home_and_relative_paths_are_not_recorded() throws {
        let store = try makeStore()
        store.note(LocalShellWorkspaces.home)
        store.note("relative/path")
        store.note("")
        XCTAssertEqual(store.recent, [])
    }

    func test_storage_is_capped_with_the_oldest_dropped() throws {
        let store = try makeStore()
        for index in 0..<100 { store.note("/dir\(index)") }
        XCTAssertEqual(store.recent.first, "/dir99")
        XCTAssertLessThan(store.recent.count, 100)
        XCTAssertFalse(store.recent.contains("/dir0"))
    }

    func test_entries_list_open_tabs_first_and_drop_home_duplicates_and_deleted() {
        let entries = LocalShellWorkspaces.entries(
            open: ["/open", "/home/me", "/shared"],
            recent: ["/recent", "/shared", "/deleted"],
            home: "/home/me",
            exists: { $0 != "/deleted" })
        XCTAssertEqual(entries, ["/open", "/shared", "/recent"])
    }

    func test_deleted_directories_make_room_up_to_the_limit() {
        let recent = (0..<20).map { "/dir\($0)" }
        let entries = LocalShellWorkspaces.entries(open: [], recent: recent, home: "/home/me",
                                                   exists: { $0 != "/dir0" })
        XCTAssertEqual(entries.count, LocalShellWorkspaces.listLimit)
        XCTAssertEqual(entries.first, "/dir1")
    }

    func test_real_directories_only_pass_the_existence_check() throws {
        let store = try makeStore()
        store.note("/usr/bin")
        store.note("/no/such/directory")
        store.note("/etc/hosts")   // 文件不是目录：开不了 shell。
        XCTAssertEqual(store.list(open: []), ["/usr/bin"])
    }
}
