import Foundation

/// 「我的设备」（设备组）两端共用的文案。Mac 是 `RemoteMyDevicesGroup` 与 `RemoteDeviceGroupPrompt`，
/// iOS 是 `RemoteMyDevicesScreen` 与 `RemoteGroupJoinSheet`；状态在 `RemoteDeviceGroup`。
enum RemoteDeviceGroupCopy {
    static let title = String(localized: "我的设备")
    /// 还没进组时的那句说明。
    static let intro = String(localized: "加入设备组后，本机可使用组内任一设备已配对的 Mac。")
    /// 已进组时的那句说明。
    static let groupFooter = String(localized: "组内任一设备已配对的 Mac，所有成员均可使用。被移除的设备需重新加入。")
    static let howToJoin = String(localized: "在待加入的设备上点「加入」，再在组内任一设备上输入它显示的 6 位验证码。")
    static let noOtherDevices = String(localized: "未发现其他设备。在登录同一 Apple ID 的另一台设备上打开 uTerm。")
    static let thisDevice = String(localized: "本机")
    static let notJoined = String(localized: "未加入")
    static let unavailable = String(localized: "无法读取本机的远程控制身份（钥匙串不可用）")
    /// 这台 Mac 开着被控、还没进组、名册里有别的设备时（`RemoteDeviceGroup.suggestsJoiningLocalMac`），「加入」上方那句说明。
    static let joinThisMacHint = String(localized: "本机加入设备组后，可远程控制本机的设备由设备组统一管理，移除设备立即生效。")

    // MARK: 新设备一侧

    static let codeTitle = String(localized: "在另一台设备上输入此验证码")

    /// 显示核对码时的说明：作废过的话说一声换了新数。
    static func codeCaption(attemptsLeft: Int) -> String {
        attemptsLeft < RemoteDeviceGroup.codeAttempts
            ? String(localized: "上一个验证码未通过核对，已更换。还可重试 \(attemptsLeft) 次。")
            : String(localized: "其他设备会弹出输入框。验证码 10 分钟内有效。")
    }

    static let failedTitle = String(localized: "加入失败")

    static func awaiting(_ device: RemoteGroupDevice) -> String {
        String(localized: "正在等待「\(device.name)」确认。")
    }

    static let selfRemoved = String(localized: "本机已被移出设备组，需重新加入。")

    // MARK: 组员一侧

    static let outsideHeader = String(localized: "未加入的设备")
    static let outsideFooter = String(localized: "在该设备的「我的设备」中点「加入」，本机会弹出输入框。")
    /// 「未加入的设备」里本机配对过的 Mac：副标题里多这一句。
    static let pairedMacOutsideHint = String(localized: "加入后，组内设备无需单独配对即可控制它")

