import UPaneGroups
import UPaneTree
import XCTest
@testable import uTerm

/// 终端区持久化（P4）：新格式往返 + 老格式迁移 + 损坏快照的兜底。
///
/// 新格式 = `WorkspaceSnapshot.terminalGroups`：一棵组树 + 每组的标签列表 +
/// 每组 `activeIndex` + 活动组。老格式 = `tabs: [TabSnapshot]`，每个窗口级标签
/// 一棵窗格树，新模型表达不了，按设计文档 §4.2 的 M2 规则迁移。
@MainActor
final class TerminalGroupsPersistenceTests: XCTestCase {

    // MARK: 形状签名 —— 不含 UUID，可以逐项断言分屏形状 / fraction / 标签顺序

    /// 一棵组树摊成「树形 + 每组的标签标题序列」。组 id 与分屏节点 id 每次恢复都会
    /// 重新铸造，直接比 `LayoutNode` 永远不相等，所以比签名。
    indirect enum GroupShape: Equatable {
        /// 一个组：它的标签标题按顺序 + 前台标签下标。
        case group(titles: [String], active: Int)
        case split(SplitDirection, Double, GroupShape, GroupShape)
    }

    func shape(of model: UPaneGroupsModel<PaneModel>) -> GroupShape {
        func walk(_ node: LayoutNode) -> GroupShape {
            switch node {
            case .leaf(let paneID):
                let group = model.groups[paneID]
                return .group(titles: group?.tabs.map { $0.customTitle ?? "" } ?? [],
                              active: group?.activeIndex ?? -1)
            case .split(let s):
                return .split(s.direction, s.fraction, walk(s.first), walk(s.second))
            }
        }
        return walk(model.root)
    }

    func shape(of snapshot: TerminalGroupsSnapshot) -> GroupShape {
        func walk(_ node: TerminalGroupsSnapshot.Node) -> GroupShape {
            switch node {
            case .leaf(let groupIndex):
                guard snapshot.groups.indices.contains(groupIndex) else {
                    return .group(titles: ["<越界>"], active: -1)
                }
                let group = snapshot.groups[groupIndex]
                return .group(titles: group.tabs.map(\.title), active: group.activeIndex)
            case .split(let direction, let fraction, let first, let second):
                return .split(direction, fraction, walk(first), walk(second))
            }
        }
        return walk(snapshot.root)
    }

    /// 树里所有 split 节点的 id，深度优先 —— 测试要靠它调 `setFraction`。
    func splitIDs(of node: LayoutNode) -> [UUID] {
        guard case .split(let s) = node else { return [] }
        return [s.id] + splitIDs(of: s.first) + splitIDs(of: s.second)
    }

    /// 2×2 四宫格：外层横分，两侧各自纵分。四个 fraction 全部取非默认值。
    func quadSplit(_ a: UUID, _ b: UUID, _ c: UUID, _ d: UUID) -> NodeSnapshot {
        .split(direction: .horizontal, fraction: 0.35,
               first: .split(direction: .vertical, fraction: 0.62,
                             first: .leaf(serverProfileID: a),
                             second: .leaf(serverProfileID: b)),
               second: .split(direction: .vertical, fraction: 0.28,
                              first: .leaf(serverProfileID: c),
                              second: .leaf(serverProfileID: d)))
    }

    // MARK: 新格式往返

