import XCTest
@testable import uTerm

final class TelemetryParserTests: XCTestCase {

    /// 一台典型 Linux 主机的合并命令输出。
    private let linuxOutput = """
    __UT_OS__
    Linux
    __UT_REL__
    NAME="Ubuntu"
    PRETTY_NAME="Ubuntu 22.04.3 LTS"
    VERSION_ID="22.04"
    __UT_UP__
    4070160.42 12345678.90
    __UT_LOAD__
    0.42 0.51 0.48 1/234 5678
    __UT_STAT__
    cpu  100 0 50 1000 30 0 5 0 0 0
    __UT_NPROC__
    8
    __UT_MEM__
    MemTotal:        4030788 kB
    MemFree:          100000 kB
    MemAvailable:    2821551 kB
    __UT_DISK__
    /dev/sda1 206292512 43370112 152402000 22% /
    __UT_TIME__
    1716643328
    __UT_END__
    """

    func testParseLinuxAllFields() {
        let s = TelemetryParser.parse(linuxOutput)
        XCTAssertEqual(s.osName, "Linux")
        XCTAssertEqual(s.prettyName, "Ubuntu 22.04.3 LTS")
        XCTAssertEqual(s.uptimeSeconds ?? 0, 4070160.42, accuracy: 0.01)
        XCTAssertEqual(s.load1 ?? 0, 0.42, accuracy: 0.001)
        // idle(1000) + iowait(30) = 1030；total = 所有 jiffies 之和 = 1185
        XCTAssertEqual(s.cpuIdle, 1030)
        XCTAssertEqual(s.cpuTotal, 1185)
        XCTAssertEqual(s.cores, 8)
        XCTAssertEqual(s.memTotalKB, 4_030_788)
        XCTAssertEqual(s.memAvailableKB, 2_821_551)
        XCTAssertEqual(s.diskTotalKB, 206_292_512)
        XCTAssertEqual(s.diskUsedKB, 43_370_112)
        XCTAssertEqual(s.diskPercent, 22)
        XCTAssertEqual(s.epoch, 1_716_643_328)
        XCTAssertTrue(s.isLinux)
    }

    func testParseNonLinuxDegradesGracefully() {
        let output = """
        __UT_OS__
        Darwin
        __UT_REL__
        __UT_UP__
        __UT_LOAD__
        __UT_STAT__
        __UT_NPROC__
        __UT_MEM__
        __UT_DISK__
        __UT_TIME__
        1716643328
        __UT_END__
        """
        let s = TelemetryParser.parse(output)
        XCTAssertEqual(s.osName, "Darwin")
        XCTAssertNil(s.uptimeSeconds)
        XCTAssertNil(s.cpuTotal)
        XCTAssertNil(s.memTotalKB)
        XCTAssertNil(s.diskUsedKB)
        XCTAssertEqual(s.epoch, 1_716_643_328)   // 非 /proc 字段仍可取
        XCTAssertFalse(s.isLinux)
    }

    func testParseEmptyOutput() {
        let s = TelemetryParser.parse("")
        XCTAssertNil(s.osName)
        XCTAssertNil(s.cpuTotal)
        XCTAssertFalse(s.isLinux)
    }

    func testCPUPercentBaselineIsNil() {
        // 首次采样（无 prev）不应给出百分比。
        XCTAssertNil(TelemetryParser.cpuPercent(
            prevIdle: nil, prevTotal: nil, idle: 1030, total: 1185))
    }

    func testCPUPercentDelta() {
        // dTotal = 85, dIdle = 30 → usage = (1 - 30/85) * 100 ≈ 64.7%
        let pct = TelemetryParser.cpuPercent(
            prevIdle: 1000, prevTotal: 1100, idle: 1030, total: 1185)
        XCTAssertEqual(pct ?? -1, 64.705, accuracy: 0.01)
    }

    func testCPUPercentClampsAndGuards() {
        // total 未推进 → nil（避免除零 / 负数）。
        XCTAssertNil(TelemetryParser.cpuPercent(
            prevIdle: 1000, prevTotal: 1185, idle: 1030, total: 1185))
    }
}
