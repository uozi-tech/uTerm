import SwiftUI
import XCTest
@testable import uTerm

/// 欢迎页主机行按 `ServerRowInfo` 判等：没变的行不重算，变了的必须重算。
@MainActor
final class ServerRowInfoTests: XCTestCase {
    private func profile() -> ServerProfile {
        let profile = ServerProfile()
        profile.name = "web-01"
        profile.host = "10.0.0.8"
        profile.port = 2222
        profile.username = "deploy"
        profile.group = "生产"
        return profile
    }

    private func row(_ profile: ServerProfile, query: String = "", isSelected: Bool = false) -> ServerRow {
        ServerRow(profile: profile, query: query, isSelected: isSelected, groupColor: nil,
                  onTap: {}, onDoubleTap: {})
    }

    func testCopiesWhatTheRowShows() {
        let source = profile()
        let info = ServerRowInfo(source)
        XCTAssertEqual(info.id, source.id)
        XCTAssertEqual(info.name, "web-01")
        XCTAssertEqual(info.displayEndpoint, "deploy@10.0.0.8")
        XCTAssertEqual(info.monogram, "W")
        XCTAssertEqual(info.groupLabel, "生产")
        XCTAssertEqual(info.reachabilityKey, HostEndpointKey(host: "10.0.0.8", port: 2222))
    }

    /// 列表被 iCloud 合并叫醒、值没变：两行相等，不重算。
    func testUnchangedProfileGivesEqualRows() {
        let source = profile()
        XCTAssertEqual(row(source), row(source))
    }

    /// 行上看得到的每一项变了（含搜索词高亮、选中态），都不能被判成相等。
    func testEveryVisibleChangeBreaksEquality() {
        let source = profile()
        let before = row(source)
        let edits: [(String, (ServerProfile) -> Void)] = [
            ("名字", { $0.name = "web-02" }),
            ("地址", { $0.host = "10.0.0.9" }),
            ("端口", { $0.port = 22 }),
            ("用户", { $0.username = "root" }),
            ("分组", { $0.group = nil }),
            ("置顶", { $0.isPinned = true }),
            ("上次连接", { $0.lastConnectedAt = Date() }),
            ("跳板机", { $0.jumpHost = ServerProfile() }),
        ]
        func edited(_ edit: (ServerProfile) -> Void) -> ServerProfile {
            let copy = profile()
            copy.id = source.id
            edit(copy)
            return copy
        }
        XCTAssertEqual(row(edited { _ in }), before, "同一台主机、字段没变")
        for (label, edit) in edits {
            XCTAssertNotEqual(row(edited(edit)), before, label)
        }
        XCTAssertNotEqual(row(source, query: "web"), before, "搜索词")
        XCTAssertNotEqual(row(source, isSelected: true), before, "选中")
    }
}
