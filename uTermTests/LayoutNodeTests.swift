import XCTest
@testable import uTerm

final class LayoutNodeTests: XCTestCase {
    func testLeafIDs() {
        let a = UUID(), b = UUID()
        let node = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        XCTAssertEqual(Set(node.leafIDs), [a, b])
    }

    func testFirstLeafID() {
        let a = UUID(), b = UUID()
        let node = LayoutNode.split(SplitNode(
            id: UUID(), direction: .vertical, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        XCTAssertEqual(node.firstLeafID, a)
    }

    func testSplittingALeafReplacesItWithASplit() {
        let a = UUID(), b = UUID(), splitID = UUID()
        let tree = LayoutNode.leaf(paneID: a)
        let result = tree.splitting(paneID: a, direction: .vertical,
                                    newPaneID: b, splitID: splitID)
        guard case .split(let s) = result else { return XCTFail("应为 split") }
        XCTAssertEqual(s.id, splitID)
        XCTAssertEqual(s.direction, .vertical)
        XCTAssertEqual(s.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s.first, .leaf(paneID: a))
        XCTAssertEqual(s.second, .leaf(paneID: b))
    }

    func testSplittingANestedLeaf() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        let result = tree.splitting(paneID: b, direction: .horizontal,
                                    newPaneID: c, splitID: UUID())
        XCTAssertEqual(Set(result.leafIDs), [a, b, c])
    }

    func testRemovingALeafPromotesSibling() {
        let a = UUID(), b = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        let result = tree.removingLeaf(paneID: a)
        XCTAssertEqual(result, .leaf(paneID: b))
    }

    func testRemovingTheOnlyLeafReturnsNil() {
        let a = UUID()
        XCTAssertNil(LayoutNode.leaf(paneID: a).removingLeaf(paneID: a))
    }

    func testRemovingNestedLeaf() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a),
            second: .split(SplitNode(
                id: UUID(), direction: .vertical, fraction: 0.5,
                first: .leaf(paneID: b), second: .leaf(paneID: c)))))
        let result = tree.removingLeaf(paneID: b)
        XCTAssertEqual(Set((result ?? .leaf(paneID: a)).leafIDs), [a, c])
    }

    func testSettingFraction() {
        let a = UUID(), b = UUID(), splitID = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: splitID, direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        let result = tree.settingFraction(0.3, splitID: splitID)
        guard case .split(let s) = result else { return XCTFail("应为 split") }
        XCTAssertEqual(s.fraction, 0.3, accuracy: 0.0001)
    }

    func testSplittingWithNewLeafFirstPutsNewLeafFirst() {
        let a = UUID(), b = UUID(), splitID = UUID()
        let tree = LayoutNode.leaf(paneID: a)
        let result = tree.splitting(paneID: a, direction: .horizontal,
                                    newPaneID: b, splitID: splitID,
                                    newLeafFirst: true)
        guard case .split(let s) = result else { return XCTFail("应为 split") }
        XCTAssertEqual(s.first, .leaf(paneID: b))
        XCTAssertEqual(s.second, .leaf(paneID: a))
    }

    func testSwappingTwoLeavesExchangesThem() {
        let a = UUID(), b = UUID(), splitID = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: splitID, direction: .horizontal, fraction: 0.3,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        let result = tree.swapping(a, b)
        guard case .split(let s) = result else { return XCTFail("应为 split") }
        XCTAssertEqual(s.first, .leaf(paneID: b))
        XCTAssertEqual(s.second, .leaf(paneID: a))
        XCTAssertEqual(s.id, splitID)
        XCTAssertEqual(s.fraction, 0.3, accuracy: 0.0001)
    }

    func testSwappingPreservesNestedStructure() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a),
            second: .split(SplitNode(
                id: UUID(), direction: .vertical, fraction: 0.5,
                first: .leaf(paneID: b), second: .leaf(paneID: c)))))
        let result = tree.swapping(a, c)
        XCTAssertEqual(Set(result.leafIDs), [a, b, c])
        XCTAssertEqual(result.firstLeafID, c)
    }

    func testSwappingUnknownIDIsNoOp() {
        let a = UUID(), b = UUID()
        let tree = LayoutNode.split(SplitNode(
            id: UUID(), direction: .horizontal, fraction: 0.5,
            first: .leaf(paneID: a), second: .leaf(paneID: b)))
        XCTAssertEqual(tree.swapping(a, UUID()), tree)
    }

    func test_isSingleLeaf_trueForLeaf() {
        let node: LayoutNode = .leaf(paneID: UUID())
        XCTAssertTrue(node.isSingleLeaf)
    }

    func test_isSingleLeaf_falseForSplit() {
        let a = UUID(), b = UUID()
        let split = LayoutNode.leaf(paneID: a).splitting(
            paneID: a, direction: .horizontal,
            newPaneID: b, splitID: UUID())
        XCTAssertFalse(split.isSingleLeaf)
    }
}
