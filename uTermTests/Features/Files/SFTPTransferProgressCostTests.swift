import AppKit
import SwiftUI
import UDesignKit
import XCTest
@testable import uTerm

/// SFTP 传输进度写路径 + 传输 Dock / 浮层的渲染开销探针。
///
/// 量三件事：
/// 1. **进度流打在主线程上的代价** —— 多路并发传输同时回调 `applyProgress`，
///    每次都写 `transfers[idx]`（`@Observable` 数组元素），状态栏芯片与浮层每次都重求。
/// 2. **`applyProgress` 自身随队列长度的成本** —— 它用 `firstIndex(where:)` 找行，O(n)。
/// 3. **浮层列表在上千条传输时的滚动开销**（`maxConcurrentTransfers` 可到 64，
///    完成 / 失败的行不会自动清）。
///
/// **规模来源**：
/// - 并发数 = `FileBrowserModel.maxConcurrentTransfers`（`sftpMaxConcurrentTransfers`，
///   默认 **4**，钳 1…**64**）。真实档取默认 4，极端档取 16（任务口径）。
/// - 回调频率：真实路径**已经在源头节流** —— `SFTPSession` 的四条传输路径
///   （`SFTPSession.swift` 的 upload(data:)/upload(localURL:)/download(toLocalURL:)/download 内核）
///   都走 `TransferProgressEmitter(totalBytes:minimumInterval: 0.25)`，即**每路每秒最多 4 次**
///   （首块与完成必达）。所以「100MB/s ÷ 32KiB ≈ 3200 次/秒」是 emitter 落地之前的旧账
///   （emitter 见 commit 90f89177）。两个频率都量：`.throttled` = 每路 4Hz（真实），
///   `.raw` = 每路 800Hz（假设 emitter 不存在时 4 路合计 3200Hz 的口径）。
/// - 浮层行数：无上限，取 1000。
@MainActor
final class SFTPTransferProgressCostTests: XCTestCase {

    private var windows: [NSWindow] = []

