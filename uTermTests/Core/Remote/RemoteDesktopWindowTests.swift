import CoreGraphics
import CoreVideo
import XCTest
@preconcurrency import Network
@testable import uTerm

/// 远程桌面「只看一个窗口」：窗口列表、按窗口开流、画面范围变了之后的几何更新。
///
/// 采集换成合成画面（测试进程没有屏幕录制授权），其余是生产代码：真服务端、真连接、真客户端与会话。
@MainActor
final class RemoteDesktopWindowTests: XCTestCase {
    // MARK: - 端到端

    func test_lists_windows_then_streams_one_and_follows_its_geometry() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "uTerm — RemoteProtocol.swift", bounds: CGRect(x: 200, y: 100, width: 951, height: 639)),
                       (id: 43, app: "Google Chrome", title: "", bounds: CGRect(x: 0, y: 30, width: 1200, height: 800))]
        XCTAssertTrue(client.supportsDesktopWindows, "新版 Mac 握手时报 desktop-windows 能力")

        // 1. 列表原样到达，顺序不变。
        let list = try await client.desktopWindows()
        XCTAssertNil(list.message)
        XCTAssertEqual(list.windows.map(\.id), [42, 43])
        XCTAssertEqual(list.windows[0].menuTitle, "uTerm — RemoteProtocol.swift")
        XCTAssertEqual(list.windows[0].menuDetail, "Xcode · 951×639")
        XCTAssertEqual(list.windows[1].menuTitle, "Google Chrome", "没标题的窗口用 App 名")
        XCTAssertEqual(list.windows[1].menuDetail, "1200×800")

        // 2. 先看整块显示器，再换成只看 42 号窗口：重开流，Mac 先把它提到最前，采集目标是那个窗口。
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        XCTAssertNil(session.info?.windowID)
        XCTAssertEqual(mac.openedWindows, [nil])
        XCTAssertEqual(mac.latestSource?.observesGeometry, false, "整块显示器的流不订几何")

        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        let info = try XCTUnwrap(session.info)
        XCTAssertEqual(info.windowID, 42)
        XCTAssertEqual(info.windowTitle, "uTerm — RemoteProtocol.swift")
        XCTAssertEqual(info.displayWidth, 951, "归一化坐标与画面比例按窗口的点尺寸算")
        XCTAssertEqual(info.displayHeight, 639)
        // 窗口 1902×1278 像素，比手机要的框小：不放大，原样。
        XCTAssertEqual(info.streamWidth, 1902)
        XCTAssertEqual(info.streamHeight, 1278)
        // 默认要「独立键鼠」：输入直接投给窗口所在的进程，开流前不把 App 变成当前 App。
        XCTAssertEqual(mac.surfacedWindows, [42])
        XCTAssertTrue(mac.raisedWindows.isEmpty)
        XCTAssertEqual(mac.independentInputs, [false, true], "整块显示器不要，窗口要")
        XCTAssertEqual(mac.openedWindows, [nil, 42])
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1))
        let source = try XCTUnwrap(mac.latestSource)
        XCTAssertTrue(source.observesGeometry)

        // 3. 光挪位置：注入与光标回报按新位置算，主控端不用知道（尺寸和占比都没变）。
        source.report(.whole(CGRect(x: 500, y: 300, width: 951, height: 639)))
        let moved = await waitUntil { mac.injector.allBounds.last == CGRect(x: 500, y: 300, width: 951, height: 639) }
        XCTAssertTrue(moved, "窗口挪了，注入的范围要跟着走")
        XCTAssertEqual(session.info?.displayWidth, 951)

        // 4. 窗口变大（或菜单伸出窗口）：系统把新范围缩进同一帧，下边空出一截。主控端收到新的点尺寸与占比。
        let grown = RemoteDesktopFrameGeometry(bounds: CGRect(x: 500, y: 300, width: 1200, height: 700),
                                               contentFraction: CGSize(width: 1, height: 0.868))
        source.report(grown)
        let updated = await waitUntil { session.info?.displayWidth == 1200 }
        XCTAssertTrue(updated, "几何更新没到主控端")
        XCTAssertEqual(session.info?.displayHeight, 700)
        XCTAssertEqual(session.contentFraction.width, 1, accuracy: 0.0001)
        XCTAssertEqual(session.contentFraction.height, 0.868, accuracy: 0.0001)
        XCTAssertEqual(mac.injector.allBounds.last, grown.bounds)

        // 5. 再重开一条流（换回整块显示器）：占比回到 1，不带着上一条流的裁切。
        await session.switchWindow(to: nil)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertNil(session.info?.windowID)
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1))
        XCTAssertEqual(session.info?.displayWidth, 1512)
        XCTAssertEqual(mac.openedWindows, [nil, 42, nil])
    }

    func test_fits_window_to_viewer_canvas_and_restores_it_afterwards() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original),
                       (id: 43, app: "Google Chrome", title: "B", bounds: CGRect(x: 0, y: 30, width: 1200, height: 800))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }

        // 1. 按手机画布（Duo 内屏横握，扣掉顶栏）开：Mac 先把窗口调成这么大，流按调好的尺寸来。
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.fittedWindows.map(\.id), [42])
        XCTAssertEqual(mac.fittedWindows.last?.size, CGSize(width: 951, height: 619))
        XCTAssertEqual(session.info?.displayWidth, 951)
        XCTAssertEqual(session.info?.displayHeight, 619)
        XCTAssertEqual(session.info?.streamWidth, 1902, "窗口 2 倍像素没超过手机要的框：原样，不缩")
        XCTAssertTrue(mac.restoredWindows.isEmpty)

        // 2. 转屏：画布变了，按新的再调一次；中间窗口先回到原位，最初的位置没丢。
        await session.refitWindow(to: CGSize(width: 669, height: 901))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.fittedWindows.last?.size, CGSize(width: 669, height: 901))
        XCTAssertEqual(session.info?.displayWidth, 669)
        XCTAssertEqual(session.info?.displayHeight, 901)
        // 差不到 8 点不重调（键盘条收放之类的抖动）。
        let fitsBefore = mac.fittedWindows.count
        await session.refitWindow(to: CGSize(width: 672, height: 905))
        XCTAssertEqual(mac.fittedWindows.count, fitsBefore)

        // 3. 换去看另一个窗口：先前那个放回最初的位置和大小。
        await session.switchWindow(to: 43)
        XCTAssertEqual(session.state, .streaming)
        let restored = await waitUntil { mac.windows.first { $0.id == 42 }?.bounds == original }
        XCTAssertTrue(restored, "换窗口后先前调过大小的窗口应还原：\(mac.restoredWindows)")
        XCTAssertEqual(mac.fittedWindows.count, fitsBefore, "没带 fit 的不调大小")

        // 4. 要的比 App 的最小窗口还小：得到的是最小尺寸，流照开。
        await session.switchWindow(to: 43, fit: CGSize(width: 300, height: 200))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.info?.displayWidth, 400)
        XCTAssertEqual(session.info?.displayHeight, 350)

        // 5. 关掉屏幕：窗口放回去。
        session.stop()
        let back = await waitUntil { mac.windows.first { $0.id == 43 }?.bounds == CGRect(x: 0, y: 30, width: 1200, height: 800) }
        XCTAssertTrue(back, "停流后窗口应还原：\(mac.restoredWindows)")
    }

    func test_refit_never_races_with_restore() async throws {
        // 2026-11-17 真机：转屏时主控端「停流 → 按新尺寸再开」，Mac 停流时的还原是异步的，和新的调大小互相抢，
        // 还原落在后面窗口就回到了原来的大尺寸。重调同一个窗口时不该有还原。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original)]
        mac.restoreDelay = .milliseconds(300)
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 669, height: 897))
        XCTAssertEqual(session.state, .streaming)
        // 连着转两次屏。
        await session.refitWindow(to: CGSize(width: 951, height: 669))
        await session.refitWindow(to: CGSize(width: 678, height: 466))
        XCTAssertEqual(session.state, .streaming)
        // 等过还原的宽限期和它的耗时：窗口仍是最后要的大小，中间一次还原都没发生。
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(mac.windows[0].bounds.size, CGSize(width: 678, height: 466), "窗口被还原抢了回去：\(mac.restoredWindows)")
        XCTAssertTrue(mac.restoredWindows.isEmpty, "重调同一个窗口时不该还原：\(mac.restoredWindows)")
        XCTAssertEqual(session.info?.displayWidth, 678)
        // 真的不看了：放回最初的位置和大小。
        session.stop()
        let back = await waitUntil { mac.windows[0].bounds == original }
        XCTAssertTrue(back, "停流后窗口应还原到最初的大小：\(mac.windows[0].bounds)")
    }

    // MARK: - 原地换尺寸

    func test_refit_resizes_the_window_in_place_without_reopening_the_stream() async throws {
        // 转屏、键盘弹出收起：新的 Mac 不停流，改窗口大小、流原地换成新尺寸，新的点尺寸和像素数随几何更新到主控端。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original)]
        let session = RemoteDesktopSession(client: client, maxWidth: 2852, maxHeight: 2006)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 1426, height: 1003))
        let showing = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame }
        XCTAssertTrue(showing)
        XCTAssertEqual(session.info?.streamWidth, 2852)
        XCTAssertEqual(mac.openedWindows.count, 1)

        var left = false
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if session.state != .streaming { left = true }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        // 弹出键盘：画布变矮。
        await session.refitWindow(to: CGSize(width: 1426, height: 535))
        let resized = await waitUntil { session.info?.displayHeight == 535 && session.info?.streamHeight == 1070 }
        watcher.cancel()
        XCTAssertTrue(resized, "新的点尺寸和像素数应随几何更新到：\(String(describing: session.info))")
        XCTAssertEqual(session.info?.displayWidth, 1426)
        XCTAssertEqual(session.info?.streamWidth, 2852)
        XCTAssertEqual(mac.windows[0].bounds.size, CGSize(width: 1426, height: 535))
        XCTAssertEqual(mac.openedWindows.count, 1, "没有重开采集")
        XCTAssertFalse(left, "全程都在放，没有停流")
        XCTAssertEqual(session.windowFit, CGSize(width: 1426, height: 535))
        // 换完之后画面接着来。
        let before = session.stats.totalFrames
        let more = await waitUntil(6) { session.stats.totalFrames > before }
        XCTAssertTrue(more, "换完尺寸后应继续收到画面")
        XCTAssertEqual(session.stats.decodeFailures, 0, "换尺寸的那一帧（新尺寸的关键帧）要解得开")
        // 不看了：窗口回到最初的位置和大小。
        session.stop()
        let back = await waitUntil { mac.windows[0].bounds == original }
        XCTAssertTrue(back, "停流后窗口应还原到最初的大小：\(mac.windows[0].bounds)")
    }

    func test_refit_sends_nothing_transitional_while_the_window_is_resizing() async throws {
        // 改窗口大小到采集换成新尺寸之间有过渡状态：采集还是旧的那套，系统把新窗口缩在旧画面的一角、报来新的范围。
        // 这些一张都不该到主控端——它停在上一张画面上，等新尺寸的第一帧到了一次换完（2026-11-18 user：换尺寸时闪）。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        // 画面取小一点：测试里现场生成一张大画面要几百毫秒，会把「改窗口期间」这段时间吃掉。
        mac.minimumWindowSize = CGSize(width: 100, height: 100)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 200, y: 100, width: 400, height: 300))]
        let session = RemoteDesktopSession(client: client, maxWidth: 800, maxHeight: 600)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 400, height: 300))
        let showing = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame }
        XCTAssertTrue(showing)
        XCTAssertEqual(session.info?.streamHeight, 600)
        let source = try XCTUnwrap(mac.latestSource)

        mac.fitDelay = .milliseconds(1500)
        let asked = ContinuousClock.now
        await session.refitWindow(to: CGSize(width: 400, height: 160))
        // 等 Mac 收到请求、开始改窗口。
        try await Task.sleep(for: .milliseconds(200))
        let framesBefore = session.stats.totalFrames
        // 过渡状态：采集出的还是旧尺寸的帧，内容只占画面的一角。
        for _ in 0..<3 {
            source.emit()
            source.report(RemoteDesktopFrameGeometry(bounds: CGRect(x: 200, y: 100, width: 400, height: 160),
                                                     contentFraction: CGSize(width: 1, height: 0.5)))
            try await Task.sleep(for: .milliseconds(60))
        }
        try XCTSkipIf(ContinuousClock.now - asked > .milliseconds(1300), "机器太忙：没赶在窗口改完之前断言")
        XCTAssertTrue(mac.fittedWindows.count == 1, "窗口还在改：\(mac.fittedWindows)")
        XCTAssertEqual(session.stats.totalFrames, framesBefore, "改窗口大小期间的过渡画面不该发出来")
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1), "过渡状态的几何不该发出来")
        XCTAssertEqual(session.info?.displayHeight, 300, "主控端还停在旧的排版上")
        XCTAssertEqual(session.info?.streamHeight, 600)

        // 改完：新的几何和新尺寸的画面一起到。
        let resized = await waitUntil(6) { session.info?.streamHeight == 320 && session.stats.totalFrames > framesBefore }
        XCTAssertTrue(resized, "\(String(describing: session.info))")
        XCTAssertEqual(session.info?.displayHeight, 160)
        XCTAssertEqual(session.contentFraction, CGSize(width: 1, height: 1))
        XCTAssertEqual(source.retargetedSizes.map(\.height), [320])
        XCTAssertEqual(session.stats.decodeFailures, 0)
    }

    func test_new_layout_waits_for_the_first_frame_of_the_new_shape() async throws {
        // 主控端：视频帧的形状要变了而新形状的画面还没显示出来时，先不换排版——现在就换，画布会拿新的比例去摆旧的
        // 画面，拉变形一下才换成新的。等送显示的那一层报「这一帧是新形状的」再一起换。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 200, y: 100, width: 1512, height: 874))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2852, maxHeight: 2006)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 1426, height: 1003))
        let showing = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame }
        XCTAssertTrue(showing)
        // 画布上显示着 2852×2006 的画面。
        session.frameShown(width: 2852, height: 2006)

        await session.refitWindow(to: CGSize(width: 1426, height: 535))
        let refitted = await waitUntil { mac.latestSource?.retargetedSizes.isEmpty == false }
        XCTAssertTrue(refitted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.info?.streamHeight, 2006, "新形状的画面还没显示：排版先不动")
        XCTAssertEqual(session.info?.displayHeight, 1003)
        // Mac 降了编码分辨率、形状没变的帧：不算。
        session.frameShown(width: 1426, height: 1003)
        XCTAssertEqual(session.info?.streamHeight, 2006)
        // 新形状的第一帧要显示了：排版跟着换。
        session.frameShown(width: 2852, height: 1070)
        XCTAssertEqual(session.info?.streamHeight, 1070)
        XCTAssertEqual(session.info?.displayHeight, 535)
        XCTAssertEqual(session.info?.displayWidth, 1426)
    }

    func test_new_layout_is_applied_anyway_if_the_new_frame_never_shows() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 200, y: 100, width: 1512, height: 874))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2852, maxHeight: 2006)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 1426, height: 1003))
        let showing = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame }
        XCTAssertTrue(showing)
        session.frameShown(width: 2852, height: 2006)
        await session.refitWindow(to: CGSize(width: 1426, height: 535))
        let applied = await waitUntil(4) { session.info?.streamHeight == 1070 }
        XCTAssertTrue(applied, "新形状的画面一直没报上来：到点照几何换，排版不能一直停在旧的上")
    }

    func test_same_shape_tolerates_rounding_but_not_a_real_change() {
        XCTAssertTrue(RemoteDesktopSession.sameShape((2852, 2006), (1426, 1003)))
        XCTAssertTrue(RemoteDesktopSession.sameShape((2852, 2006), (1900, 1336)), "等比缩小后取偶数")
        XCTAssertFalse(RemoteDesktopSession.sameShape((2852, 2006), (2852, 1070)), "键盘弹出：矮了一半")
        XCTAssertFalse(RemoteDesktopSession.sameShape((2852, 2006), (2006, 2852)), "转屏")
    }

    // MARK: - 换大小时不盖遮罩

    func test_refitting_the_same_window_keeps_the_picture_uncovered() async throws {
        // 转屏、键盘弹出收起时按新尺寸重开流只要几百毫秒：这期间不盖「正在连接」，画布上留着上一张画面。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 1200, height: 800))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        // 第一次打开：照常盖「正在连接」。
        let first = Task { await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 669)) }
        let coveredWhileOpening = await waitUntil(2) { session.notice(macName: "Mac", showsClose: true) != nil }
        XCTAssertTrue(coveredWhileOpening, "第一次打开时要有「正在连接」")
        await first.value
        let showing = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame }
        XCTAssertTrue(showing)
        XCTAssertNil(session.notice(macName: "Mac", showsClose: true))
        // 换大小（老 Mac 的做法：停流、按新尺寸再开同一个窗口；新 Mac 原地换，见上面那条）：从发起到新画面出来，一直不盖。
        var covered = false
        let refit = Task { await session.switchWindow(to: 42, fit: CGSize(width: 669, height: 897)) }
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                if session.notice(macName: "Mac", showsClose: true) != nil { covered = true }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await refit.value
        let back = await waitUntil { session.state == .streaming && !session.awaitingFirstFrame && !session.isRetargeting }
        watcher.cancel()
        XCTAssertTrue(back, "换完大小应回到正常在放")
        XCTAssertFalse(covered, "换大小期间不该盖「正在连接」")
        XCTAssertEqual(session.info?.displayWidth, 669)
        // 换到另一个窗口不算换大小：照常盖。
        mac.windows.append((id: 43, app: "Safari", title: "B", bounds: CGRect(x: 0, y: 0, width: 900, height: 600)))
        let other = Task { await session.switchWindow(to: 43) }
        let coveredForOther = await waitUntil(2) { session.notice(macName: "Mac", showsClose: true) != nil }
        XCTAssertTrue(coveredForOther, "换窗口时照常提示正在连接")
        await other.value
    }

    // MARK: - 看着时保持在最前

    func test_keep_front_raises_the_window_again_when_another_app_comes_forward() async throws {
        // 被别的 App 盖住的窗口 macOS 不让它重绘，画面停在最后一帧：主控端要了「保持在最前」时，Mac 隔一会儿看一眼，
        // 它的 App 不在最前了就重新提上来。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42, keepFront: true, independentInput: false)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.raisedWindows, [42], "开流时提一次")
        // 一直在最前：不反复去提。
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(mac.raisedWindows, [42])
        // 别的 App 到前面来了。
        mac.windowsBehind = [42]
        let raised = await waitUntil(4) { mac.raisedWindows == [42, 42] }
        XCTAssertTrue(raised, "退到后面之后应重新提到最前：\(mac.raisedWindows)")
        // 不看了：之后它退到后面也不再管。
        session.stop()
        _ = await waitUntil { server.desktopViewer == nil }
        mac.windowsBehind = [42]
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(mac.raisedWindows, [42, 42], "停流后不该再去提窗口")
    }

    func test_window_is_left_alone_unless_keep_front_was_asked() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42, independentInput: false)
        XCTAssertEqual(session.state, .streaming)
        mac.windowsBehind = [42]
        try await Task.sleep(for: .milliseconds(1800))
        XCTAssertEqual(mac.raisedWindows, [42], "没要保持在最前：只在开流时提一次，不和坐在 Mac 前的人抢窗口")
        // 中途打开：按同一个窗口重开流，从此开始保持。
        await session.switchWindow(to: 42, keepFront: true, independentInput: false)
        let raised = await waitUntil(4) { mac.raisedWindows.count >= 2 && mac.windowsBehind.isEmpty }
        XCTAssertTrue(raised, "打开开关后应把窗口提回最前：\(mac.raisedWindows)")
    }

    func test_independent_input_leaves_the_app_in_the_background() async throws {
        // 「独立键鼠」：输入直接投给窗口所在的进程，开流前不把 App 变成当前 App；关掉就回到老办法，先提到最前。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        XCTAssertTrue(session.supportsWindowInput)
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.independentInputs, [true])
        XCTAssertEqual(mac.surfacedWindows, [42])
        XCTAssertTrue(mac.raisedWindows.isEmpty, "不抢 Mac 上的前台 App")

        await session.switchWindow(to: 42, independentInput: false)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.independentInputs, [true, false])
        XCTAssertEqual(mac.raisedWindows, [42], "走全局通道：点击只落到最上面的窗口，开流前提到最前")
        XCTAssertEqual(mac.surfacedWindows, [42])
    }

    func test_independent_input_is_not_asked_of_an_old_mac() async throws {
        let old = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopWindowInput }
        let (server, mac, client) = try await makeRig(features: old)
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 900, height: 600))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        XCTAssertFalse(session.supportsWindowInput, "主控端据此不显示开关")
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.independentInputs, [false])
        XCTAssertEqual(mac.raisedWindows, [42])
    }

    func test_view_only_never_uses_independent_input() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 900, height: 600))]
        mac.canControl = false
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertTrue(mac.independentInputs.isEmpty, "没有「辅助功能」授权：不建输入落点")
        XCTAssertTrue(mac.surfacedWindows.isEmpty)
    }

    func test_connection_drop_restores_fitted_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let original = CGRect(x: 200, y: 100, width: 1512, height: 874)
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: original)]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.windows[0].bounds.size, CGSize(width: 951, height: 619))
        // 手机那头整条连接断了（没来得及发停流）：Mac 自己把窗口放回去。
        client.disconnect()
        let restored = await waitUntil { mac.windows[0].bounds == original }
        XCTAssertTrue(restored, "连接断开后窗口应还原")
    }

    func test_view_only_does_not_resize_the_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 1512, height: 874))]
        mac.canControl = false
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 619))
        XCTAssertEqual(session.state, .streaming)
        XCTAssertTrue(mac.fittedWindows.isEmpty, "没有辅助功能授权时不动窗口")
        XCTAssertEqual(session.info?.displayWidth, 1512)
    }

    func test_static_window_stream_stays_connected() async throws {
        // 2026-11-17 真机：切到只看一个窗口后画面一静止，手机每隔 4–10 秒就判定连接已死、重连重开流。
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 200, y: 100, width: 951, height: 615))]
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.start()
        XCTAssertEqual(session.state, .streaming)
        await session.switchWindow(to: 42, fit: CGSize(width: 951, height: 615))
        XCTAssertEqual(session.state, .streaming)
        let sourcesBefore = mac.sources.count
        // 画面完全不动 7 秒：连接要一直在，流不该被重开。
        try await Task.sleep(for: .seconds(7))
        XCTAssertEqual(client.state, .connected)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.sources.count, sourcesBefore, "静止期间流被重开了 \(mac.sources.count - sourcesBefore) 次")
    }

    func test_window_gone_is_rejected_and_connection_survives() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 99)
        guard case .failed(let message) = session.state else { return XCTFail("窗口不存在应被拒：\(session.state)") }
        XCTAssertTrue(message.contains("找不到要看的窗口"), message)
        XCTAssertEqual(client.state, .connected)
        XCTAssertTrue(mac.sources.isEmpty, "被拒时不该开采集")
    }

    func test_view_only_does_not_raise_the_window() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        // 没有「辅助功能」授权：提不动窗口（同一项授权），流照开。
        mac.canControl = false
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(session.info?.windowID, 42)
        XCTAssertTrue(mac.raisedWindows.isEmpty)
    }

    func test_window_list_explains_when_desktop_is_off_or_unauthorized() async throws {
        let (server, mac, client) = try await makeRig()
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        mac.enabled = false
        var list = try await client.desktopWindows()
        XCTAssertTrue(list.windows.isEmpty)
        XCTAssertTrue(list.message?.contains("没有打开远程桌面") == true, list.message ?? "nil")
        mac.enabled = true
        mac.screenAuthorized = false
        list = try await client.desktopWindows()
        XCTAssertTrue(list.windows.isEmpty)
        XCTAssertTrue(list.message?.contains("屏幕录制") == true, list.message ?? "nil")
    }

    func test_old_mac_gets_no_window_request() async throws {
        // 老 Mac：不声明 desktop-windows。主控端不发 `desktopWindows`（老 Mac 会断开整条连接），开流也不带窗口号。
        let old = RemoteConstants.localFeatures.filter { $0 != RemoteFeature.desktopWindows }
        let (server, mac, client) = try await makeRig(features: old)
        defer { server.stop() }
        mac.windows = [(id: 42, app: "Xcode", title: "A", bounds: CGRect(x: 0, y: 0, width: 800, height: 600))]
        XCTAssertFalse(client.supportsDesktopWindows)
        do {
            _ = try await client.desktopWindows()
            XCTFail("老 Mac 上应直接报版本太旧")
        } catch RemoteAttachError.rejected(let message) {
            XCTAssertTrue(message.contains("版本太旧"), message)
        }
        XCTAssertEqual(client.state, .connected)
        let session = RemoteDesktopSession(client: client, maxWidth: 2007, maxHeight: 2853)
        defer { session.stop() }
        XCTAssertFalse(session.supportsWindows)
        await session.switchWindow(to: 42)
        XCTAssertEqual(session.state, .streaming)
        XCTAssertEqual(mac.openedWindows, [nil], "老 Mac 上照旧看整块显示器")
        XCTAssertTrue(mac.raisedWindows.isEmpty)
    }

    // MARK: - 几何换算

    func test_frame_geometry_from_capture_attachments() throws {
        // 2026-11-17 探针的读数：400×332 的窗口按 800×664 开流，之后放大到 520×412。
        let start = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 332), contentScale: 1, scaleFactor: 2,
            screenRect: CGRect(x: 300, y: 664, width: 400, height: 332), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(start, .whole(CGRect(x: 300, y: 664, width: 400, height: 332)))

        let grown = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 400, height: 316), contentScale: 0.7692307829856873, scaleFactor: 2,
            screenRect: CGRect(x: 300, y: 664, width: 520, height: 412), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(grown.bounds.origin, CGPoint(x: 300, y: 664))
        XCTAssertEqual(grown.bounds.width, 520, accuracy: 0.5)
        XCTAssertEqual(grown.bounds.height, 411, accuracy: 1)
        XCTAssertEqual(grown.contentFraction.width, 1, accuracy: 0.001)
        XCTAssertEqual(grown.contentFraction.height, 632.0 / 664, accuracy: 0.001)
        XCTAssertTrue(grown.differsVisibly(from: start))

        // 菜单伸出窗口：范围比窗口大，系统报的屏幕位置还是窗口的。按左上角不动算。
        let menu = try XCTUnwrap(RemoteDesktopFrameGeometry.make(
            contentRect: CGRect(x: 0, y: 0, width: 399, height: 326), contentScale: 0.681430995464325, scaleFactor: 2,
            screenRect: CGRect(x: 450, y: 524, width: 520, height: 412), frameSize: CGSize(width: 800, height: 664)))
        XCTAssertEqual(menu.bounds.origin, CGPoint(x: 450, y: 524))
        XCTAssertEqual(menu.bounds.width, 585.5, accuracy: 0.5)
        XCTAssertEqual(menu.bounds.height, 478.4, accuracy: 0.5)

        // 光挪位置不算「看得出的变化」。
        let moved = RemoteDesktopFrameGeometry.whole(CGRect(x: 900, y: 10, width: 400, height: 332))
        XCTAssertFalse(moved.differsVisibly(from: start))

        // 缺东西、尺寸为零都算不出。
        XCTAssertNil(RemoteDesktopFrameGeometry.make(contentRect: .zero, contentScale: 1, scaleFactor: 2,
                                                     screenRect: .zero, frameSize: CGSize(width: 800, height: 664)))
        XCTAssertNil(RemoteDesktopFrameGeometry.make(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), contentScale: 0,
                                                     scaleFactor: 2, screenRect: .zero, frameSize: CGSize(width: 800, height: 664)))
    }

    func test_window_fit_shrinks_the_window_for_bigger_text() {
        let canvas = CGSize(width: 951, height: 619)
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 1), CGSize(width: 951, height: 619))
        // 字大 1.25 倍：窗口只有画布的 0.8，画面放大 1.25 倍铺满。
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 1.25), CGSize(width: 761, height: 495))
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 0.8), CGSize(width: 1189, height: 774))
        // 离谱的值夹住；画布还没量出来时没有尺寸。
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 10), CGSize(width: 476, height: 310))
        XCTAssertNil(RemoteDesktopWindowFit.size(canvas: .zero, textScale: 1))
        XCTAssertNil(RemoteDesktopWindowFit.size(canvas: canvas, textScale: .nan))
        XCTAssertTrue(RemoteDesktopWindowFit.textScales.contains(1))
    }

    /// 「最清晰」（默认）：Mac 每点 2 个像素，窗口调成画布像素数的一半那么多点，画面不经放大。
    func test_sharpest_text_scale_maps_mac_pixels_onto_device_pixels() {
        let canvas = CGSize(width: 951, height: 669)
        XCTAssertEqual(RemoteDesktopWindowFit.defaultTextScale, RemoteDesktopWindowFit.sharpest, "默认是最清晰")
        let phone = RemoteDesktopWindowFit.size(canvas: canvas, textScale: RemoteDesktopWindowFit.sharpest, displayScale: 3)
        XCTAssertEqual(phone, CGSize(width: 1426, height: 1003),
                       "3 倍屏：画布 2853×2007 像素，窗口 2852×2006 像素（往下取整，不能比画布多出一个像素）")
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: CGSize(width: 950, height: 668), textScale: RemoteDesktopWindowFit.sharpest,
                                                   displayScale: 3), CGSize(width: 1425, height: 1002), "像素数是偶数时正好对上")
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: RemoteDesktopWindowFit.sharpest, displayScale: 2),
                       CGSize(width: 951, height: 669), "2 倍屏：和标准一样")
        XCTAssertEqual(RemoteDesktopWindowFit.size(canvas: canvas, textScale: 1, displayScale: 3),
                       CGSize(width: 951, height: 669), "别的档不看屏幕的倍数")
        XCTAssertEqual(RemoteDesktopWindowFit.scale(for: RemoteDesktopWindowFit.sharpest, displayScale: 0), 2, "倍数没报上来时不除以零")
    }

    /// 画面和画布只差一两个像素时按原生像素一比一排、落在整像素上，不拉去铺满。
    func test_viewport_shows_a_nearly_fitting_picture_at_native_pixels() {
        // 「最清晰」的真实情形：画布 951×669 点（3 倍屏），窗口 1426×1003 点，视频 2852×2006 像素。
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 1426, height: 1003),
                                             viewSize: CGSize(width: 951, height: 669), bleedsIntoCorners: true)
        let stretched = viewport.contentFrame
        XCTAssertEqual(stretched.width, 951, accuracy: 0.01, "前提：不给原生大小时拉去铺满")
        viewport.nativeSize = CGSize(width: 2852.0 / 3, height: 2006.0 / 3)
        viewport.pixelsPerPoint = 3
        let frame = viewport.contentFrame
        XCTAssertEqual(frame.width * 3, 2852, accuracy: 0.001, "一个视频像素对一个屏幕像素")
        XCTAssertEqual(frame.height * 3, 2006, accuracy: 0.001)
        XCTAssertEqual((frame.minX * 3).rounded(), frame.minX * 3, accuracy: 0.001, "位置在整像素上")
        XCTAssertEqual((frame.minY * 3).rounded(), frame.minY * 3, accuracy: 0.001)
        XCTAssertEqual(viewport.scale, 2852.0 / 3 / 1426, accuracy: 0.0001, "滚动量、指针照这个比例换算")
    }

    func test_viewport_does_not_snap_when_the_picture_is_far_from_native_or_too_big() {
        var viewport = RemoteDesktopViewport(contentSize: CGSize(width: 951, height: 669),
                                             viewSize: CGSize(width: 951, height: 669), bleedsIntoCorners: true)
        viewport.pixelsPerPoint = 3
        viewport.nativeSize = CGSize(width: 1902.0 / 3, height: 1338.0 / 3)
        XCTAssertNil(viewport.snappedSize, "标准字号：视频只有画布三分之二的像素，照旧放大铺满")
        XCTAssertEqual(viewport.contentFrame.width, 951, accuracy: 0.01)
        viewport.contentSize = CGSize(width: 1427, height: 1004)
        viewport.nativeSize = CGSize(width: 2854.0 / 3, height: 2008.0 / 3)
        XCTAssertNil(viewport.snappedSize, "比画布还大一个像素：放不下，照旧缩进去")
    }

    func test_listable_windows_skip_overlays_and_tiny_ones() {
        func entry(_ id: UInt32, layer: Int = 0, alpha: Double = 1, size: CGSize = CGSize(width: 800, height: 600),
                   app: String = "App", title: String = "") -> RemoteDesktopWindows.Entry {
            RemoteDesktopWindows.Entry(id: id, pid: 100, app: app, title: title,
                                       bounds: CGRect(origin: .zero, size: size), layer: layer, alpha: alpha)
        }
        let listed = RemoteDesktopWindows.listable([
            entry(1, app: "Xcode", title: "uTerm"),
            entry(2, layer: 25),                                   // 菜单栏上的状态项
            entry(3, alpha: 0),                                    // 看不见的
            entry(4, size: CGSize(width: 120, height: 40)),        // 太小
            entry(5, app: "Google Chrome"),
        ])
        XCTAssertEqual(listed.map(\.id), [1, 5], "只留普通层级、看得见、不太小的，顺序不变")
        XCTAssertEqual(listed[0], RemoteDesktopWindowSummary(id: 1, app: "Xcode", title: "uTerm", width: 800, height: 600))
    }

    func test_window_frame_matching_tolerates_one_point() {
        let frame = CGRect(x: 100, y: 50, width: 800, height: 600)
        XCTAssertTrue(RemoteDesktopWindows.matches(frame, frame.offsetBy(dx: 0.5, dy: -1)))
        XCTAssertFalse(RemoteDesktopWindows.matches(frame, frame.offsetBy(dx: 2, dy: 0)))
        XCTAssertFalse(RemoteDesktopWindows.matches(frame, CGRect(x: 100, y: 50, width: 803, height: 600)))
    }

    // MARK: - 重复帧比对

    func test_identical_frames_compare_equal_and_one_changed_byte_does_not() {
        let first = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 3)
        let same = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 3)
        let other = RemoteDesktopFixture.makeFrame(width: 320, height: 200, seed: 4)
        XCTAssertTrue(RemoteFrameCompare.identical(first, first))
        XCTAssertTrue(RemoteFrameCompare.identical(first, same))
        XCTAssertFalse(RemoteFrameCompare.identical(first, other))
        XCTAssertFalse(RemoteFrameCompare.identical(first, RemoteDesktopFixture.makeFrame(width: 320, height: 202, seed: 3)),
                       "尺寸不同不算一样")

        // 只改色度面最后一行的最后一个字节（闪烁的光标就是这么小的变化）：必须比得出来。
        CVPixelBufferLockBaseAddress(same, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(same, 1)
        let rows = CVPixelBufferGetHeightOfPlane(same, 1)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(same, 1)!.assumingMemoryBound(to: UInt8.self)
        chroma[(rows - 1) * stride + 319] ^= 0xFF
        CVPixelBufferUnlockBaseAddress(same, [])
        XCTAssertFalse(RemoteFrameCompare.identical(first, same))
    }

    // MARK: - 协议

    func test_wire_numbers_and_old_peers_ignore_the_new_keys() throws {
        XCTAssertEqual(RemoteMessage.Kind.desktopWindows.rawValue, 54)
        XCTAssertEqual(RemoteMessage.Kind.desktopWindowList.rawValue, 55)
        XCTAssertEqual(RemoteMessage.Kind.desktopGeometry.rawValue, 56)
        XCTAssertEqual(RemoteFeature.desktopWindows, "desktop-windows")
        XCTAssertTrue(RemoteConstants.localFeatures.contains(RemoteFeature.desktopWindows))

        // 老主控端的开流请求没有 windowID：解出来是 nil（整块显示器）。
        let legacy = #"{"requestID":"8E6B6C7E-2D6B-4B0B-9A52-3F4E2A1B0C9D","maxWidth":1206,"maxHeight":2622,"codec":"hevc"}"#
        let request = try RemoteJSON.decode(RemoteDesktopStartRequest.self, from: Data(legacy.utf8))
        XCTAssertNil(request.windowID)

        var withWindow = request
        withWindow.windowID = 42
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopStartRequest.self, from: RemoteJSON.encode(withWindow)).windowID, 42)

        let update = RemoteDesktopGeometryUpdate(width: 1200, height: 700, contentWidth: 1, contentHeight: 0.868)
        XCTAssertEqual(try RemoteJSON.decode(RemoteDesktopGeometryUpdate.self, from: RemoteJSON.encode(update)), update)
    }

    // MARK: - 夹具

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(3))
        }
        return true
    }

    /// 服务端（不广播，只在 127.0.0.1 监听）+ 已预先互信、已连上的手机客户端。
    private func makeRig(features: [String] = RemoteConstants.localFeatures)
        async throws -> (RemoteHostServer, FakeDesktopMac, RemoteMacClient) {
        let mac = FakeDesktopMac()
        let server = RemoteHostServer(registry: TerminalSessionRegistry(),
                                      identity: RemoteIdentityStore(role: .controllers, storage: RemoteMemoryStorage()),
                                      localName: "测试 Mac", localID: UUID(), advertises: false,
                                      localFeatures: features, desktopEnvironment: mac.environment())
        server.start()
        let ready = await waitUntil { server.port != nil }
        XCTAssertTrue(ready, "服务端没起来：\(server.status)")
        let phoneIdentity = RemoteIdentityStore(role: .hosts, storage: RemoteMemoryStorage())
        try server.trust(RemotePeer(id: RemoteLocalDevice.id(), name: "测试 iPhone",
                                    publicKey: try phoneIdentity.localIdentity().publicKey.rawRepresentation,
                                    pairedAt: Date()))
        let client = RemoteMacClient(macName: "测试 Mac",
                                     endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: try XCTUnwrap(server.port))!),
                                     identity: phoneIdentity)
        await client.connect()
        XCTAssertEqual(client.state, .connected)
        return (server, mac, client)
    }
}