    /// 多组 + 每组多标签 + 非默认 fraction + 非零 activeIndex → 逐项相等。
    func testNewFormatRoundTripPreservesShapeFractionsOrderAndActiveTab() {
        let ws = WorkspaceModel()
        let s1 = UUID(), s2 = UUID(), s3 = UUID(), s4 = UUID()
        ws.openServer(profileID: s1, title: "组1标签1")
        ws.splitActiveGroup(direction: .vertical)          // 开出第二个组
        ws.splitActiveGroup(direction: .horizontal)        // 再开第三个组
        guard let g3 = ws.terminalGroups.activeGroupID,
              let g1 = ws.terminalGroups.groupIDs.first else {
            return XCTFail("应该有三个组")
        }
        XCTAssertEqual(ws.terminalGroups.groupCount, 3)

        // 第一个组三个标签，前台停在中间那个（非零 activeIndex）。
        ws.openServer(profileID: s2, title: "组1标签2", in: g1)
        ws.openServer(profileID: s3, title: "组1标签3", in: g1)
        ws.terminalGroups.activateTab(groupID: g1, index: 1)
        // 最后一个组再加一个标签，并把活动组停在它身上。
        ws.openServer(profileID: s4, title: "组3标签2", in: g3)

        // 两个 split 都改成非默认 fraction。
        let splits = splitIDs(of: ws.terminalGroups.root)
        XCTAssertEqual(splits.count, 2)
        ws.terminalGroups.setFraction(0.27, splitID: splits[0])
        ws.terminalGroups.setFraction(0.73, splitID: splits[1])

        let before = shape(of: ws.terminalGroups)
        let activeTitleBefore = ws.terminalGroups.activeTab?.customTitle
        let activeServerBefore = ws.terminalGroups.activeTab?.payload.serverProfileID

        let snap = ws.snapshot()
        XCTAssertNotNil(snap.terminalGroups, "新格式必须写进快照")
        let restored = WorkspaceModel(snapshot: snap)

        XCTAssertEqual(shape(of: restored.terminalGroups), before,
                       "分屏形状 / fraction / 每组标签顺序 / 每组前台标签必须逐项还原")
        XCTAssertEqual(restored.terminalGroups.groupCount, 3)
        // 3（第一个组）+ 1（第一次分屏克隆出的）+ 2（第二次分屏克隆的 + 后开的）
        XCTAssertEqual(restored.terminalGroups.allTabs.count, 6)
        XCTAssertEqual(restored.terminalGroups.allTabs.map(\.payload.serverProfileID),
                       ws.terminalGroups.allTabs.map(\.payload.serverProfileID))
        XCTAssertEqual(restored.terminalGroups.activeTab?.customTitle, activeTitleBefore)
        XCTAssertEqual(restored.terminalGroups.activeTab?.payload.serverProfileID,
                       activeServerBefore)
    }

    /// 组树快照本身能过一遍 JSON，且解码后的形状不变。
    func testNewFormatSurvivesJSONEncoding() throws {
        let ws = WorkspaceModel()
        ws.openServer(profileID: UUID(), title: "a")
        ws.splitActiveGroup(direction: .vertical)
        ws.openServer(profileID: UUID(), title: "b")
        let splits = splitIDs(of: ws.terminalGroups.root)
        ws.terminalGroups.setFraction(0.31, splitID: splits[0])

        let data = try JSONEncoder().encode(ws.snapshot())
        let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
        let restored = WorkspaceModel(snapshot: decoded)
        XCTAssertEqual(shape(of: restored.terminalGroups), shape(of: ws.terminalGroups))
    }

