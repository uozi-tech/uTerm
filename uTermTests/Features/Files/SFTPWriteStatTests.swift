import XCTest
@testable import uTerm

final class SFTPWriteStatTests: XCTestCase {

    // MARK: - write → read round-trip

    func test_mockWriteThenRead_roundtrips() async throws {
        let mock = MockSFTP()
        let payload = Data("hello".utf8)
        try await mock.write("/x", data: payload)
        let result = try await mock.read("/x")
        XCTAssertEqual(result, payload)
    }

    // MARK: - stat 返回正确的 size 和 mtime

    func test_mockStat_returnsSizeAndMtime() async throws {
        let mock = MockSFTP()
        let payload = Data("12345".utf8)
        try await mock.write("/y", data: payload)
        let stat = try await mock.stat("/y")
        XCTAssertEqual(stat.size, 5)
        XCTAssertLessThanOrEqual(abs(stat.mtime.timeIntervalSinceNow), 1)
    }

    // MARK: - stat 文件不存在抛错

    func test_mockStat_missingFileThrows() async {
        let mock = MockSFTP()
        do {
            _ = try await mock.stat("/nope")
            XCTFail("应抛错")
        } catch {
            // 任何错误都算 pass
        }
    }
}
