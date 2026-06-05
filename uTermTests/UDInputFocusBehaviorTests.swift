import SwiftUI
import XCTest
@testable import uTerm

final class UDInputFocusBehaviorTests: XCTestCase {
    func testTextFieldDoesNotAutofocusByDefault() {
        let field = UDTextField(placeholder: "Host", text: .constant(""))

        XCTAssertFalse(field.autoFocus)
    }

    func testSearchFieldDoesNotAutofocusByDefault() {
        let field = UDSearchField(text: .constant(""))

        XCTAssertFalse(field.autoFocus)
    }

    func testInputsCanOptInToAutofocus() {
        let textField = UDTextField(placeholder: "Host",
                                    text: .constant(""),
                                    autoFocus: true)
        let searchField = UDSearchField(text: .constant(""), autoFocus: true)

        XCTAssertTrue(textField.autoFocus)
        XCTAssertTrue(searchField.autoFocus)
    }
}
