import XCTest
@testable import uTermMobile

/// `MobileSFTPController` 的操作语义（假会话 `MobileFakeSFTPProvider`，不连真实服务器）：
/// 单次操作失败只给提示不翻失败页、目录递归删且一次只删一个、符号链接先解析再决定进不进。
@MainActor
final class MobileSFTPControllerTests: XCTestCase {
    private func dir(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o040755, size: 4096, modifiedAt: nil)
    }
    private func file(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o100644, size: 3, modifiedAt: nil)
    }
    private func link(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o120777, size: 4, modifiedAt: nil)
    }

    private func make(_ directories: [String: [RemoteEntry]],
                      latency: Duration = .zero) async -> (MobileSFTPController, MobileFakeSFTPProvider) {
        let provider = MobileFakeSFTPProvider(
            tree: MobileFakeSFTPTree(directories: directories, home: "/"), latency: latency)
        let controller = await MobileFakeSFTP.controller(provider: provider, path: "/")
        return (controller, provider)
    }

    private func wait(_ predicate: @MainActor () -> Bool) async -> Bool {
        await MobileFakeTerminal.waitUntil(timeout: .seconds(5), predicate)
    }

    // MARK: - a. 单次操作失败不翻失败页

    func testDeleteFailureKeepsBrowsingAndShowsTransientError() async throws {
        let (controller, provider) = await make(["/": [file("a.txt")]])
        await provider.inject(.removeFile, message: "权限不足")

        controller.delete(controller.entries[0])
        let reported = await wait { controller.transientError != nil }

        XCTAssertTrue(reported)
        XCTAssertEqual(controller.state, .connected, "单次删除失败不能把整个标签翻成「连接失败」")
        XCTAssertEqual(controller.transientError?.hasPrefix("删除失败"), true)
        XCTAssertEqual(controller.entries.map(\.name), ["a.txt"])
        controller.clearTransientError()
        XCTAssertNil(controller.transientError)
    }

    func testOpenDirectoryFailureKeepsCurrentListing() async throws {
        let (controller, provider) = await make(["/": [dir("locked"), file("a")], "/locked": []])
        await provider.inject(.list, at: "/locked", message: "Permission denied")

        await controller.load("/locked")

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.path, "/", "列不出的目录不进去，留在原目录")
        XCTAssertEqual(controller.entries.map(\.name), ["locked", "a"])
        XCTAssertFalse(controller.loading)
        XCTAssertEqual(controller.transientError?.hasPrefix("打开目录失败"), true)
    }

    func testRenameAndChmodFailuresAreTransient() async throws {
        let (controller, provider) = await make(["/": [file("a")]])
        await provider.inject(.rename)
        await provider.inject(.setPermissions)

        controller.rename(controller.entries[0], to: "b")
        let renameReported = await wait { controller.transientError != nil }
        XCTAssertTrue(renameReported)
        XCTAssertEqual(controller.transientError?.hasPrefix("重命名失败"), true)
        controller.clearTransientError()

        controller.chmod(controller.entries[0], mode: 0o600)
        let chmodReported = await wait { controller.transientError != nil }
        XCTAssertTrue(chmodReported)
        XCTAssertEqual(controller.transientError?.hasPrefix("权限设置失败"), true)
        XCTAssertEqual(controller.state, .connected)
    }

    /// 改名不变 / 只有空白：不发请求。
    func testRenameToSameOrBlankNameSendsNothing() async throws {
        let (controller, provider) = await make(["/": [file("a")]])
        await provider.resetCounts()
        controller.rename(controller.entries[0], to: "  a ")
        controller.rename(controller.entries[0], to: "   ")
        try? await Task.sleep(for: .milliseconds(100))
        let renames = await provider.callCount(.rename)
        XCTAssertEqual(renames, 0)
    }

    // MARK: - b. 目录递归删 + 一次只删一个

    func testDeleteDirectoryRemovesWholeTree() async throws {
        let (controller, provider) = await make([
            "/": [dir("d"), file("keep")],
            "/d": [file("x"), dir("sub")],
            "/d/sub": [file("y")],
        ])
        let target = try XCTUnwrap(controller.entries.first { $0.name == "d" })

        controller.delete(target)
        XCTAssertEqual(controller.deletion?.name, "d", "删目录要立刻有进度可显示")
        let done = await wait {
            controller.deletion == nil && controller.entries.map(\.name) == ["keep"]
        }

        XCTAssertTrue(done, "非空目录也要删干净（原先 rmdir 非空目录直接失败）")
        XCTAssertNil(controller.transientError)
        let gone = await provider.entrySnapshot(at: "/d")
        XCTAssertNil(gone)
        let fileRemovals = await provider.callCount(.removeFile)
        let dirRemovals = await provider.callCount(.removeDirectory)
        XCTAssertEqual(fileRemovals, 2)
        XCTAssertEqual(dirRemovals, 2)
    }

    func testOnlyOneDeletionAtATime() async throws {
        let (controller, provider) = await make([
            "/": [dir("d1"), dir("d2")],
            "/d1": [file("a"), file("b")],
            "/d2": [file("c")],
        ], latency: .milliseconds(30))
        let d1 = try XCTUnwrap(controller.entries.first { $0.name == "d1" })
        let d2 = try XCTUnwrap(controller.entries.first { $0.name == "d2" })

        controller.delete(d1)
        controller.delete(d2)
        XCTAssertEqual(controller.transientError?.contains("正在删除「d1」"), true,
                       "第二次删除要明确告诉用户在排队，而不是静默吞掉")

        let finished = await wait { controller.deletion == nil && controller.entries.count == 1 }
        XCTAssertTrue(finished)
        XCTAssertEqual(controller.entries.map(\.name), ["d2"])
        let d2Still = await provider.entrySnapshot(at: "/d2")
        XCTAssertNotNil(d2Still)
    }

    func testCancelDeletionBeforeFirstRoundTripDeletesNothing() async throws {
        let (controller, provider) = await make([
            "/": [dir("d")],
            "/d": [file("a"), file("b")],
        ])
        controller.delete(controller.entries[0])
        controller.cancelDeletion()
        XCTAssertEqual(controller.deletion?.isCancelling, true)

        let finished = await wait { controller.deletion == nil }
        XCTAssertTrue(finished)
        XCTAssertNil(controller.transientError, "取消不是错误")
        let children = await provider.listSnapshot("/d")
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(controller.entries.map(\.name), ["d"])
    }

    // MARK: - c. 符号链接先解析

    func testSymlinkToDirectoryEntersTarget() async throws {
        let (controller, _) = await make([
            "/": [link("logs")],
            "/logs": [file("a.log")],
        ])

        let isFile = await controller.openSymlink(controller.entries[0])

        XCTAssertFalse(isFile)
        XCTAssertEqual(controller.path, "/logs")
        XCTAssertEqual(controller.entries.map(\.name), ["a.log"])
        XCTAssertFalse(controller.loading)
    }

    func testSymlinkToFileIsHandledAsFile() async throws {
        let (controller, provider) = await make(["/": [link("conf"), file("z")]])
        // 指向文件的链接 opendir 会失败。
        await provider.inject(.list, at: "/conf", message: "Not a directory")
        let before = controller.entries

        let isFile = await controller.openSymlink(controller.entries[0])

        XCTAssertTrue(isFile, "指向文件的链接交给调用方按文件处理（弹操作单）")
        XCTAssertEqual(controller.path, "/")
        XCTAssertEqual(controller.entries, before)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertNil(controller.transientError)
        XCTAssertFalse(controller.loading)
    }

    /// 旧路径：`open` 把文件链接当目录列 → 列失败 → 整个标签「连接失败」。
    func testOpenOnFileSymlinkNoLongerFailsTheTab() async throws {
        let (controller, provider) = await make(["/": [link("conf")]])
        await provider.inject(.list, at: "/conf", message: "Not a directory")

        controller.open(controller.entries[0])
        let settled = await wait { !controller.loading }
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(settled)
        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.path, "/")
    }

    // MARK: - 排序（与 macOS 同一套规则，iOS 显示点文件）

    func testListingShowsDotfilesAndSortsNaturally() async throws {
        let (controller, _) = await make([
            "/": [file("f10"), file(".ssh"), file("f2"), dir("zdir")],
        ])
        XCTAssertEqual(controller.entries.map(\.name), ["zdir", ".ssh", "f2", "f10"])
    }
}
