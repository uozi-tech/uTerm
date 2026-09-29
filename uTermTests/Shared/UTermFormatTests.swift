import XCTest
import UDesignKit
@testable import uTerm

/// `UTermFormat`：UFormat 没覆盖的几种写法（uptime / ETA / 进度 / 日期 / 相对时间兜底）。
final class UTermFormatTests: XCTestCase {

    func testUptimeTruncatesAndPadsMinutes() {
        XCTAssertEqual(UTermFormat.uptime(seconds: 59), "0m")
        XCTAssertEqual(UTermFormat.uptime(seconds: 12 * 60 + 59), "12m")
        XCTAssertEqual(UTermFormat.uptime(seconds: 3 * 3600 + 5 * 60), "3h 05m")
        XCTAssertEqual(UTermFormat.uptime(seconds: 47 * 86_400 + 16 * 3600 + 59 * 60), "47d 16h")
        XCTAssertEqual(UTermFormat.uptime(seconds: -1), UFormat.placeholder)
        XCTAssertEqual(UTermFormat.uptime(seconds: .nan), UFormat.placeholder)
    }

    func testETARoundsBeforeSplitting() {
        // 59.6 秒：旧实现先判 <60 再舍入 → 「剩余 60 秒」。
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 596, bytesPerSecond: 10), "剩余 1m 00s")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 420, bytesPerSecond: 10), "剩余 42 s")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 1255, bytesPerSecond: 10), "剩余 2m 06s")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 37_200, bytesPerSecond: 10), "剩余 1h 02m")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 5, bytesPerSecond: 10), "即将完成")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 0, bytesPerSecond: 0), "即将完成")
        XCTAssertEqual(UTermFormat.eta(remainingBytes: 100, bytesPerSecond: 0), UFormat.placeholder)
    }

    func testTransferRate() {
        XCTAssertEqual(UTermFormat.transferRate(0), UFormat.placeholder)
        XCTAssertEqual(UTermFormat.transferRate(1536), "1.50 KB/s")
        // 1024 进制（旧实现走 ByteCountFormatter .file = 1000 进制）。
        XCTAssertEqual(UTermFormat.transferRate(1_048_576), "1.00 MB/s")
    }

    func testProgressFloorsAndClamps() {
        XCTAssertEqual(UTermFormat.progress(0), "0%")
        XCTAssertEqual(UTermFormat.progress(0.29), "29%")       // 0.29*100 = 28.999…
        XCTAssertEqual(UTermFormat.progress(0.999), "99%")      // 没传完不显示 100%
        XCTAssertEqual(UTermFormat.progress(1), "100%")
        XCTAssertEqual(UTermFormat.progress(1.03), "100%")
        XCTAssertEqual(UTermFormat.progressFraction(done: 103, total: 100), 1)
        XCTAssertEqual(UTermFormat.progressFraction(done: 5, total: 0), 0)
        XCTAssertEqual(UTermFormat.progress(UTermFormat.progressFraction(done: 29, total: 100)), "29%")
    }

    func testDateIsGregorianAndFixedWidth() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var g = Calendar(identifier: .gregorian)
        g.timeZone = tz
        let d = g.date(from: DateComponents(year: 2026, month: 9, day: 8, hour: 23, minute: 59))!
        XCTAssertEqual(UTermFormat.date(d, timeZone: tz), "2026-09-08")
    }

    func testRelativeFallback() {
        let now = Date()
        XCTAssertEqual(UTermFormat.relative(nil), "从未")
        XCTAssertEqual(UTermFormat.relative(nil, fallback: "从未连接"), "从未连接")
        XCTAssertEqual(UTermFormat.relative(now.addingTimeInterval(-30), now: now), "刚刚")
        XCTAssertEqual(UTermFormat.relative(now.addingTimeInterval(-180), now: now), "3 分钟前")
    }
}
