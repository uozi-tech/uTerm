import Foundation

/// 「我的设备」（设备组）两端共用的文案。Mac 是 `RemoteMyDevicesGroup` 与 `RemoteDeviceGroupPrompt`，
/// iOS 是 `RemoteMyDevicesScreen` 与 `RemoteGroupJoinSheet`；状态在 `RemoteDeviceGroup`。
enum RemoteDeviceGroupCopy {
    static let title = String(localized: "我的设备")
    /// 还没进组时的那句说明。
    static let intro = String(localized: "加入后，你在任何一台设备上配对过的 Mac，这台设备都能用。")
    /// 已进组时的那句说明。
    static let groupFooter = String(localized: "组里任何一台设备配对过的 Mac，组里的设备都能用。移除的设备要重新加入。")
    static let howToJoin = String(localized: "在要加入的设备上点「加入」，再在组里任意一台设备上输入它显示的 6 位数。")
    static let noOtherDevices = String(localized: "还没有你的其它设备。在另一台登录同一 Apple ID 的设备上打开 uTerm。")
    static let thisDevice = String(localized: "这台设备")
    static let notJoined = String(localized: "还没加入")
    static let unavailable = String(localized: "读不到这台设备的远程控制身份（钥匙串不可用）")

    // MARK: 新设备一侧

    static let codeTitle = String(localized: "在你的另一台设备上输入这个数")

    /// 显示核对码时的说明：作废过的话说一声换了新数。
    static func codeCaption(attemptsLeft: Int) -> String {
        attemptsLeft < RemoteDeviceGroup.codeAttempts
            ? String(localized: "上一个数没对上，换成了这个新数。还能再试 \(attemptsLeft) 次。")
            : String(localized: "组里的设备会弹出输入框。10 分钟内有效。")
    }

    static let failedTitle = String(localized: "没有加入")

    static func awaiting(_ device: RemoteGroupDevice) -> String {
        String(localized: "还在等「\(device.name)」确认。")
    }

    static let selfRemoved = String(localized: "这台设备已被移出你的设备组。要再用，重新加入。")

    // MARK: 组员一侧

    static let outsideHeader = String(localized: "不在组里的设备")
    static let outsideFooter = String(localized: "在那台设备的「我的设备」里点「加入」，这里会弹出输入框。")

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

    static let removeMessage = String(localized: "被移除的设备要重新加入才能用。")
    static let cascadeHeader = String(localized: "由它加进来的设备也一起移除：")
    static let leaveTitle = String(localized: "离开设备组？")
    static let leaveMessage = String(localized: "离开后这台设备要重新加入才能用，组里别的设备不受影响。")

    // MARK: 弹窗（组员一侧输码）

    static func requestTitle(_ device: RemoteGroupDevice) -> String {
        String(localized: "「\(device.name)」想加入你的设备")
    }

    static let verifyingTitle = String(localized: "正在核对…")

    static func requestDetail(_ request: RemoteDeviceGroup.JoinRequest) -> String {
        let name = request.candidate.name
        switch request.status {
        case .waitingForCode:
            return String(localized: "输入它屏幕上显示的 6 位数。不是你发起的，点「拒绝」。")
        case .verifying:
            return String(localized: "等「\(name)」回话。可以先关掉，核对会在后台继续。")
        case .wrongCode(let left):
            return String(localized: "不对，「\(name)」上已经换了新数。还能再试 \(left) 次。")
        case .limitReached:
            return String(localized: "输错的次数太多了。过 10 分钟再试，或者在另一台设备上输入。")
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
