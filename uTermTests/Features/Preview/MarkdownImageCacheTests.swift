import XCTest
@testable import uTerm

final class MarkdownImageCacheTests: XCTestCase {
    private func data(_ count: Int, fill: UInt8 = 0xAB) -> Data {
        Data(repeating: fill, count: count)
    }

    func testStoresAndRetrievesEntry() {
        var cache = MarkdownImageCache()
        let blob = data(1_000)

        XCTAssertTrue(cache.insert(blob, forKey: "a"))
        XCTAssertEqual(cache["a"], blob)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 1_000)
    }

    func testRejectsEntryOverPerImageCap() {
        var cache = MarkdownImageCache(perImageByteCap: 100,
                                       totalByteCap: 10_000,
                                       maxEntryCount: 100)

        XCTAssertFalse(cache.insert(data(101), forKey: "big"))
        XCTAssertNil(cache["big"])
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
    }

    func testAcceptsEntryExactlyAtPerImageCap() {
        var cache = MarkdownImageCache(perImageByteCap: 100,
                                       totalByteCap: 10_000,
                                       maxEntryCount: 100)

        XCTAssertTrue(cache.insert(data(100), forKey: "edge"))
        XCTAssertEqual(cache.count, 1)
    }

    func testEvictsOldestWhenTotalByteCapExceeded() {
        var cache = MarkdownImageCache(perImageByteCap: 1_000,
                                       totalByteCap: 250,
                                       maxEntryCount: 100)

        cache.insert(data(100), forKey: "a")
        cache.insert(data(100), forKey: "b")
        cache.insert(data(100), forKey: "c") // total would be 300 > 250 → evict "a"

        XCTAssertNil(cache["a"], "oldest entry should be evicted")
        XCTAssertEqual(cache["b"], data(100))
        XCTAssertEqual(cache["c"], data(100))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.totalBytes, 200)
        XCTAssertLessThanOrEqual(cache.totalBytes, 250)
    }

    func testEvictsOldestWhenEntryCountCapExceeded() {
        var cache = MarkdownImageCache(perImageByteCap: 1_000,
                                       totalByteCap: 1_000_000,
                                       maxEntryCount: 2)

        cache.insert(data(10), forKey: "a")
        cache.insert(data(10), forKey: "b")
        cache.insert(data(10), forKey: "c") // count would be 3 > 2 → evict "a"

        XCTAssertNil(cache["a"])
        XCTAssertNotNil(cache["b"])
        XCTAssertNotNil(cache["c"])
        XCTAssertEqual(cache.count, 2)
    }

    func testReinsertingSameKeyUpdatesValueWithoutGrowingCount() {
        var cache = MarkdownImageCache(perImageByteCap: 1_000,
                                       totalByteCap: 1_000_000,
                                       maxEntryCount: 100)

        cache.insert(data(50, fill: 0x01), forKey: "k")
        cache.insert(data(80, fill: 0x02), forKey: "k")

        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.totalBytes, 80)
        XCTAssertEqual(cache["k"], data(80, fill: 0x02))
    }

    func testReinsertingExistingKeyRefreshesEvictionOrder() {
        var cache = MarkdownImageCache(perImageByteCap: 1_000,
                                       totalByteCap: 1_000_000,
                                       maxEntryCount: 2)

        cache.insert(data(10), forKey: "a")
        cache.insert(data(10), forKey: "b")
        cache.insert(data(10), forKey: "a") // "a" becomes most-recent
        cache.insert(data(10), forKey: "c") // count > 2 → evict oldest, now "b"

        XCTAssertNotNil(cache["a"], "re-inserted key should not be the eviction victim")
        XCTAssertNil(cache["b"])
        XCTAssertNotNil(cache["c"])
        XCTAssertEqual(cache.count, 2)
    }

    func testRemoveAllResetsState() {
        var cache = MarkdownImageCache()
        cache.insert(data(100), forKey: "a")
        cache.insert(data(100), forKey: "b")

        cache.removeAll()

        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.totalBytes, 0)
        XCTAssertNil(cache["a"])
    }

    func testDefaultCapsAreSane() {
        // Per-image cap is stricter than the 50 MB main-file guard, and the
        // total cap bounds aggregate growth.
        XCTAssertLessThan(MarkdownImageCache.perImageByteCap, 50 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(MarkdownImageCache.totalByteCap,
                                    MarkdownImageCache.perImageByteCap)
        XCTAssertGreaterThan(MarkdownImageCache.maxEntryCount, 0)
    }
}