    /// 老版本写的 JSON 没有 `terminalGroups` 键，解码后必须是 nil（走迁移），不能抛。
    func testLegacyJSONDecodesWithNilTerminalGroups() throws {
        let json = #"""
        {"tabs":[{"title":"uozi","layout":{"leaf":{"serverProfileID":"00000000-0000-0000-0000-0000000000A1","kind":"terminal"}}}],"activeTabIndex":0}
        """#.data(using: .utf8)!
        let snap = try JSONDecoder().decode(WorkspaceSnapshot.self, from: json)
        XCTAssertNil(snap.terminalGroups)
        XCTAssertEqual(snap.tabs.count, 1)
    }

    // MARK: 老格式迁移（设计文档 §4.2 的 M2）

    /// 活动标签是四宫格、另有两个标签各自单窗格：
    /// 活动标签的分屏形状保住、另外两个标签的窗格变成第一组里的标签、会话总数不变。
    func testMigrationKeepsActiveTabShapeAndFoldsOtherTabsIntoFirstGroup() {
        let q1 = UUID(), q2 = UUID(), q3 = UUID(), q4 = UUID()
        let before = UUID(), after = UUID()
        let tabs = [
            TabSnapshot(title: "前面那个", layout: .leaf(serverProfileID: before)),
            TabSnapshot(title: "四宫格", layout: quadSplit(q1, q2, q3, q4)),
            TabSnapshot(title: "后面那个", layout: .leaf(serverProfileID: after)),
        ]
        let migrated = WorkspaceSnapshot.migratingLegacyTabs(tabs, activeTabIndex: 1)

        XCTAssertEqual(shape(of: migrated), .split(.horizontal, 0.35,
            .split(.vertical, 0.62,
                   // 第一个组 = 活动标签 DFS 的第一个叶子；其余标签的窗格追加在后面。
                   .group(titles: ["四宫格", "前面那个", "后面那个"], active: 0),
                   .group(titles: ["四宫格"], active: 0)),
            .split(.vertical, 0.28,
                   .group(titles: ["四宫格"], active: 0),
                   .group(titles: ["四宫格"], active: 0))))
        XCTAssertEqual(migrated.activeGroupIndex, 0)

        // 会话一条不丢：迁移前后叶子总数相等。
        let leavesBefore = tabs.reduce(0) { $0 + $1.layout.leafServerIDs.count }
        let tabsAfter = migrated.groups.reduce(0) { $0 + $1.tabs.count }
        XCTAssertEqual(tabsAfter, leavesBefore)
        XCTAssertEqual(tabsAfter, 6)

        // 服务器身份也要对上（不能给谁回落成随机 UUID）。
        XCTAssertEqual(migrated.groups[0].tabs.map(\.serverProfileID), [q1, before, after])
        XCTAssertEqual(migrated.groups.dropFirst().flatMap { $0.tabs.map(\.serverProfileID) },
                       [q2, q3, q4])
    }

    /// 同一条迁移走完整的 `WorkspaceModel.restore`：模型里的组树也要保形。
    func testMigrationThroughRestoreProducesSameShapeInModel() {
        let q = (UUID(), UUID(), UUID(), UUID())
        let lone = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [
                TabSnapshot(title: "四宫格", layout: quadSplit(q.0, q.1, q.2, q.3)),
                TabSnapshot(title: "单窗格", layout: .leaf(serverProfileID: lone)),
            ],
            activeTabIndex: 0)
        let ws = WorkspaceModel(snapshot: snap)

        XCTAssertEqual(ws.terminalGroups.groupCount, 4, "活动标签的四宫格必须保住")
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 5, "会话一条不丢")
        XCTAssertEqual(shape(of: ws.terminalGroups), shape(of: snap.terminalGroupsForRestore))
        XCTAssertEqual(ws.terminalGroups.activeTab?.customTitle, "四宫格")
        XCTAssertEqual(ws.terminalGroups.activeTab?.payload.serverProfileID, q.0)
        XCTAssertEqual(ws.terminalGroups.allTabs.map(\.payload.serverProfileID),
                       [q.0, lone, q.1, q.2, q.3])
    }

    /// 迁移一次之后写回的是新格式，第二次重启不能再降级 —— P3 的退化是「每次重启
    /// 都把分屏拍平」，这条钉住它不再发生。
    func testMigratedLayoutSurvivesASecondRestart() {
        let q = (UUID(), UUID(), UUID(), UUID())
        let legacy = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "四宫格", layout: quadSplit(q.0, q.1, q.2, q.3))],
            activeTabIndex: 0)
        let first = WorkspaceModel(snapshot: legacy)
        let second = WorkspaceModel(snapshot: first.snapshot())
        let third = WorkspaceModel(snapshot: second.snapshot())
        XCTAssertEqual(third.terminalGroups.groupCount, 4)
        XCTAssertEqual(shape(of: third.terminalGroups), shape(of: first.terminalGroups))
    }

    /// 迁移仍要写旧键作为降级回滚通道：一个标签一条，layout 恒单叶。
    func testSnapshotStillWritesLegacyTabsForDowngrade() {
        let ws = WorkspaceModel()
        let s1 = UUID(), s2 = UUID()
        ws.openServer(profileID: s1, title: "a")
        ws.splitActiveGroup(direction: .vertical)
        ws.openServer(profileID: s2, title: "b")

        let snap = ws.snapshot()
        XCTAssertEqual(snap.tabs.count, ws.terminalGroups.allTabs.count,
                       "旧键一个标签一条，会话一条不丢")
        for tab in snap.tabs {
            guard case .leaf = tab.layout else {
                return XCTFail("降级写的 layout 必须是单叶")
            }
        }
        XCTAssertEqual(snap.tabs.map(\.title), ws.terminalGroups.allTabs.map { $0.customTitle ?? "" })
    }

    /// `activeTabIndex` 缺失 / 越界 / 为负时取第 0 个标签的形状，不能崩也不能空。
    func testMigrationFallsBackToFirstTabWhenActiveIndexIsUnusable() {
        let quad = quadSplit(UUID(), UUID(), UUID(), UUID())
        let tabs = [
            TabSnapshot(title: "第一个", layout: quad),
            TabSnapshot(title: "第二个", layout: .leaf(serverProfileID: UUID())),
        ]
        for bogus in [nil, 99, -1, 2] as [Int?] {
            let migrated = WorkspaceSnapshot.migratingLegacyTabs(tabs, activeTabIndex: bogus)
            XCTAssertEqual(migrated.groups.count, 4, "回落到第 0 个标签的四宫格：\(String(describing: bogus))")
            XCTAssertEqual(migrated.activeGroupIndex, 0)
            XCTAssertEqual(migrated.groups.reduce(0) { $0 + $1.tabs.count }, 5)
        }
    }

    // MARK: 迁移 + 白名单剪枝

    /// 老格式迁移与 `knownServerIDs` 白名单剪枝同时生效（旧 `pruningUnknownServers`
    /// 那条语义现在收在 `restore` 的 `make` 闭包里，对新老两种格式一视同仁）：
    /// 指向不存在服务器的标签丢掉 → 标签被丢光的组丢掉 → split 只剩一侧就上提。
    func testMigrationAndUnknownServerPruningTogether() {
        let live1 = UUID(), live2 = UUID()
        let dead1 = UUID(), dead2 = UUID(), dead3 = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [
                // 活动标签：四宫格，两活两死 → 剩下的两个组，外层 split 保留。
                TabSnapshot(title: "四宫格", layout: quadSplit(live1, dead1, dead2, live2)),
                // 另一个标签：整条都是死的 → 追加到第一个组后全被剪掉。
                TabSnapshot(title: "全死", layout: .leaf(serverProfileID: dead3)),
            ],
            activeTabIndex: 0)
        let ws = WorkspaceModel()
        ws.restore(from: snap, knownServerIDs: [live1, live2])

        XCTAssertEqual(ws.terminalGroups.allTabs.map(\.payload.serverProfileID), [live1, live2])
        XCTAssertEqual(ws.terminalGroups.groupCount, 2, "两个空掉的组塌缩，内层 split 上提")
        XCTAssertEqual(shape(of: ws.terminalGroups),
                       .split(.horizontal, 0.35,
                              .group(titles: ["四宫格"], active: 0),
                              .group(titles: ["四宫格"], active: 0)))
    }

    /// 白名单对**新格式**同样生效 —— 剪枝不是只给老快照用的迁移逻辑。
    /// 第二个组整组指向已删除的服务器：组丢掉、split 只剩一侧就上提。
    func testWhitelistPruningAppliesToNewFormatToo() {
        let live = UUID(), dead = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [], activeTabIndex: nil,
            terminalGroups: TerminalGroupsSnapshot(
                root: .split(direction: .horizontal, fraction: 0.4,
                             first: .leaf(groupIndex: 0),
                             second: .leaf(groupIndex: 1)),
                groups: [
                    TerminalGroupsSnapshot.Group(
                        tabs: [TerminalTabSnapshot(serverProfileID: live, title: "活的"),
                               TerminalTabSnapshot(serverProfileID: dead, title: "死的")],
                        activeIndex: 1),
                    TerminalGroupsSnapshot.Group(
                        tabs: [TerminalTabSnapshot(serverProfileID: dead, title: "整组都死")],
                        activeIndex: 0),
                ],
                activeGroupIndex: 1))

        let ws = WorkspaceModel()
        ws.restore(from: snap, knownServerIDs: [live])
        XCTAssertEqual(ws.terminalGroups.allTabs.map(\.payload.serverProfileID), [live])
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
        XCTAssertEqual(ws.terminalGroups.activeTab?.customTitle, "活的")
        XCTAssertEqual(ws.terminalGroups.activeGroupID, ws.terminalGroups.groupIDs.first,
                       "活动组指向被剪掉的组时回落到树的第一个叶子")
    }

    /// 全部服务器都不认识 → 整棵树剪光，回落到一个空组，由调用方兜底开新标签。
    func testPruningEverythingLeavesOneEmptyGroup() {
        let snap = WorkspaceSnapshot(
            tabs: [TabSnapshot(title: "坏的", layout: quadSplit(UUID(), UUID(), UUID(), UUID()))],
            activeTabIndex: 0)
        let ws = WorkspaceModel()
        ws.restore(from: snap, knownServerIDs: [UUID()])
        XCTAssertTrue(ws.terminalGroups.isEmpty)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
        XCTAssertNil(ws.terminalGroups.activeTab)
    }

    // MARK: 损坏 / 空 / 缺字段的快照

    func testEmptySnapshotRestoresToOneEmptyGroup() {
        let ws = WorkspaceModel()
        ws.restore(from: WorkspaceSnapshot(tabs: [], activeTabIndex: nil))
        XCTAssertTrue(ws.terminalGroups.isEmpty)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
        XCTAssertNotNil(ws.terminalGroups.activeGroupID)
    }

    /// 新格式里 `groups` 是空的、root 却引用了 groupIndex 0：不能崩，回落到空组。
    func testNewFormatWithDanglingGroupIndexDoesNotCrash() {
        let snap = WorkspaceSnapshot(
            tabs: [], activeTabIndex: nil,
            terminalGroups: TerminalGroupsSnapshot(root: .leaf(groupIndex: 0),
                                                   groups: [],
                                                   activeGroupIndex: 7))
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1)
        XCTAssertTrue(ws.terminalGroups.isEmpty)
    }

    /// 组的 `activeIndex` 越界 / 活动组下标越界 / split 引用不存在的组：全部要兜住。
    func testNewFormatWithOutOfRangeIndexesIsClamped() {
        let a = UUID(), b = UUID()
        let snap = WorkspaceSnapshot(
            tabs: [], activeTabIndex: nil,
            terminalGroups: TerminalGroupsSnapshot(
                root: .split(direction: .horizontal, fraction: 0.5,
                             first: .leaf(groupIndex: 0),
                             second: .leaf(groupIndex: 42)),
                groups: [
                    TerminalGroupsSnapshot.Group(
                        tabs: [TerminalTabSnapshot(serverProfileID: a, title: "一"),
                               TerminalTabSnapshot(serverProfileID: b, title: "二")],
                        activeIndex: 99),
                ],
                activeGroupIndex: -3))
        let ws = WorkspaceModel(snapshot: snap)
        XCTAssertEqual(ws.terminalGroups.groupCount, 1, "引用不到的一侧上提")
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 2)
        XCTAssertNotNil(ws.terminalGroups.activeGroupID)
        // activeIndex 越界时 `activeTab` 为 nil 而不是崩；活动组仍要落在树里。
        XCTAssertTrue(ws.terminalGroups.groupIDs.contains(ws.terminalGroups.activeGroupID!))
    }

    /// 半截 / 损坏的 JSON：`WorkspaceStore.load()` 返回 nil，不抛不崩。
    func testCorruptJSONLoadsAsNilInsteadOfCrashing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let serverID = UUID()
        let windowID = WorkspaceWindowID(serverID: serverID)
        let url = dir.appendingPathComponent("workspace-\(serverID.uuidString).json")

        // 半截 JSON（写盘被打断）。
        let full = #"{"tabs":[],"activeTabIndex":null,"terminalGroups":{"root":{"leaf":{"groupIndex":0}},"groups":[]}}"#
        for truncated in [String(full.prefix(40)), "", "{", "not json at all"] {
            try truncated.data(using: .utf8)!.write(to: url)
            XCTAssertNil(WorkspaceStore(windowID: windowID, directory: dir).load(),
                         "损坏快照必须解码失败并回落 nil：\(truncated)")
        }
    }

    // MARK: 真实老快照文件走完整落盘路径

    /// 一份形状照抄真实 pre-P3 `workspace-<serverID>.json` 的老快照（含 pane-types
    /// 时期才有的 `kind` 键），从磁盘 → `WorkspaceStore.load()` → `restore` 全程走一遍。
    func testRealLegacyJSONFileOnDiskMigratesEndToEnd() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let serverID = UUID(uuidString: "9E7C3296-A11E-4095-B337-FAA36CE74E0F")!
        let other = UUID(uuidString: "070FAC8D-B30D-48D8-9F7D-7860C558C9A9")!
        let windowID = WorkspaceWindowID(serverID: serverID)
        let json = """
        {
          "tabs": [
            {"title": "demo-server",
             "layout": {"leaf": {"kind": "terminal", "serverProfileID": "\(serverID.uuidString)"}}},
            {"title": "四宫格",
             "layout": {"split": {"direction": "horizontal", "fraction": 0.35,
               "first": {"split": {"direction": "vertical", "fraction": 0.62,
                 "first": {"leaf": {"kind": "terminal", "serverProfileID": "\(serverID.uuidString)"}},
                 "second": {"leaf": {"kind": "terminal", "serverProfileID": "\(other.uuidString)"}}}},
               "second": {"split": {"direction": "vertical", "fraction": 0.28,
                 "first": {"leaf": {"kind": "terminal", "serverProfileID": "\(serverID.uuidString)"}},
                 "second": {"leaf": {"kind": "files", "serverProfileID": "\(other.uuidString)"}}}}}}},
            {"title": "旁边那个",
             "layout": {"leaf": {"kind": "terminal", "serverProfileID": "\(other.uuidString)"}}}
          ],
          "activeTabIndex": 1,
          "uiState": {"inspectorWidth": 300, "leftSidebarVisibility": "all",
                      "sidebarWidth": 300, "previewTerminalRatio": 0.667,
                      "rightInspectorPresented": true}
        }
        """
        try json.data(using: .utf8)!
            .write(to: dir.appendingPathComponent("workspace-\(serverID.uuidString).json"))

        guard let loaded = WorkspaceStore(windowID: windowID, directory: dir).load() else {
            return XCTFail("真实老快照必须能解码")
        }
        XCTAssertNil(loaded.terminalGroups, "老文件没有新键")

        let ws = WorkspaceModel()
        ws.restore(from: loaded, knownServerIDs: [serverID, other])

        // 活动标签（四宫格）保形；另外两个标签的窗格追加到第一个组。
        XCTAssertEqual(shape(of: ws.terminalGroups),
                       .split(.horizontal, 0.35,
                              .split(.vertical, 0.62,
                                     .group(titles: ["四宫格", "demo-server", "旁边那个"], active: 0),
                                     .group(titles: ["四宫格"], active: 0)),
                              .split(.vertical, 0.28,
                                     .group(titles: ["四宫格"], active: 0),
                                     .group(titles: ["四宫格"], active: 0))))
        XCTAssertEqual(ws.terminalGroups.allTabs.count, 6, "会话一条不丢")
        XCTAssertEqual(ws.uiState.previewTerminalRatio, 0.667, accuracy: 0.0001)

        // 再存一次：新键写上了，旧键仍在（降级回滚）。
        let resaved = ws.snapshot()
        XCTAssertNotNil(resaved.terminalGroups)
        XCTAssertEqual(resaved.tabs.count, 6)
        try WorkspaceStore(windowID: windowID, directory: dir).save(resaved)
        let reloaded = WorkspaceStore(windowID: windowID, directory: dir).load()
        XCTAssertNotNil(reloaded?.terminalGroups)
        XCTAssertEqual(shape(of: WorkspaceModel(snapshot: reloaded!).terminalGroups),
                       shape(of: ws.terminalGroups))
    }
}
