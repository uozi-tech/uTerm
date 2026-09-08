import SwiftUI
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// `SFTPScreen`（iOS 文件标签）的渲染 / 交互成本探针。
///
/// ## 为什么这一轮才写得出来
///
/// 上一版夹具只能把目录**填**进控制器：`MobileSFTPController` 直接持有具体的
/// `SFTPSession`，`open` / `goUp` / `delete` / `rename` / `chmod` / 上传下载全都
/// `guard let session` 空转，交互的端到端成本量不到。本轮把控制器的依赖降到产品
/// 已有的 `SFTPProviding` 协议（与桌面 `FileBrowserModel` 同一个），并补了
/// `MobileSFTPController(testProvider:startPath:)` 注入口，
/// `MobileFakeSFTPProvider` 升级成完整的内存假会话 —— 于是下面每一条交互跑的
/// **都是产品自己的那条路径**，探针只负责计时和判据。
///
/// ## 规模从哪来
///
/// SFTP 的目录条目数没有产品内的注入口（不像主机列表能靠 SwiftData 播种），
/// 规模由假会话生成：
///
/// - **真实档 500**：一台服务器上随手打开的目录量级（Ubuntu 24.04 的 `/usr/bin`
///   约 1000 条、一个中型项目的 `src/` 或按天切分的日志目录几百条）。
/// - **极端档 20000**：`node_modules`、按小时切分的日志目录、对象存储挂载点。
///   这是"还能不能用"的边界档，不是常态。
///
/// 两档与 `MobileFixturesTests.testSFTPScreenMountsFakeSession` 同源，读数可互相对照。
///
/// ## 闸门
///
/// **绝对毫秒只打印**。判红只用结构判据：
/// 1. `UIView` 数不随条目数涨（500 与 20000 之差 ≤ 2）——判 B/C 的第一判据；
/// 2. `scrollable > 0` 且 `travelled > 单程幅度`（否则读数作废，`MobileProbeRig` 自己抛）；
/// 3. hitTest p50 的**比值**不随规模涨（≤ 3×）；
/// 4. `ink > 0.005`（截图不是空壳）；
/// 5. 每次交互之后，`controller.entries` 与 `UIScrollView.contentSize` 必须对得上
///    （进目录 = 子目录条数 + 1 行 `..`；删一条 = 少一行；改名 = 条数不变）。
@MainActor
final class SFTPScreenProbeTests: XCTestCase {

    /// `SFTPRow` 的固定行高（`.frame(height: 56)`）。`..` 行同高。
    private static let rowHeight: CGFloat = 56
    private static let realistic = 500
    private static let extreme = 20_000

    // MARK: - 挂载脚手架

    private struct Mounted {
        let rig: MobileProbeRig
        let controller: MobileSFTPController
        let provider: MobileFakeSFTPProvider
        /// 容器要活到用例结束：`@Query` 靠它，提前释放会把主机列表抽走。
        let container: ModelContainer
        let store: MobileStore
        let session: MobileSFTPSession
    }

    /// 把 `SFTPScreen` 用假会话挂起来（不发起任何真实连接）。
    ///
    /// `MobileFakeSFTP.session` 会把 `activeTarget` 预设成 `store.sftpTarget`，
    /// `SFTPScreen.consumeSFTPTarget` 因此整条跳过 `controller.start(...)`。
    private func mountScreen(label: String, entries count: Int,
                             subdirectories: Int = 0, childCount: Int = 0,
                             depth: Int = 1) async throws -> Mounted {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let host = try XCTUnwrap(MobileFixtures.firstServer(in: container))
        let provider = MobileFakeSFTPProvider(entries: count,
                                              subdirectories: subdirectories,
                                              childCount: childCount, depth: depth)
        let session = await MobileFakeSFTP.session(host: host, provider: provider)
        let store = MobileStore()
        store.sftpTarget = host.persistentModelID
        store.tab = .sftp

        let rig = MobileProbeRig(label: label)
        rig.mount(
            SFTPScreen()
                .environment(store)
                .environment(HostKeyChallengeRelay())
                .environment(session)
                .modelContainer(container))
        return Mounted(rig: rig, controller: session.controller, provider: provider,
                       container: container, store: store, session: session)
    }

