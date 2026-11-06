import SwiftUI
import XCTest
@testable import uTerm

@MainActor
final class PreferenceBindingTests: XCTestCase {
    private final class Box {
        var value: String
        init(_ value: String) { self.value = value }
    }

    private func binding(_ box: Box) -> Binding<String> {
        Binding(get: { box.value }, set: { box.value = $0 })
    }

    func testReadsKnownRawValue() {
        let box = Box(SSHHostKeyPolicy.strict.rawValue)
        XCTAssertEqual(binding(box).rawValue(SSHHostKeyPolicy.self, default: .ask).wrappedValue, .strict)
    }

    func testUnknownOrEmptyFallsBackToDefault() {
        XCTAssertEqual(binding(Box("garbage")).rawValue(SSHHostKeyPolicy.self, default: .ask).wrappedValue, .ask)
        XCTAssertEqual(binding(Box("")).rawValue(LogLevel.self, default: .info).wrappedValue, .info)
    }

    func testWritesRawValueBack() {
        let box = Box("garbage")
        let enumBinding = binding(box).rawValue(AppearancePreference.self, default: .system)
        enumBinding.wrappedValue = .dark
        XCTAssertEqual(box.value, AppearancePreference.dark.rawValue)
        XCTAssertEqual(enumBinding.wrappedValue, .dark)
    }
}
