import XCTest
@testable import uTerm

final class ExternalEditChangeDetectorTests: XCTestCase {
    private func fp(_ second: TimeInterval, size: Int64 = 10, inode: UInt64 = 1) -> LocalFileFingerprint {
        LocalFileFingerprint(modificationDate: Date(timeIntervalSince1970: second), size: size, inode: inode)
    }

    func testUnchangedFileNeverUploads() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        for _ in 0..<5 { XCTAssertEqual(detector.observe(fp(0)), .idle) }
    }

    func testUploadsOnlyAfterSameNewFingerprintSeenTwice() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        XCTAssertEqual(detector.observe(fp(5)), .settling)
        XCTAssertEqual(detector.observe(fp(5)), .upload(fp(5)))
    }

    func testStillWritingKeepsSettling() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        XCTAssertEqual(detector.observe(fp(5, size: 100)), .settling)
        XCTAssertEqual(detector.observe(fp(5, size: 200)), .settling, "还在长 —— 别传半截")
        XCTAssertEqual(detector.observe(fp(5, size: 200)), .upload(fp(5, size: 200)))
    }

    func testAtomicSaveDetectedByInodeEvenWithSameTimeAndSize() {
        var detector = ExternalEditChangeDetector(synced: fp(0, inode: 1))
        XCTAssertEqual(detector.observe(fp(0, inode: 2)), .settling)
        XCTAssertEqual(detector.observe(fp(0, inode: 2)), .upload(fp(0, inode: 2)))
    }

    func testMissingFileMidRenameDoesNotUploadOrResetPending() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        XCTAssertEqual(detector.observe(fp(5)), .settling)
        XCTAssertEqual(detector.observe(nil), .settling)
        XCTAssertEqual(detector.observe(fp(5)), .upload(fp(5)))
    }

    func testMarkSyncedStopsFurtherUploads() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        _ = detector.observe(fp(5))
        _ = detector.observe(fp(5))
        detector.markSynced(fp(5))
        XCTAssertEqual(detector.observe(fp(5)), .idle)
        XCTAssertFalse(detector.hasUnsyncedChanges(current: fp(5)))
    }

    func testPostponedVersionIsNotRetriedUntilFileChangesAgain() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        _ = detector.observe(fp(5))
        _ = detector.observe(fp(5))
        detector.postpone(fp(5))  // 上传失败 / 用户点了「暂不上传」
        for _ in 0..<3 { XCTAssertEqual(detector.observe(fp(5)), .idle) }
        XCTAssertTrue(detector.hasUnsyncedChanges(current: fp(5)))

        // 再存一次盘 → 按新改动处理。
        XCTAssertEqual(detector.observe(fp(9)), .settling)
        XCTAssertEqual(detector.observe(fp(9)), .upload(fp(9)))
    }

    func testClearPostponedAllowsManualRetry() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        detector.postpone(fp(5))
        detector.clearPostponed()
        XCTAssertEqual(detector.observe(fp(5)), .settling)
        XCTAssertEqual(detector.observe(fp(5)), .upload(fp(5)))
    }

    func testRevertingToSyncedContentClearsPostponed() {
        var detector = ExternalEditChangeDetector(synced: fp(0))
        detector.postpone(fp(5))
        XCTAssertEqual(detector.observe(fp(0)), .idle)
        XCTAssertFalse(detector.hasUnsyncedChanges(current: fp(0)))
    }

    func testFingerprintReadsRealFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerprint-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(LocalFileFingerprint.read(url))
        try Data("hello".utf8).write(to: url)
        let first = try XCTUnwrap(LocalFileFingerprint.read(url))
        XCTAssertEqual(first.size, 5)
        try Data("hello!".utf8).write(to: url, options: .atomic)  // rename 覆盖 → 新 inode
        let second = try XCTUnwrap(LocalFileFingerprint.read(url))
        XCTAssertNotEqual(first, second)
    }
}
