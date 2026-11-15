import XCTest
@testable import uTerm

/// 贴图 / 粘贴进度（`PasteProgress` / `PasteProgressRelay` / `PasteProgressReporter`）的行为闸。
final class PasteProgressTests: XCTestCase {

    func testOverallIsMonotonicAcrossPhases() {
        let steps: [PasteProgress] = [
            PasteProgress(.reading), PasteProgress(.reading, fraction: 1),
            PasteProgress(.encoding), PasteProgress(.encoding, fraction: 1),
            .sending(0, of: 10), .sending(5, of: 10), .sending(10, of: 10),
            PasteProgress(.finishing), PasteProgress(.finishing, fraction: 1),
        ]
        let overall = steps.map(\.overall)
        XCTAssertEqual(overall, overall.sorted())
        XCTAssertEqual(overall.first, 0)
        XCTAssertEqual(overall.last, 1)
    }

    func testFractionIsClamped() {
        XCTAssertEqual(PasteProgress(.sending, fraction: 3).fraction, 1)
        XCTAssertEqual(PasteProgress(.sending, fraction: -1).fraction, 0)
        XCTAssertEqual(PasteProgress(.sending, fraction: .nan).fraction, 0)
        XCTAssertEqual(PasteProgress.sending(0, of: 0).fraction, 1, "空内容算发完")
    }

    func testNoteCarriesProgressWhileInFlight() {
        let note = PasteProgress.sending(1, of: 2).note
        XCTAssertNotNil(note.progress)
        XCTAssertNil(PasteNote(text: "已粘贴").progress, "结果提示不带进度条")
    }

    /// 同一段里不到 1% 的不送、往回退的不送；换段、到 100% 的照送。送到主线程时保持放行的先后。
    @MainActor
    func testRelayThrottlesAndDropsRegressions() async {
        let log = DeliveredLog()
        let done = expectation(description: "delivered")
        let relay = PasteProgressRelay { progress in
            log.items.append(progress)
            if progress.phase == .finishing { done.fulfill() }
        }
        DispatchQueue.global().async {
            relay.report(PasteProgress(.reading))
            relay.report(.sending(0, of: 10_000))
            for sent in stride(from: 1, through: 10_000, by: 1) { relay.report(.sending(sent, of: 10_000)) }
            relay.report(.sending(5_000, of: 10_000))
            relay.report(PasteProgress(.finishing))
        }
        await fulfillment(of: [done], timeout: 5)
        let delivered = log.items

        XCTAssertEqual(delivered.map(\.overall), delivered.map(\.overall).sorted(), "主线程上看到的不能往回走")
        XCTAssertLessThan(delivered.count, 120, "一万次上报应被压到一百来次")
        XCTAssertTrue(delivered.contains(.sending(10_000, of: 10_000)), "100% 必须送到")
        XCTAssertEqual(delivered.first, PasteProgress(.reading))
    }

    /// 进度经 task-local 往下传：跨 actor、进子任务都收得到；作用域外不报。
    func testReporterReachesThroughActorsAndChildTasks() async {
        actor Uploader {
            func upload() async {
                PasteProgressReporter.report(.sending(1, of: 2))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { PasteProgressReporter.report(.sending(2, of: 2)) }
                }
            }
        }
        let seen = Seen()
        await PasteProgressReporter.$sink.withValue({ seen.add($0) }) {
            await Uploader().upload()
        }
        PasteProgressReporter.report(PasteProgress(.finishing))
        XCTAssertEqual(seen.all, [.sending(1, of: 2), .sending(2, of: 2)])
    }
}

@MainActor
private final class DeliveredLog {
    var items: [PasteProgress] = []
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [PasteProgress] = []
    func add(_ item: PasteProgress) { lock.withLock { items.append(item) } }
    var all: [PasteProgress] { lock.withLock { items } }
}
