import XCTest
import SwiftUI
@testable import uTerm

final class StatusBarViewTests: XCTestCase {
    func testCPULoadSummaryIncludesLoadCoresAndCPU() {
        XCTAssertEqual(
            StatusBarView.cpuLoadSummary(load: "0.42", cpuPercent: 64, cores: 8),
            "负载 0.42 · 8 核 · CPU 64%"
        )
    }

    func testCPULoadSummaryFallsBackWhenCoresAreMissing() {
        XCTAssertEqual(
            StatusBarView.cpuLoadSummary(load: "0.42", cpuPercent: 64, cores: nil),
            "负载 0.42 · CPU 64%"
        )
    }

    @MainActor
    func testTransferStatusIconUsesFixedCenteredFrame() {
        let chipHeight = SFTPTransfersDockLayout.statusChipHeight
        let iconFrame = SFTPTransfersDockLayout.statusIconFrame

        XCTAssertEqual(chipHeight, 22)
        XCTAssertEqual(iconFrame.height, chipHeight)
        XCTAssertEqual(iconFrame.width, 12)
    }

    @MainActor
    func testTransferStatusIconNudgesArrowToVisualCenter() {
        let arrowYOffset = SFTPTransfersDockLayout.statusArrowYOffset

        XCTAssertGreaterThan(arrowYOffset, 0)
        XCTAssertLessThanOrEqual(arrowYOffset, 1)
    }
}