    private func closeAllWindows() {
        for window in windows {
            window.contentView = NSView()
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    // MARK: - 夹具

    /// 造一个挂起中的传输队列：`MockSFTP.blockTransfers` 让传输永远不完成，
    /// 于是前 `maxConcurrentTransfers` 条停在 `.active`，其余停在 `.queued`。
    private func makeBusyModel(concurrency: Int, queued: Int) async -> FileBrowserModel {
        UserDefaults.standard.set(concurrency, forKey: "sftpMaxConcurrentTransfers")
        let mock = MockSFTP(tree: ["/home/user": []])
        await mock.setBlockTransfers(true)
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        for i in 0..<queued {
            model.enqueueUpload(fileName: String(format: "payload-%04d.bin", i),
                                data: Data(count: 4096))
        }
        // 等调度把前 N 条推成 active。
        for _ in 0..<400 where model.transfers.filter({ $0.status == .active }).count < min(concurrency, queued) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model
    }

    /// 「攒了一天」的队列：先让 `finished` 条真的跑完（`.done` 留在数组里 —— 传输行不会
    /// 自动清，要用户点「清除已完成」），再挂起 `active` 条。
    ///
    /// 这才是 `applyProgress` 的**真实最坏序**：新起的传输永远排在一堆已完成的后面，
    /// `transfers.firstIndex(where:)` 每次都要先扫过那一堆。
    private func makeAgedQueue(finished: Int, active: Int) async -> FileBrowserModel {
        UserDefaults.standard.set(active, forKey: "sftpMaxConcurrentTransfers")
        let mock = MockSFTP(tree: ["/home/user": []])
        let model = FileBrowserModel(testProvider: mock, startPath: "/home/user")
        for i in 0..<finished {
            model.enqueueUpload(fileName: String(format: "old-%04d.bin", i),
                                data: Data(count: 256))
        }
        for _ in 0..<4000 where model.transfers.filter({ $0.status == .done }).count < finished {
            try? await Task.sleep(for: .milliseconds(2))
        }
        await mock.setBlockTransfers(true)
        for i in 0..<active {
            model.enqueueUpload(fileName: String(format: "live-%04d.bin", i),
                                data: Data(count: 4096))
        }
        for _ in 0..<400 where model.transfers.filter({ $0.status == .active }).count < active {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return model
    }

    /// 状态栏芯片 + 浮层同屏 —— 两者都读 `model.transfers`，进度一动就都要重求。
    private struct DockProbeView: View {
        let model: FileBrowserModel
        var body: some View {
            VStack(spacing: 0) {
                SFTPTransfersDock(transfers: model.transfers,
                                  onCancel: { _ in }, onCancelAll: {},
                                  onClearFinished: {}, onRetry: { _ in })
                    .frame(height: 28)
                SFTPTransfersPanel(transfers: model.transfers,
                                   aggSpeed: 0,
                                   activeCount: 0, doneCount: 0,
                                   onCancel: { _ in }, onCancelAll: {},
                                   onClearFinished: {}, onRetry: { _ in })
            }
            .background(UD.bg)
        }
    }

    private func mount(_ view: AnyView, size: NSSize) throws -> ForwardingProbeFixture.Mounted {
        try ForwardingProbeFixture.mount(view, size: size, windows: &windows)
    }

    // MARK: - ① 进度流的主线程代价

    private enum Cadence: String {
        /// 真实路径：`TransferProgressEmitter` 每路每秒最多 4 次。
        case throttled
        /// 假设源头不节流：每路 800Hz（4 路合计 3200Hz 的旧口径）。
        case raw
    }

    private func measureProgressStream(concurrency: Int, cadence: Cadence,
                                       queued: Int) async throws -> (beats: Int, calls: Int) {
        defer { closeAllWindows() }
        let model = await makeBusyModel(concurrency: concurrency, queued: queued)
        let mounted = try mount(AnyView(DockProbeView(model: model)),
                                size: NSSize(width: 420, height: 420))
        mounted.host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        let activeIDs = model.transfers.filter { $0.status == .active }.map(\.id)
        XCTAssertEqual(activeIDs.count, min(concurrency, queued),
                       "并发预算 \(concurrency) 应正好推起这么多条 active")

        // 每 8ms 一拍；每拍按档位补发若干次进度回调。
        // throttled：每路 4Hz ⇒ 每 250ms 一轮 ⇒ 约每 31 拍一轮。
        // raw：每路 800Hz ⇒ 每 8ms 一拍里每路 6~7 次。
        let perBeatPerStream = cadence == .raw ? 7 : 0
        var calls = 0
        var beats = 0
        var bytes: [UUID: Int64] = [:]
        let start = Date()
        while Date().timeIntervalSince(start) < 3 {
            try? await Task.sleep(for: .milliseconds(8))
            beats += 1
            let times = cadence == .raw ? perBeatPerStream : (beats % 31 == 0 ? 1 : 0)
            for _ in 0..<times {
                for id in activeIDs {
                    let next = (bytes[id] ?? 0) + 32 * 1024
                    bytes[id] = next
                    model.applyProgress(id: id,
                                        TransferProgress(bytesDone: next,
                                                         bytesTotal: 64 * 1024 * 1024))
                    calls += 1
                }
            }
            mounted.host.layoutSubtreeIfNeeded()
        }
        model.dispose()
        return (beats, calls)
    }

    /// 真实档（4 路）与极端档（16 路），两种回调频率各量一次。
    /// 判据是**拍数**（3 秒里 8ms 心跳理想 375 拍）—— 主线程被占住多少这里就掉多少。
    func testProgressStreamMainThreadCost() async throws {
        defer { closeAllWindows() }
        var readings: [String: (beats: Int, calls: Int)] = [:]
        for (concurrency, cadence) in [(4, Cadence.throttled), (4, .raw),
                                       (16, Cadence.throttled), (16, .raw)] {
            let r = try await measureProgressStream(concurrency: concurrency,
                                                    cadence: cadence,
                                                    queued: concurrency + 4)
            let key = "\(concurrency)路/\(cadence.rawValue)"
            readings[key] = r
            print("[sftp-progress] \(key) beats=\(r.beats)/375 calls=\(r.calls) "
                  + "(\(r.calls * 1000 / 3000)/s)")
            try? await Task.sleep(for: .milliseconds(200))
        }

        // 结构判据：真实档（源头已节流）不能把主线程压垮。
        let real = try XCTUnwrap(readings["4路/throttled"])
        XCTAssertGreaterThan(real.beats, 200,
                             "真实档（4 路 × 4Hz）3 秒只收到 \(real.beats)/375 拍 —— 主线程被进度流占死了")
    }

    // MARK: - ② applyProgress 随队列长度的成本

    /// `applyProgress` 一次调用的成本不该跟着队列长度涨。
    ///
    /// 改前它用 `transfers.firstIndex(where:)` 找行 —— O(队列长度)。
    /// 传输队列不会自动清（完成 / 失败的行留着等用户「清除已完成」），
    /// 一天下来攒上千条很正常，那时每一次进度回调都要线性扫一遍。
    func testApplyProgressLookupDoesNotScaleWithQueueLength() async throws {
        func cost(history: Int) async -> Double {
            let model = await makeAgedQueue(finished: history, active: 4)
            let ids = model.transfers.filter { $0.status == .active }.map(\.id)
            // 取**最后**一条 active —— 它在数组里排在全部已完成行的后面，是真实最坏序。
            let target = try! XCTUnwrap(ids.last)
            // 预热
            for i in 0..<200 {
                model.applyProgress(id: target,
                                    TransferProgress(bytesDone: Int64(i + 1) * 32768,
                                                     bytesTotal: 64 * 1024 * 1024))
            }
            let rounds = 2000
            let start = CFAbsoluteTimeGetCurrent()
            for i in 0..<rounds {
                model.applyProgress(id: target,
                                    TransferProgress(bytesDone: Int64(i + 300) * 32768,
                                                     bytesTotal: 64 * 1024 * 1024))
            }
            let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)
            model.dispose()
            return ms
        }

        let small = await cost(history: 20)
        let big = await cost(history: 1000)
        let ratio = big / max(small, 1e-9)
        print(String(format: "[sftp-apply] 历史 20 条 %.5fms/次 → 历史 1000 条 %.5fms/次 ratio=%.1f×",
                     small, big, ratio))
        XCTAssertLessThan(ratio, 6,
                          "一次 applyProgress 的成本不该随队列长度涨（历史 20 → 1000 条，50 倍），"
                          + "实测 \(String(format: "%.1f", ratio))×")
    }

    // MARK: - ③ 浮层列表滚动

    /// 传输浮层 1000 行的挂载 / 滚动 / hitTest / NSView。
    func testTransfersPanelScrollCostAtOneThousandRows() async throws {
        defer { closeAllWindows() }
        let rows = 1000
        let statuses: [FileBrowserModel.TransferItem.Status] = [.active, .queued, .done, .failed]
        var items: [FileBrowserModel.TransferItem] = []
        items.reserveCapacity(rows)
        for i in 0..<rows {
            let done: Int64 = Int64(i % 97) * 1_048_576
            let total: Int64 = 128 * 1_048_576
            let speed = Double(i % 13) * 1_400_000
            let direction: FileBrowserModel.TransferDirection = i % 3 == 0 ? .down : .up
            items.append(FileBrowserModel.TransferItem(
                id: UUID(),
                fileName: String(format: "release-bundle-%04d.tar.zst", i),
                direction: direction,
                bytesDone: done,
                bytesTotal: total,
                speedBytesPerSec: speed,
                status: statuses[i % 4]))
        }
        let view = AnyView(
            SFTPTransfersPanel(transfers: items, aggSpeed: 1_234_567,
                               activeCount: rows / 4, doneCount: rows / 4,
                               onCancel: { _ in }, onCancelAll: {},
                               onClearFinished: {}, onRetry: { _ in })
                .frame(maxHeight: .infinity))
        let mounted = try mount(view, size: NSSize(width: 420, height: 480))
        let reading = await ForwardingProbeFixture.measure(
            label: "panel/\(rows)", rows: rows, mounted: mounted)
        print("[sftp-panel] \(reading.oneLine)")
        print("[sftp-panel-views] \(reading.histogram)")

        XCTAssertGreaterThan(reading.scrollableHeight, 0, "1000 行必须超过一屏")
        XCTAssertLessThan(reading.views, 400,
                          "懒栈下 NSView 数不该跟着 1000 行长：实测 \(reading.views)")
        closeAllWindows()
    }

    // MARK: - ④ 状态栏芯片的派生扫描

    /// 状态栏芯片一次 body 求值要把 `transfers` 扫几遍。
    ///
    /// 改前：`active`（filter）在 `chip` / `aggregateChip` / `popover` 里各求一次，
    /// 加上 `doneCount` / `failedCount` / `aggPct`（两次 reduce）/ `aggSpeed`（filter + reduce），
    /// 一次 body 至少 **5~6 遍**全表。而进度每变一次，这个 body 就重求一次。
    /// 改后一遍聚合。两臂同轮交替，判据是同轮相对比。
    func testDockDerivedScansAreOnePass() async throws {
        let statuses: [FileBrowserModel.TransferItem.Status] = [.active, .queued, .done, .failed]
        func makeItems(_ n: Int) -> [FileBrowserModel.TransferItem] {
            var items: [FileBrowserModel.TransferItem] = []
            items.reserveCapacity(n)
            for i in 0..<n {
                let done: Int64 = Int64(i % 97) * 1_048_576
                items.append(FileBrowserModel.TransferItem(
                    id: UUID(), fileName: "f\(i).bin",
                    direction: i % 3 == 0 ? .down : .up,
                    bytesDone: done, bytesTotal: 128 * 1_048_576,
                    speedBytesPerSec: Double(i % 13) * 1_400_000,
                    status: statuses[i % 4]))
            }
            return items
        }

        /// 改前的六次独立扫描。
        func legacy(_ items: [FileBrowserModel.TransferItem]) -> Int {
            let active1 = items.filter { $0.status == .queued || $0.status == .active }
            let doneCount = items.filter { $0.status == .done }.count
            let failedCount = items.filter { $0.status == .failed }.count
            let active2 = items.filter { $0.status == .queued || $0.status == .active }
            let total = active2.reduce(0) { $0 + $1.bytesTotal }
            let doneBytes = active2.reduce(0) { $0 + $1.bytesDone }
            let active3 = items.filter { $0.status == .queued || $0.status == .active }
            let speed = items.filter { $0.status == .active }.reduce(0) { $0 + $1.speedBytesPerSec }
            return active1.count &+ doneCount &+ failedCount &+ Int(total % 7)
                &+ Int(doneBytes % 7) &+ active3.count &+ Int(speed) % 7
        }

        func bench(_ items: [FileBrowserModel.TransferItem],
                   _ body: ([FileBrowserModel.TransferItem]) -> Int) -> Double {
            for _ in 0..<3 { _ = body(items) }
            let rounds = 200
            let start = CFAbsoluteTimeGetCurrent()
            var sink = 0
            for _ in 0..<rounds { sink &+= body(items) }
            XCTAssertNotEqual(sink, Int.min)
            return (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(rounds)
        }

        let small = makeItems(20)
        let big = makeItems(1000)
        // 轮内顺序反转一次，防单向漂移。
        _ = bench(small) { legacy($0) }
        _ = bench(big) { SFTPTransfersDockSummary($0).activeCount }
        let legacySmall = bench(small) { legacy($0) }
        let currentSmall = bench(small) { SFTPTransfersDockSummary($0).activeCount }
        let currentBig = bench(big) { SFTPTransfersDockSummary($0).activeCount }
        let legacyBig = bench(big) { legacy($0) }
        print(String(format: """
            [sftp-dock] legacy 20 条 %.5fms / 1000 条 %.5fms | current 20 条 %.5fms / 1000 条 %.5fms
            """, legacySmall, legacyBig, currentSmall, currentBig))
        XCTAssertLessThan(currentBig, legacyBig * 0.6,
                          String(format: "1000 条一次派生：改前 %.5fms → 改后 %.5fms",
                                 legacyBig, currentBig))
    }

    /// 一遍聚合出来的数值必须与逐次扫描完全一致。
    func testDockSummaryMatchesTheLegacyScans() {
        let statuses: [FileBrowserModel.TransferItem.Status] = [.active, .queued, .done, .failed]
        var items: [FileBrowserModel.TransferItem] = []
        for i in 0..<40 {
            items.append(FileBrowserModel.TransferItem(
                id: UUID(), fileName: "f\(i)", direction: i % 2 == 0 ? .up : .down,
                bytesDone: Int64(i) * 100, bytesTotal: Int64(i + 1) * 1000,
                speedBytesPerSec: Double(i) * 10, status: statuses[i % 4]))
        }
        let summary = SFTPTransfersDockSummary(items)
        let activeRef = items.filter { $0.status == .queued || $0.status == .active }
        XCTAssertEqual(summary.activeCount, activeRef.count)
        XCTAssertEqual(summary.doneCount, items.filter { $0.status == .done }.count)
        XCTAssertEqual(summary.failedCount, items.filter { $0.status == .failed }.count)
        XCTAssertEqual(summary.allActiveAreUploads, activeRef.allSatisfy { $0.direction == .up })
        XCTAssertEqual(summary.aggregateSpeed,
                       items.filter { $0.status == .active }.reduce(0) { $0 + $1.speedBytesPerSec },
                       accuracy: 0.0001)
        let total = activeRef.reduce(0) { $0 + $1.bytesTotal }
        let done = activeRef.reduce(0) { $0 + $1.bytesDone }
        XCTAssertEqual(summary.aggregateFraction,
                       total > 0 ? min(1, Double(done) / Double(total)) : 0,
                       accuracy: 0.0001)
        // 单条进行中时才给 `single`（状态栏内联进度那一档）。
        XCTAssertEqual(summary.single?.id, activeRef.count == 1 ? activeRef[0].id : nil)
    }
}
