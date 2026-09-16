import XCTest
import SwiftData
@testable import uTerm

@MainActor
final class GroupStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: ServerProfile.self, ServerGroup.self, configurations: config)
        return ModelContext(container)
    }

    // MARK: Group model + 颜色

    func testPaletteHasTenColors() {
        XCTAssertEqual(ServerGroup.palette.count, 10)
        XCTAssertEqual(ServerGroup.palette.first, "#f87171")
        XCTAssertEqual(ServerGroup.palette.last, "#9aa7b5")
    }

    func testGroupHexRGBParses() {
        let (r, g, b) = groupHexRGB("#f87171")
        XCTAssertEqual(r, 248.0/255, accuracy: 0.001)
        XCTAssertEqual(g, 113.0/255, accuracy: 0.001)
        XCTAssertEqual(b, 113.0/255, accuracy: 0.001)
        let (r2, _, _) = groupHexRGB("60a5fa")
        XCTAssertEqual(r2, 96.0/255, accuracy: 0.001)
    }

    func testGroupHexRGBFallsBackToGrayOnBadInput() {
        let (r, g, b) = groupHexRGB("not-a-hex")
        XCTAssertEqual(r, 154.0/255, accuracy: 0.001)
        XCTAssertEqual(g, 167.0/255, accuracy: 0.001)
        XCTAssertEqual(b, 181.0/255, accuracy: 0.001)
    }

    func testGroupModelInsertFetchRoundTrip() throws {
        let ctx = try makeContext()
        ctx.insert(ServerGroup(name: "prod", colorHex: "#f87171", isPinned: true, sortOrder: 0))
        let all = try ctx.fetch(FetchDescriptor<ServerGroup>())
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "prod")
        XCTAssertEqual(all.first?.isPinned, true)
    }

    private func profile(_ name: String, group: String?) -> ServerProfile {
        let p = ServerProfile()
        p.name = name
        p.host = "h"
        p.group = group
        return p
    }

    // MARK: nextColor / sortedForSidebar（纯函数）

    func testNextColorCyclesPalette() {
        XCTAssertEqual(GroupStore.nextColor(existingCount: 0), "#f87171")
        XCTAssertEqual(GroupStore.nextColor(existingCount: 3), "#a3e635")
        XCTAssertEqual(GroupStore.nextColor(existingCount: 10), "#f87171")
    }

    func testSortedForSidebarPinnedThenOrderThenName() {
        let a = ServerGroup(name: "zeta",  isPinned: false, sortOrder: 5)
        let b = ServerGroup(name: "alpha", isPinned: true,  sortOrder: 9)
        let c = ServerGroup(name: "beta",  isPinned: false, sortOrder: 5)
        let sorted = GroupStore.sortedForSidebar([a, b, c])
        XCTAssertEqual(sorted.map(\.name), ["alpha", "beta", "zeta"])
    }

    // MARK: reconcile / ensure

    func testReconcileCreatesMissingGroups() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "prod"))
        ctx.insert(profile("p2", group: "prod"))
        ctx.insert(profile("p3", group: "dev"))
        ctx.insert(profile("p4", group: nil))
        ctx.insert(profile("p5", group: ""))
        GroupStore(context: ctx).reconcile()
        let groups = try ctx.fetch(FetchDescriptor<ServerGroup>())
        XCTAssertEqual(Set(groups.map(\.name)), ["dev", "prod"])
    }

    func testReconcileIsIdempotent() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "prod"))
        let store = GroupStore(context: ctx)
        store.reconcile()
        store.reconcile()
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServerGroup>()).count, 1)
    }

    func testReconcileEmptyProfilesCreatesNothing() throws {
        let ctx = try makeContext()
        GroupStore(context: ctx).reconcile()
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ServerGroup>()).isEmpty)
    }

    func testReconcileAssignsCyclingColors() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "aaa"))
        ctx.insert(profile("p2", group: "bbb"))
        GroupStore(context: ctx).reconcile()
        let byName = Dictionary(uniqueKeysWithValues:
            try ctx.fetch(FetchDescriptor<ServerGroup>()).map { ($0.name, $0.colorHex) })
        XCTAssertEqual(byName["aaa"], "#f87171")
        XCTAssertEqual(byName["bbb"], "#fb923c")
    }

    func testReconcileContinuesColorAndOrderForNewNames() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "aaa"))
        ctx.insert(profile("p2", group: "bbb"))
        let store = GroupStore(context: ctx)
        store.reconcile()                       // aaa→palette[0]/order0, bbb→palette[1]/order1
        ctx.insert(profile("p3", group: "ccc"))
        store.reconcile()                       // 续：ccc→palette[2]/order2（不重启）
        let byName = Dictionary(uniqueKeysWithValues:
            try ctx.fetch(FetchDescriptor<ServerGroup>()).map { ($0.name, $0) })
        XCTAssertEqual(byName["ccc"]?.colorHex, "#fbbf24")   // palette[2]
        XCTAssertEqual(byName["ccc"]?.sortOrder, 2)
        XCTAssertEqual(byName["aaa"]?.colorHex, "#f87171")   // 旧的不变
        XCTAssertEqual(byName["aaa"]?.sortOrder, 0)
    }

    func testEnsureCreatesThenReturnsSame() throws {
        let ctx = try makeContext()
        let store = GroupStore(context: ctx)
        let g1 = store.ensure(name: "staging")
        let g2 = store.ensure(name: "staging")
        XCTAssertEqual(g1.persistentModelID, g2.persistentModelID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServerGroup>()).count, 1)
    }

    // MARK: spec B 操作

    func testCreateEmptyReturnsNilNoInsert() throws {
        let ctx = try makeContext()
        XCTAssertNil(GroupStore(context: ctx).create(name: "   "))
        XCTAssertTrue(try ctx.fetch(FetchDescriptor<ServerGroup>()).isEmpty)
    }

    func testCreateNewThenDuplicateReturnsSame() throws {
        let ctx = try makeContext()
        let store = GroupStore(context: ctx)
        let a = store.create(name: "prod")
        let b = store.create(name: "prod")
        XCTAssertNotNil(a)
        XCTAssertEqual(a?.persistentModelID, b?.persistentModelID)
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServerGroup>()).count, 1)
    }

    func testRenameUpdatesGroupAndMembers() throws {
        let ctx = try makeContext()
        let p = profile("p1", group: "dev"); ctx.insert(p)
        let store = GroupStore(context: ctx); store.reconcile()
        let g = try ctx.fetch(FetchDescriptor<ServerGroup>()).first { $0.name == "dev" }!
        XCTAssertTrue(store.rename(g, to: "develop"))
        XCTAssertEqual(g.name, "develop")
        XCTAssertEqual(p.group, "develop")
    }

    func testRenameToExistingNameRefused() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "dev")); ctx.insert(profile("p2", group: "prod"))
        let store = GroupStore(context: ctx); store.reconcile()
        let dev = try ctx.fetch(FetchDescriptor<ServerGroup>()).first { $0.name == "dev" }!
        XCTAssertFalse(store.rename(dev, to: "prod"))
        XCTAssertEqual(dev.name, "dev")
    }

    func testRenameToSameNameIsNoOp() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "dev"))
        let store = GroupStore(context: ctx); store.reconcile()
        let g = try ctx.fetch(FetchDescriptor<ServerGroup>()).first { $0.name == "dev" }!
        XCTAssertTrue(store.rename(g, to: "dev"))                  // 同名 → true no-op
        XCTAssertEqual(g.name, "dev")                             // 未变
        XCTAssertEqual(try ctx.fetch(FetchDescriptor<ServerGroup>()).count, 1)   // 不重复
    }

    func testRenameEmptyRefused() throws {
        let ctx = try makeContext()
        ctx.insert(profile("p1", group: "dev"))
        let store = GroupStore(context: ctx); store.reconcile()
        let g = try ctx.fetch(FetchDescriptor<ServerGroup>()).first!
        XCTAssertFalse(store.rename(g, to: "  "))
        XCTAssertEqual(g.name, "dev")
    }

    func testDeleteRemovesGroupAndUngroupsMembers() throws {
        let ctx = try makeContext()
        let p = profile("p1", group: "dev"); ctx.insert(p)
        let q = profile("p2", group: "prod"); ctx.insert(q)
        let store = GroupStore(context: ctx); store.reconcile()
        let dev = try ctx.fetch(FetchDescriptor<ServerGroup>()).first { $0.name == "dev" }!
        store.delete(dev)
        XCTAssertNil(p.group)
        XCTAssertEqual(q.group, "prod")
        XCTAssertFalse(try ctx.fetch(FetchDescriptor<ServerGroup>()).contains { $0.name == "dev" })
    }

    func testSetColorAndPinned() throws {
        let ctx = try makeContext()
        let g = ServerGroup(name: "x"); ctx.insert(g)
        let store = GroupStore(context: ctx)
        store.setColor(g, hex: "#60a5fa"); store.setPinned(g, true)
        XCTAssertEqual(g.colorHex, "#60a5fa")
        XCTAssertTrue(g.isPinned)
    }

    func testReorderRewritesSortOrderByPosition() throws {
        let ctx = try makeContext()
        let a = ServerGroup(name: "a", sortOrder: 0)
        let b = ServerGroup(name: "b", sortOrder: 1)
        let c = ServerGroup(name: "c", sortOrder: 2)
        [a, b, c].forEach { ctx.insert($0) }
        let store = GroupStore(context: ctx)
        store.reorder([c, a, b])                 // 新可视顺序
        XCTAssertEqual(c.sortOrder, 0)
        XCTAssertEqual(a.sortOrder, 1)
        XCTAssertEqual(b.sortOrder, 2)
    }

    func testReorderIsNoOpWhenAlreadyInOrder() throws {
        let ctx = try makeContext()
        let a = ServerGroup(name: "a", sortOrder: 0)
        let b = ServerGroup(name: "b", sortOrder: 1)
        [a, b].forEach { ctx.insert($0) }
        GroupStore(context: ctx).reorder([a, b])
        XCTAssertEqual(a.sortOrder, 0)
        XCTAssertEqual(b.sortOrder, 1)
    }

    func testAddMemberMovesAndRemoveUngroups() throws {
        let ctx = try makeContext()
        let p = profile("p1", group: "dev"); ctx.insert(p)
        let store = GroupStore(context: ctx)
        store.addMember(p, to: "prod")
        XCTAssertEqual(p.group, "prod")
        store.removeMember(p)
        XCTAssertNil(p.group)
    }

    func testMembersOf() throws {
        let a = profile("a", group: "dev")
        let b = profile("b", group: "dev")
        let c = profile("c", group: "prod")
        let m = GroupStore.members(of: "dev", in: [a, b, c])
        XCTAssertEqual(Set(m.map(\.name)), ["a", "b"])
        XCTAssertTrue(GroupStore.members(of: "nope", in: [a, b, c]).isEmpty)
    }

    func testMemberDisplayNameUsesServerNameBeforeHost() {
        let p = profile("prod-main", group: nil)
        p.host = "203.0.113.10"

        XCTAssertEqual(serverProfileMemberDisplayName(p), "prod-main")
    }

    func testMemberDisplayNameFallsBackToHostWhenServerNameIsEmpty() {
        let p = profile("", group: nil)
        p.host = "203.0.113.10"

        XCTAssertEqual(serverProfileMemberDisplayName(p), "203.0.113.10")
    }

    // MARK: detail rename editor state

    func testDetailRenameEditorBeginPrefillsDraftAndClearsError() {
        var state = GroupRenameEditorState<String>()
        state.draft = "stale"
        state.hasError = true

        state.begin(id: "group-1", currentName: "prod")

        XCTAssertTrue(state.isEditing("group-1"))
        XCTAssertEqual(state.draft, "prod")
        XCTAssertFalse(state.hasError)
    }

    func testDetailRenameEditorSaveClosesOnSuccess() {
        var state = GroupRenameEditorState<String>()
        state.begin(id: "group-1", currentName: "prod")
        state.draft = "vps"
        var submittedName: String?

        let saved = state.save(id: "group-1") { draft in
            submittedName = draft
            return true
        }

        XCTAssertTrue(saved)
        XCTAssertEqual(submittedName, "vps")
        XCTAssertFalse(state.isEditing("group-1"))
        XCTAssertFalse(state.hasError)
    }

    func testDetailRenameEditorSaveFailureKeepsEditorOpen() {
        var state = GroupRenameEditorState<String>()
        state.begin(id: "group-1", currentName: "prod")
        state.draft = "existing"

        let saved = state.save(id: "group-1") { _ in false }

        XCTAssertFalse(saved)
        XCTAssertTrue(state.isEditing("group-1"))
        XCTAssertEqual(state.draft, "existing")
        XCTAssertTrue(state.hasError)
    }

    func testDetailRenameEditorBlankSaveDoesNotSubmit() {
        var state = GroupRenameEditorState<String>()
        state.begin(id: "group-1", currentName: "prod")
        state.draft = "   "
        var didSubmit = false

        let saved = state.save(id: "group-1") { _ in
            didSubmit = true
            return true
        }

        XCTAssertFalse(saved)
        XCTAssertFalse(didSubmit)
        XCTAssertTrue(state.isEditing("group-1"))
        XCTAssertTrue(state.hasError)
    }

    func testDetailRenameEditorCancelClearsEditingState() {
        var state = GroupRenameEditorState<String>()
        state.begin(id: "group-1", currentName: "prod")
        state.draft = "changed"
        state.hasError = true

        state.cancel(currentName: "prod")

        XCTAssertFalse(state.isEditing("group-1"))
        XCTAssertEqual(state.draft, "prod")
        XCTAssertFalse(state.hasError)
    }

    func testGroupRowDeleteButtonUsesLargeHitTarget() {
        XCTAssertGreaterThanOrEqual(GroupRowDeleteButtonLayout.hitWidth, 28)
        XCTAssertGreaterThanOrEqual(GroupRowDeleteButtonLayout.hitHeight, 28)
    }

    func testGroupsManagerRowsDoNotDeclareKeyboardFocusRing() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Groups/Views/GroupsManagerView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains(".focusable("))
        XCTAssertFalse(source.contains(".focusEffectDisabled("))
    }

    func testGroupsManagerRenameInputDoesNotAutofocus() throws {
        let source = try String(contentsOf: repoRoot.appendingPathComponent(
            "uTerm/Features/Groups/Views/GroupsManagerView.swift"
        ), encoding: .utf8)

        XCTAssertFalse(source.contains("autoFocus: true"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
