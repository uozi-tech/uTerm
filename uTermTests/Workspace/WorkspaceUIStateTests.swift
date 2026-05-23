import XCTest
import SwiftUI
@testable import uTerm

final class WorkspaceUIStateTests: XCTestCase {

    func test_defaultValues() {
        let s = WorkspaceUIState()
        XCTAssertEqual(s.leftSidebarVisibility, .all)
        XCTAssertTrue(s.rightInspectorPresented)
        XCTAssertEqual(s.previewTerminalRatio, 0.667, accuracy: 0.001)
    }

    func test_roundtripEncoding_allDefault() throws {
        let s = WorkspaceUIState()
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(WorkspaceUIState.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_roundtripEncoding_customValues() throws {
        var s = WorkspaceUIState()
        s.leftSidebarVisibility = .detailOnly
        s.rightInspectorPresented = false
        s.previewTerminalRatio = 0.4
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(WorkspaceUIState.self, from: data)
        XCTAssertEqual(decoded, s)
    }

    func test_decoding_unknownVisibilityFallsBackToAll() throws {
        let json = #"""
        {"leftSidebarVisibility":"future_value","rightInspectorPresented":true,"previewTerminalRatio":0.667}
        """#.data(using: .utf8)!
        let s = try JSONDecoder().decode(WorkspaceUIState.self, from: json)
        XCTAssertEqual(s.leftSidebarVisibility, .all)
    }

    func test_decoding_missingFields_fallsBackToDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let s = try JSONDecoder().decode(WorkspaceUIState.self, from: json)
        XCTAssertEqual(s.leftSidebarVisibility, .all)
        XCTAssertTrue(s.rightInspectorPresented)
        XCTAssertEqual(s.previewTerminalRatio, 0.667, accuracy: 0.001)
    }

    func test_ratio_clampedToReasonableRange() {
        var s = WorkspaceUIState()
        s.previewTerminalRatio = -1
        XCTAssertGreaterThanOrEqual(s.previewTerminalRatio, 0.1)
        s.previewTerminalRatio = 5
        XCTAssertLessThanOrEqual(s.previewTerminalRatio, 0.9)
    }

    func test_workspaceSnapshot_includesUIState_roundtrip() throws {
        var ui = WorkspaceUIState()
        ui.leftSidebarVisibility = .detailOnly
        ui.rightInspectorPresented = false
        let snap = WorkspaceSnapshot(tabs: [], activeTabIndex: nil, uiState: ui)
        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        XCTAssertEqual(decoded.uiState?.leftSidebarVisibility, .detailOnly)
        XCTAssertEqual(decoded.uiState?.rightInspectorPresented, false)
    }

    func test_workspaceSnapshot_oldJSONWithoutUIState_decodesWithNil() throws {
        let json = #"""
        {"tabs":[],"activeTabIndex":null}
        """#.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertNil(snap.uiState)
    }
}