    /// 等到「模型改完 **且** 列表真的重排完」，返回端到端毫秒。
    ///
    /// 产品的 `open` / `goUp` / `delete` / `rename` / `chmod` / `upload` 都是
    /// 发射后不管的 `Task`，调用点拿不到句柄；而 SwiftUI 的更新还要再过一趟。
    /// 所以判据直接落在 `controller` + `UIScrollView.contentSize` 上 —— 两边都成立
    /// 才叫「这次交互端到端做完了」。
    ///
    /// 动作写成尾随的 `beforeStart:` 而不是调用点前一句：计时起点要严格落在动作
    /// **之前**，中间插一次布局就把账算歪了。等待用 `Task.yield()`（不 sleep，
    /// 免得把等待本身算进读数），`rig.layout()` 每轮逼一次布局 + CA 提交。
    /// 超时判红 —— 等不到必须红，不能静默返回一个漂亮的小数字。
    @discardableResult
    private func settleLayout(_ m: Mounted, _ what: String,
                              timeoutSeconds: Double = 20,
                              until condition: @MainActor () -> Bool,
                              beforeStart action: @MainActor () -> Void) async throws -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        action()
        var spins = 0
        while true {
            m.rig.layout()
            if condition() { return (CFAbsoluteTimeGetCurrent() - start) * 1000 }
            if CFAbsoluteTimeGetCurrent() - start > timeoutSeconds {
                XCTFail("\(timeoutSeconds)s 内没等到「\(what)」")
                throw MobileFakeSFTPError.noSuchFile(what)
            }
            spins += 1
            // 纯 yield 在极少数情况下喂不到 CA 的提交时机；每 200 转让一次 runloop。
            if spins % 200 == 0 {
                try? await Task.sleep(for: .milliseconds(1))
            } else {
                await Task.yield()
            }
        }
    }

    private func expectedContentHeight(_ m: Mounted) -> CGFloat {
        let upRow: CGFloat = m.controller.path == "/" ? 0 : Self.rowHeight
        return CGFloat(m.controller.entries.count) * Self.rowHeight + upRow
    }

    // MARK: - ① 两档挂载 + 滚动

    /// 500 / 20000 两档：挂载、心跳、200 步往返、结构快照。
    /// 闸门是「`UIView` 数不随条目涨」+「hitTest 比值不涨」，毫秒只打印。
    func testMountAndScrollAcrossTiers() async throws {
        defer { MobileProbeWindow.closeAll() }

        var views: [Int: Int] = [:]
        var hitP50: [Int: Double] = [:]

        for count in [Self.realistic, Self.extreme] {
            let m = try await mountScreen(label: "sftp-\(count)", entries: count)
            XCTAssertEqual(m.controller.entries.count, count, "假会话必须把整目录列出来")

            let scrollView = try m.rig.requireScrollView()
            XCTAssertEqual(scrollView.contentSize.height,
                           CGFloat(count) * Self.rowHeight, accuracy: 1,
                           "内容高必须随条目数线性涨（行高 56pt）")

            let beat = try await m.rig.heartbeat(seconds: 1)
            let scroll = try await m.rig.measureScroll()
            let shot = await m.rig.snapshot()
            m.rig.report(scroll, shot, beat)
            attachProbePNG(shot.png, name: "sftp-\(count)")

            // 结构判据（毫秒不判）
            XCTAssertGreaterThan(scroll.scrollable, 0)
            XCTAssertGreaterThan(scroll.travelled, scroll.amplitude,
                                 "驱动没真的推动列表，读数作废")
            XCTAssertGreaterThan(shot.ink, 0.005, "截图是空壳，这一档的读数不算数")
            views[count] = shot.views
            hitP50[count] = shot.hitP50
            await m.rig.close()
        }

        let small = try XCTUnwrap(views[Self.realistic])
        let large = try XCTUnwrap(views[Self.extreme])
        print("[sftp-verdict] views \(Self.realistic)=\(small) \(Self.extreme)=\(large)")
        XCTAssertLessThanOrEqual(abs(small - large), 2,
                                 "UIView 数随条目数涨 = 列表不是真的懒建（判 B/C 的第一判据）")

        let hSmall = try XCTUnwrap(hitP50[Self.realistic])
        let hLarge = try XCTUnwrap(hitP50[Self.extreme])
        print(String(format: "[sftp-verdict] hitTest p50 %d=%.1fus %d=%.1fus ratio=%.2f",
                     Self.realistic, hSmall, Self.extreme, hLarge,
                     hSmall > 0 ? hLarge / hSmall : 0))
        if hSmall > 0 {
            XCTAssertLessThan(hLarge / hSmall, 3.0,
                              "命中路径被条目数拖累（守比值不守绝对微秒）")
        }
    }

    // MARK: - ② 进目录 / 返回上级（走产品的 open / goUp）

    /// 两档各做一次「进子目录 → 返回上级」，量端到端（模型 + 重排 + CA 提交）。
    ///
    /// 结构判据：进目录后内容高 = 子目录条数 × 56 + 一行 `..`；返回后回到原值。
    /// 一条也不能靠夹具回填 —— 走的是 `controller.open(_:)` / `goUp()` 本身。
    func testDirectoryNavigationEndToEnd() async throws {
        defer { MobileProbeWindow.closeAll() }

        for count in [Self.realistic, Self.extreme] {
            let childCount = 200
            let m = try await mountScreen(label: "sftp-nav-\(count)", entries: count,
                                          subdirectories: 6, childCount: childCount,
                                          depth: 2)
            let scrollView = try m.rig.requireScrollView()
            let rootHeight = scrollView.contentSize.height
            let dir = try XCTUnwrap(m.controller.entries.first { $0.isDirectory },
                                    "这一档必须有目录行才谈得上进目录")

            let enterMS = try await settleLayout(m, "进目录 /\(dir.name)") {
                m.controller.path == "/\(dir.name)"
                    && scrollView.contentSize.height == self.expectedContentHeight(m)
            } beforeStart: {
                m.controller.open(dir)
            }
            XCTAssertEqual(m.controller.entries.count, childCount)
            XCTAssertEqual(scrollView.contentSize.height,
                           CGFloat(childCount + 1) * Self.rowHeight, accuracy: 1,
                           "进目录后要多出一行 `..`")

            let upMS = try await settleLayout(m, "返回上级") {
                m.controller.path == "/"
                    && scrollView.contentSize.height == self.expectedContentHeight(m)
            } beforeStart: {
                m.controller.goUp()
            }
            XCTAssertEqual(m.controller.entries.count, count)
            XCTAssertEqual(scrollView.contentSize.height, rootHeight, accuracy: 1,
                           "返回上级要回到原来的列表")

            print(String(format: "[sftp-nav-%d] enter=%.1fms(%d 条) up=%.1fms(%d 条) "
                         + "list-calls=%d",
                         count, enterMS, childCount, upMS, count,
                         await m.provider.callCount(.list)))
            await m.rig.close()
        }
    }

    // MARK: - ③ 改名 / 删除后的列表刷新

    /// 两档各做一次「改名 → 删除」，量端到端。
    ///
    /// 结构判据：改名后条数不变、新名在列表里、旧名不在；删除后正好少一条。
    /// 两步都会触发产品自己的「改完重列整个目录」，20000 档量的正是那一次重列的账。
    func testRenameAndDeleteRefreshEndToEnd() async throws {
        defer { MobileProbeWindow.closeAll() }

        for count in [Self.realistic, Self.extreme] {
            let m = try await mountScreen(label: "sftp-mut-\(count)", entries: count)
            let scrollView = try m.rig.requireScrollView()
            let victim = try XCTUnwrap(m.controller.entries.first { $0.isRegularFileForProbe })
            let newName = "renamed-by-probe.bin"

            let renameMS = try await settleLayout(m, "改名后列表刷新") {
                m.controller.entries.contains { $0.name == newName }
            } beforeStart: {
                m.controller.rename(victim, to: newName)
            }
            XCTAssertEqual(m.controller.entries.count, count, "改名不改条目数")
            XCTAssertFalse(m.controller.entries.contains { $0.name == victim.name })
            XCTAssertEqual(scrollView.contentSize.height,
                           CGFloat(count) * Self.rowHeight, accuracy: 1)

            let renamed = try XCTUnwrap(m.controller.entries.first { $0.name == newName })
            let deleteMS = try await settleLayout(m, "删除后列表刷新") {
                m.controller.entries.count == count - 1
                    && scrollView.contentSize.height == self.expectedContentHeight(m)
            } beforeStart: {
                m.controller.delete(renamed)
            }
            XCTAssertFalse(m.controller.entries.contains { $0.name == newName })
            XCTAssertEqual(scrollView.contentSize.height,
                           CGFloat(count - 1) * Self.rowHeight, accuracy: 1,
                           "删一条就该少一行")

            // chmod 也走同一条「改完重列」的路，顺带量一笔。
            let target = try XCTUnwrap(m.controller.entries.first { $0.isRegularFileForProbe })
            let chmodMS = try await settleLayout(m, "chmod 后列表刷新") {
                (m.controller.entries.first { $0.name == target.name }?
                    .permissions ?? 0) & 0o777 == 0o600
            } beforeStart: {
                m.controller.chmod(target, mode: 0o600)
            }

            print(String(format: "[sftp-mut-%d] rename=%.1fms delete=%.1fms chmod=%.1fms "
                         + "list-calls=%d",
                         count, renameMS, deleteMS, chmodMS,
                         await m.provider.callCount(.list)))

            // 失败注入：删除失败必须落到 `.failed` 态（不能静默吞掉）。
            await m.provider.inject(.removeFile, message: "权限不足（探针注入）")
            let doomed = try XCTUnwrap(m.controller.entries.first { $0.isRegularFileForProbe })
            let entriesBefore = m.controller.entries.count
            _ = try await settleLayout(m, "删除失败落到 failed 态") {
                if case .failed = m.controller.state { return true }
                return false
            } beforeStart: {
                m.controller.delete(doomed)
            }
            XCTAssertEqual(m.controller.entries.count, entriesBefore,
                           "删除失败不能把列表改掉")
            await m.rig.close()
        }
    }

    // MARK: - ④ 一次上传 + 一次下载（端到端，假会话）

    /// 真实档做一次「上传本地文件 → 列表出现 → 下载回来」，量端到端并逐字节比对。
    ///
    /// 走的是产品的 `upload(from:)` / `download(_:)`，中间经假会话的流式写 / 读。
    func testUploadDownloadRoundTripEndToEnd() async throws {
        defer { MobileProbeWindow.closeAll() }

        let count = Self.realistic
        let m = try await mountScreen(label: "sftp-io-\(count)", entries: count)
        let scrollView = try m.rig.requireScrollView()

        // 128KB 语料：跨得过假会话 32KB 的分块边界，又不会把用例拖慢。
        let payload = Data((0..<(128 * 1024)).map { UInt8($0 % 251) })
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sftp-probe-\(UUID().uuidString).bin")
        try payload.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let uploadMS = try await settleLayout(m, "上传后列表刷新") {
            m.controller.entries.contains { $0.name == localURL.lastPathComponent }
                && scrollView.contentSize.height == self.expectedContentHeight(m)
        } beforeStart: {
            m.controller.upload(from: localURL)
        }
        XCTAssertEqual(m.controller.entries.count, count + 1, "上传后正好多一条")
        XCTAssertEqual(scrollView.contentSize.height,
                       CGFloat(count + 1) * Self.rowHeight, accuracy: 1)

        let uploaded = try XCTUnwrap(
            m.controller.entries.first { $0.name == localURL.lastPathComponent })
        XCTAssertEqual(uploaded.size, UInt64(payload.count), "列表里的大小要是真大小")

        let downloadStart = CFAbsoluteTimeGetCurrent()
        let downloadedURL = await m.controller.download(uploaded)
        let downloadMS = (CFAbsoluteTimeGetCurrent() - downloadStart) * 1000
        let url = try XCTUnwrap(downloadedURL, "下载必须给出本地 URL")
        XCTAssertEqual(try Data(contentsOf: url), payload, "上传下载必须字节一致")

        print(String(format: "[sftp-io-%d] upload=%.1fms(%dKB) download=%.1fms "
                     + "upload-calls=%d download-calls=%d",
                     count, uploadMS, payload.count / 1024, downloadMS,
                     await m.provider.callCount(.upload),
                     await m.provider.callCount(.download)))
        await m.rig.close()
    }
}
