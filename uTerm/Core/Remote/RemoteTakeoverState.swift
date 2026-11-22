import Foundation

/// 接管一台 Mac 之后，本机这一侧的对账状态（两端共用；标签怎么开、怎么摆由各端自己的标签容器做）：
///
/// - `follower`：那台 Mac 的终端列表变了，哪些标签该关、哪些该开（`RemoteSessionFollower`）。
/// - `arrangedByHand`：用户在本机亲手排过这台 Mac 的标签，之后 Mac 推来的顺序不再覆盖，直到重新接管，
///   或 Mac 推来的顺序和本机的排法对上了（支持 `arrange-sessions` 的 Mac 会照本机的排，见 `noteMacOrder`）。
/// - `awaitingFirstList`：接管时那台 Mac 的列表还没到。等第一份列表来了，调用方据 `Update.firstListIsEmpty`
///   决定要不要自动新建第一个终端（Mac 窗口这样做；手机从列表里点进来接管，列表一定已经到了）。
nonisolated struct RemoteTakeoverState: Equatable, Sendable {
    private(set) var follower: RemoteSessionFollower
    private(set) var arrangedByHand = false
    private(set) var awaitingFirstList: Bool

    /// `listReceived` 为 false = 接管时那台 Mac 的终端列表还没收到，`sessionIDs` 只是连接上暂存的会话。
    init(takingOver sessionIDs: [UUID], listReceived: Bool = true) {
        follower = RemoteSessionFollower(takingOver: sessionIDs)
        awaitingFirstList = !listReceived
    }

    struct Update: Equatable, Sendable {
        /// 列表里出现过、现在没了的终端：关掉标签。
        var gone: Set<UUID>
        /// 没见过的终端（按列表顺序）：开标签。
        var fresh: [UUID]
        /// 这是接管后收到的第一份列表（接管时还没有列表），而且那台 Mac 上一个终端都没有。
        var firstListIsEmpty = false
    }

    /// 收到那台 Mac 的终端列表。
    mutating func update(_ sessionIDs: [UUID]) -> Update {
        let firstListIsEmpty = awaitingFirstList && sessionIDs.isEmpty
        awaitingFirstList = false
        let (gone, fresh) = follower.update(sessionIDs)
        return Update(gone: gone, fresh: fresh, firstListIsEmpty: firstListIsEmpty)
    }

    /// 用户在本机亲手排过这台 Mac 的标签。
    mutating func noteArrangedByHand() {
        arrangedByHand = true
    }

    /// 收到 Mac 推来的顺序。用户亲手排过、而这份顺序和本机此刻的排法一致（多半是 Mac 已照本机排好）时，重新跟着 Mac 排。
    /// Mac 排不了的（两个标签在它那边分在不同的组或窗口），顺序对不上，本机就继续保持自己的排法。
    /// `layout` 是本机各组里这台 Mac 的标签（会话 id，按本机的先后）。
    mutating func noteMacOrder(_ order: [UUID]?, layout: [[UUID]]) {
        guard arrangedByHand, let order else { return }
        if layout.allSatisfy({ RemoteTabArrangement.arranged($0, order: order) { $0 } == $0 }) {
            arrangedByHand = false
        }
    }

    /// 本机标签要跟着排的顺序：Mac 推来了顺序、用户也没亲手排过才排；否则 nil，不动。
    func arrangement(_ order: [UUID]?) -> [UUID]? {
        arrangedByHand ? nil : order
    }
}

extension RemoteTabArrangement {
    /// 两次快照之间，用户有没有亲手调过标签顺序：每一组里，原来就在同一组的那些标签相对先后变了就算。
    /// 只比两边都在的标签——关掉的、新开的不算；挪到别的组不算（各组本来就各排各的）。
    /// 给拿不到「拖动排序」回调的标签容器用（Mac 上的 `UPaneGroups`）：每次自己摆完记一份快照，下次对账前比一比。
    nonisolated static func reorderedByHand(from previous: [[UUID]], to current: [[UUID]]) -> Bool {
        var place: [UUID: (group: Int, position: Int)] = [:]
        for (group, ids) in previous.enumerated() {
            for (position, id) in ids.enumerated() { place[id] = (group, position) }
        }
        for ids in current {
            var lastPosition: [Int: Int] = [:]
            for id in ids {
                guard let at = place[id] else { continue }
                if let last = lastPosition[at.group], last > at.position { return true }
                lastPosition[at.group] = at.position
            }
        }
        return false
    }
}

extension RemoteSessionInfo {
    /// 本机远控标签上的名字，两端一致：那台 Mac 上这枚标签此刻的名字（用户改过名就是改后的，也跟着程序设的标题变）；
    /// 老版本 Mac 不发它时，用这边终端自己收到的标题；再没有就用 `fallback`。截短同本机标签（`TerminalTitle.clippedForTab`）。
    nonisolated static func remoteTabTitle(_ info: RemoteSessionInfo?, shellTitle: String?, fallback: String) -> String {
        TerminalTitle.clippedForTab(info?.tabTitle ?? shellTitle ?? info?.title ?? fallback)
    }
}