    /// 「未加入的设备」一行的副标题：机型；是本机配对过的 Mac 时再加一句（`isPairedMacOutside`）。都没有时为 nil。
    static func outsideSubtitle(_ device: RemoteGroupDevice, pairedHosts: Set<UUID>) -> String? {
        var parts = [device.modelDetail].compactMap(\.self)
        if isPairedMacOutside(device, pairedHosts: pairedHosts) { parts.append(pairedMacOutsideHint) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 没进组的这台设备是 Mac，本机配对过它（`RemoteDeviceGroup.pairedHostIDs`）。
    static func isPairedMacOutside(_ device: RemoteGroupDevice, pairedHosts: Set<UUID>) -> Bool {
        device.isMac && pairedHosts.contains(device.id)
    }

    /// 名单里一行的副标题：机型、「这台设备」、谁加的。都没有时为 nil。
    static func memberSubtitle(_ row: RemoteDeviceGroup.MemberRow) -> String? {
        var parts = [row.device.modelDetail].compactMap(\.self)
        if row.isLocal { parts.append(thisDevice) }
        if let admitter = row.admittedByName { parts.append(String(localized: "由「\(admitter)」添加")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func removeTitle(_ device: RemoteGroupDevice) -> String {
        String(localized: "移除「\(device.name)」？")
    }

    static let removeMessage = String(localized: "移除后，该设备需重新加入才能使用。")
    /// 移除确认里的第二句：Mac 上的撤销是自动的（§7.3）。
    static let removeRevokesMacs = String(localized: "你的 Mac 也将撤销其远程控制权限。")
    static let cascadeHeader = String(localized: "同时移除由该设备添加的设备：")
    static let leaveTitle = String(localized: "离开设备组？")
    static let leaveMessage = String(localized: "离开后，本机需重新加入才能使用；组内其他设备不受影响。")

    // MARK: 验证本人（系统验证框上的说明，`RemoteGroupOwnerCheck`）

    /// 一句动宾短语：macOS 会在前面加「“uTerm”正在尝试」。
    static func ownerCheckRemove(name: String, count: Int) -> String {
        count > 1 ? String(localized: "移除「\(name)」等 \(count) 台设备") : String(localized: "移除「\(name)」")
    }

    static func ownerCheckAdmit(name: String) -> String {
        String(localized: "将「\(name)」加入设备组")
    }

    static let ownerCheckLeave = String(localized: "离开设备组")

    // MARK: 还没通的 Mac

    static let pendingHostsHeader = String(localized: "待开通的 Mac")
    static let pendingHostsFooter = String(localized: "组内有设备可连接这些 Mac 时，将自动为本机开通。")

    /// 「还没通的 Mac」一行右边那几个字。
    static func pendingHostStatus(_ status: RemoteDeviceGroup.PendingHost.Status) -> String {
        switch status {
        case .opening:
            return String(localized: "正在开通")
        case .needsPairing(.notAllowed):
            return String(localized: "Mac 未允许开通，需单独配对")
        case .needsPairing(.tooOld):
            return String(localized: "Mac 上的 uTerm 版本过旧，需单独配对")
        case .needsPairing(.rejected):
            return String(localized: "Mac 已拒绝，需单独配对")
        case .needsPairing(.conflict):
            return String(localized: "与本机保存的记录不一致，需重新配对")
        case .needsPairing(.forgotten):
            return String(localized: "你已在本机忘记这台 Mac")
        }
    }

    /// 要单独配对的用警示色。
    static func isWarning(_ status: RemoteDeviceGroup.PendingHost.Status) -> Bool {
        if case .needsPairing = status { return true }
        return false
    }

    // MARK: 已移除的设备

    static let removedHeader = String(localized: "已移除的设备")
    static let removedFooter = String(localized: "相关 Mac 上线后将自动撤销。")
    /// 撤销进度里没记下名字时的叫法。
    static let unnamedDevice = String(localized: "未命名设备")

    /// 「已移除的设备」一行右边那几个字：还有几台 Mac 没撤（只剩一台时写它的名字）。
    static func removedStatus(_ device: RemoteDeviceGroup.RemovedDevice) -> String {
        if device.waitingHosts.count == 1, let host = device.waitingHosts.first {
            return String(localized: "「\(host)」尚未撤销")
        }
        return String(localized: "\(device.waitingHosts.count) 台 Mac 尚未撤销")
    }

    // MARK: 弹窗（组员一侧输码）

    static func requestTitle(_ device: RemoteGroupDevice) -> String {
        String(localized: "「\(device.name)」请求加入设备组")
    }

    static let verifyingTitle = String(localized: "正在核对")

    static func requestDetail(_ request: RemoteDeviceGroup.JoinRequest) -> String {
        let name = request.candidate.name
        switch request.status {
        case .waitingForCode:
            return String(localized: "输入该设备上显示的 6 位验证码。如非本人操作，点「拒绝」。")
        case .verifying:
            return String(localized: "正在等待「\(name)」响应。可先关闭，核对将在后台继续。")
        case .wrongCode(let left):
            return String(localized: "验证码有误，「\(name)」已更换验证码。还可重试 \(left) 次。")
        case .limitReached:
            return String(localized: "错误次数过多。10 分钟后重试，或改在另一台设备上输入。")
        case .admitted:
            return String(localized: "「\(name)」已加入。")
        }
    }

    /// 这个状态下能不能输码。
    static func acceptsCode(_ status: RemoteDeviceGroup.JoinRequest.Status) -> Bool {
        switch status {
        case .waitingForCode, .wrongCode: return true
        case .verifying, .limitReached, .admitted: return false
        }
    }

    /// 弹窗说明用不用警示色（上一次输错、次数用完）。
    static func isWarning(_ status: RemoteDeviceGroup.JoinRequest.Status) -> Bool {
        switch status {
        case .wrongCode, .limitReached: return true
        case .waitingForCode, .verifying, .admitted: return false
        }
    }
}

extension RemoteDeviceGroup {
    /// 提示把这台 Mac 加进设备组（§19）：本机是 Mac、开着被控且允许担保（`localHost.acceptsGroupControllers`：
    /// 关着担保时进了组也不按名单记主控端，这句话不成立）、还没进组、没被移出（那时另有一句「已被移出」）、
    /// 没在加入（显示着验证码或失败原因时不加）、名册里有别的设备。只有 Mac 交了 `localHost`，iOS 上恒为 false。
    var suggestsJoiningLocalMac: Bool {
        guard local.isMac, localHost?.acceptsGroupControllers == true else { return false }
        return !isInGroup && !isSelfRemoved && joinState == nil && !otherDevices.isEmpty
    }

    /// 「你的其它设备」那一列（还没进组、或这台被移出时）：名册里不在本机组里的设备，被移出时再加上原来组里的设备
    /// （本机还记着它们，`otherDevices` 不列，不然被移出后它们哪儿都看不到）。按名字排，同一个 ID 只列一次。
    var listedOtherDevices: [RemoteGroupDevice] {
        guard isSelfRemoved else { return otherDevices }
        var seen = Set<UUID>()
        return (otherDevices + members.filter { !$0.isLocal }.map(\.device))
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }
}

/// 移除一台组员时的确认：连带的设备（`RemoteDeviceGroup.devicesAdmitted(by:)`）默认都勾上，可以取消勾选。
nonisolated struct RemoteGroupRemovalPlan: Equatable, Identifiable {
    let target: RemoteGroupDevice
    let cascade: [RemoteGroupDevice]
    private(set) var selected: Set<UUID>

    var id: UUID { target.id }

    init(target: RemoteGroupDevice, cascade: [RemoteGroupDevice]) {
        self.target = target
        self.cascade = cascade.filter { $0.id != target.id }
        selected = Set(self.cascade.map(\.id))
    }

    func includes(_ id: UUID) -> Bool { selected.contains(id) }

    mutating func set(_ id: UUID, included: Bool) {
        guard cascade.contains(where: { $0.id == id }) else { return }
        if included { selected.insert(id) } else { selected.remove(id) }
    }

    /// 交给 `RemoteDeviceGroup.remove(_:)` 的：这台设备，加上勾着的连带设备（按列表顺序）。
    var ids: [UUID] {
        [target.id] + cascade.filter { selected.contains($0.id) }.map(\.id)
    }
}
