import SwiftData
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 已知主机指纹页：左滑删除只在 `List` 里生效，所以这里钉的是它真的是列表、数据变了会跟。
/// 滑动手势本身合成不了，走不到确认框。
@MainActor
final class FingerprintsListTests: XCTestCase {
    private func collectionView(in view: UIView) -> UICollectionView? {
        if let list = view as? UICollectionView { return list }
        for child in view.subviews {
            if let found = collectionView(in: child) { return found }
        }
        return nil
    }

    func testRowsAreInASwipeableListAndFollowTheStore() async throws {
        defer { MobileProbeWindow.closeAll() }
        let container = try MobileFixtures.emptyContainer()
        let known = KnownHost()
        known.host = "10.0.0.1"
        known.keyTypeRaw = "ssh-ed25519"
        known.fingerprint = "SHA256:abc"
        container.mainContext.insert(known)
        try container.mainContext.save()

        let (window, _) = MobileProbeWindow.make(size: CGSize(width: 390, height: 700), placement: .visibleOnScreen,
                                                 rootView: NavigationStack { FingerprintsView() }.modelContainer(container))
        try await Task.sleep(for: .milliseconds(500))
        let list = try XCTUnwrap(collectionView(in: window), "swipeActions 只在 List 里生效")
        XCTAssertEqual(list.numberOfItems(inSection: 0), 1)

        container.mainContext.delete(known)
        try container.mainContext.save()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertNil(collectionView(in: window), "删光了显示空状态")
    }
}
