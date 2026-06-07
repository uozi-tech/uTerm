import SwiftUI
import AppKit
import XCTest
@testable import uTerm

final class UDInputFocusBehaviorTests: XCTestCase {
    @MainActor
    func testTextFieldDoesNotAutofocusByDefault() {
        let field = UDTextField(placeholder: "Host", text: .constant(""))

        XCTAssertFalse(field.autoFocus)
    }

    @MainActor
    func testSearchFieldDoesNotAutofocusByDefault() {
        let field = UDSearchField(text: .constant(""))

        XCTAssertFalse(field.autoFocus)
    }

    @MainActor
    func testInputsCanOptInToAutofocus() {
        let textField = UDTextField(placeholder: "Host",
                                    text: .constant(""),
                                    autoFocus: true)
        let searchField = UDSearchField(text: .constant(""), autoFocus: true)

        XCTAssertTrue(textField.autoFocus)
        XCTAssertTrue(searchField.autoFocus)
    }

    @MainActor
    func testInputFocusDismissesOnlyForOutsideClicksInSameWindow() {
        let inputWindow = NSWindow()
        let otherWindow = NSWindow()
        let inputFrame = NSRect(x: 20, y: 20, width: 160, height: 34)

        XCTAssertFalse(UDInputFocusDismissal.shouldDismissFocus(
            eventWindow: inputWindow,
            inputWindow: inputWindow,
            eventLocationInWindow: NSPoint(x: 40, y: 32),
            inputFrameInWindow: inputFrame
        ))

        XCTAssertTrue(UDInputFocusDismissal.shouldDismissFocus(
            eventWindow: inputWindow,
            inputWindow: inputWindow,
            eventLocationInWindow: NSPoint(x: 240, y: 32),
            inputFrameInWindow: inputFrame
        ))

        XCTAssertFalse(UDInputFocusDismissal.shouldDismissFocus(
            eventWindow: otherWindow,
            inputWindow: inputWindow,
            eventLocationInWindow: NSPoint(x: 240, y: 32),
            inputFrameInWindow: inputFrame
        ))
    }
}
