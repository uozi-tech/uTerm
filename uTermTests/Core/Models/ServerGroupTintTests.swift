import SwiftUI
import XCTest
@testable import uTerm

@MainActor
final class ServerGroupTintTests: XCTestCase {

    func testColorsMapsEveryGroupNameToItsHex() {
        let groups = [
            ServerGroup(name: "prod", colorHex: "#f87171"),
            ServerGroup(name: "dev", colorHex: "#60a5fa"),
        ]
        let colors = ServerGroupTint.colors(for: groups)
        XCTAssertEqual(colors.count, 2)
        XCTAssertEqual(colors["prod"], ServerGroupTint.color(hex: "#f87171"))
        XCTAssertEqual(colors["dev"], ServerGroupTint.color(hex: "#60a5fa"))
    }

    func testColorsKeepsFirstGroupWhenNamesCollide() {
        let groups = [
            ServerGroup(name: "prod", colorHex: "#f87171"),
            ServerGroup(name: "prod", colorHex: "#60a5fa"),
        ]
        XCTAssertEqual(ServerGroupTint.colors(for: groups)["prod"],
                       ServerGroupTint.color(hex: "#f87171"))
    }

    func testLookupReturnsNilForMissingOrEmptyGroup() {
        let colors = ["prod": ServerGroupTint.color(hex: "#f87171")]
        XCTAssertNil(ServerGroupTint.color(for: nil, colors: colors))
        XCTAssertNil(ServerGroupTint.color(for: "", colors: colors))
        XCTAssertNil(ServerGroupTint.color(for: "staging", colors: colors))
        XCTAssertEqual(ServerGroupTint.color(for: "prod", colors: colors), colors["prod"])
    }

    func testHexColorMatchesSRGBComponentsAndModelColor() {
        XCTAssertEqual(ServerGroupTint.color(hex: "#f87171"),
                       Color(.sRGB, red: 248.0 / 255, green: 113.0 / 255, blue: 113.0 / 255))
        XCTAssertEqual(ServerGroup(name: "x", colorHex: "60a5fa").color,
                       ServerGroupTint.color(hex: "#60a5fa"))
        // 非法输入回退中性灰 #9aa7b5
        XCTAssertEqual(ServerGroupTint.color(hex: "not-a-hex"), ServerGroupTint.color(hex: "#9aa7b5"))
    }
}
