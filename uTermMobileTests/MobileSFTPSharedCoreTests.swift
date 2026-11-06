import XCTest
@testable import uTermMobile

/// iOS 文件标签改用两端共享的 `FileBrowserModel` 之后的接线：属性名照旧可用、平台参数
/// （固定排序、不补属主名）生效、关标签后在途结果不落地。
@MainActor
final class MobileSFTPSharedCoreTests: XCTestCase {
    private func dir(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o040755, size: 4096, modifiedAt: nil)
    }
    private func file(_ name: String) -> RemoteEntry {
        RemoteEntry(name: name, posixPermissions: 0o100644, size: 3, modifiedAt: nil)
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

    func testControllerForwardsSharedBrowserState() async throws {
        let (controller, _) = await make(["/": [dir("d"), file("a")], "/d": [file("x")]])

        XCTAssertEqual(controller.state, .connected)
        XCTAssertEqual(controller.browser.state, .browsing)
        XCTAssertEqual(controller.entries, controller.browser.sortedEntries)

        await controller.load("/d")
        XCTAssertEqual(controller.path, "/d")
        XCTAssertEqual(controller.browser.currentPath, "/d")
        XCTAssertEqual(controller.entries.map(\.name), ["x"])
    }

    /// iOS 不显示属主，就不该为补属主名开 exec 通道。
    func testListingDoesNotRunOwnerLookup() async throws {
        let (controller, provider) = await make(["/": [file("a")], "/d": [file("b")]])
        await provider.resetCounts()
        await controller.load("/d")
        let execs = await provider.callCount(.exec)
        XCTAssertEqual(execs, 0)
    }

    /// 关标签之后，在途的目录加载结果不再落地，标签也不再算开着。
    func testCloseDropsInFlightLoad() async throws {
        let (controller, _) = await make(["/": [dir("d")], "/d": [file("x")]],
                                         latency: .milliseconds(80))
        let load = Task { await controller.load("/d") }
        _ = await wait { controller.loading }
        controller.close()
        await load.value

        XCTAssertEqual(controller.path, "/")
        XCTAssertEqual(controller.entries.map(\.name), ["d"])
        XCTAssertFalse(controller.isOpen)
    }

    /// 连点「上一级」：第二次点按的是还没变的当前目录，只上一级，不越级。
    func testDoubleGoUpMovesOneLevel() async throws {
        let (controller, _) = await make([
            "/": [dir("a")], "/a": [dir("b")], "/a/b": [file("x")],
        ], latency: .milliseconds(30))
        await controller.load("/a/b")

        controller.goUp()
        controller.goUp()
        let settled = await wait { !controller.loading && controller.path != "/a/b" }

        XCTAssertTrue(settled)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.path, "/a")
    }
}
