import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 我的设备：设备组（docs/remote-device-group-design.md §6）。
///
/// - 还没进组：一句说明、这台设备一行带「加入」、你的其它设备（只显示）。
/// - 点了「加入」：这一行下面大字显示 6 位数和「取消」，作废过就说一声；失败写原因。
/// - 已进组：组员名单，每行一个操作（别的设备「移除…」，这台「离开…」）；下面是还没进组的设备。
/// - 这台被移出了：说一声，再给「加入」。
///
/// 状态在 App 级的 `RemoteDeviceGroupService`（全 App 一个、后台一直在读名册）；别的设备想加入时由
/// `RemoteDeviceGroupPrompt` 单独弹面板输码，不在这一页。页面开着时轮询改快。
struct RemoteMyDevicesGroup: View {
    @Environment(RemoteDeviceGroupService.self) private var service
    /// 等确认的移除（连带的设备可以取消勾选）。
    @State private var removing: RemoteGroupRemovalPlan?
    @State private var confirmingLeave = false

    private var model: RemoteDeviceGroup? { service.model }

    var body: some View {
        SettingsGroup(title: RemoteDeviceGroupCopy.title, footer: footer) {
            if let model {
                content(model)
            } else {
                SettingsEmptyRow(symbol: "exclamationmark.triangle", text: RemoteDeviceGroupCopy.unavailable)
            }
        }
        .task {
            service.ensureModel()
            await service.keepActive()
        }
        .sheet(item: $removing) { plan in
            RemoteGroupRemoveSheet(plan: plan) { ids in
                removing = nil
                if let ids { model?.remove(ids) }
            }
        }
        .alert(RemoteDeviceGroupCopy.leaveTitle, isPresented: $confirmingLeave) {
            Button("取消", role: .cancel) {}
            Button("离开", role: .destructive) { model?.leave() }
        } message: {
            Text(RemoteDeviceGroupCopy.leaveMessage)
        }
        if let model, model.isInGroup, !model.isSelfRemoved, !model.otherDevices.isEmpty {
            SettingsGroup(title: RemoteDeviceGroupCopy.outsideHeader, footer: RemoteDeviceGroupCopy.outsideFooter) {
                ForEach(model.otherDevices) { device in
                    SettingsListRow(icon: symbol(for: device), tint: UD.text3, title: device.name,
                                    subtitle: device.modelDetail) { EmptyView() }
                }
            }
        }
    }

    private var footer: String {
        guard let model, model.isInGroup, !model.isSelfRemoved else {
            return RemoteDeviceGroupCopy.intro + RemoteDeviceGroupCopy.howToJoin
        }
        return RemoteDeviceGroupCopy.groupFooter
    }

    @ViewBuilder
    private func content(_ model: RemoteDeviceGroup) -> some View {
        if let error = model.storageError {
            SettingsInlineNote(tone: .danger, text: error)
        }
        if model.isSelfRemoved {
            SettingsInlineNote(tone: .warning, text: RemoteDeviceGroupCopy.selfRemoved)
        }
        if model.isInGroup, !model.isSelfRemoved {
            memberList(model)
        } else {
            joinRow(model)
            joinProgress(model)
            ForEach(model.listedOtherDevices) { device in
                SettingsListRow(icon: symbol(for: device), tint: UD.text3, title: device.name,
                                subtitle: device.modelDetail) { EmptyView() }
            }
            if model.listedOtherDevices.isEmpty {
                SettingsEmptyRow(symbol: "laptopcomputer.and.iphone", text: RemoteDeviceGroupCopy.noOtherDevices)
            }
        }
    }

    // MARK: 还没进组

    private func joinRow(_ model: RemoteDeviceGroup) -> some View {
        SettingsListRow(icon: symbol(for: model.local), tint: UD.accent, title: model.local.name,
                        subtitle: [RemoteDeviceGroupCopy.thisDevice, RemoteDeviceGroupCopy.notJoined].joined(separator: " · ")) {
            if !isShowingCode(model) {
                UDButton(title: "加入", style: .secondary) {
                    model.startJoin()
                    service.poke()
                }
            }
        }
    }

    @ViewBuilder
    private func joinProgress(_ model: RemoteDeviceGroup) -> some View {
        switch model.joinState {
        case .showingCode(let code, let attemptsLeft):
            SettingsCenteredBlock(caption: RemoteDeviceGroupCopy.codeCaption(attemptsLeft: attemptsLeft)) {
                VStack(spacing: 10) {
                    Text(RemoteDeviceGroupCopy.codeTitle)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(UD.text)
                    Text(RemotePairingCode.grouped(code))
                        .font(.system(size: 34, weight: .semibold, design: .monospaced))
                        .foregroundStyle(UD.text)
                        .textSelection(.enabled)
                    UDButton(title: "取消", style: .secondary) { model.cancelJoin() }
                }
            }
            .settingsDivider(inset: nil)
        case .failed(let reason):
            SettingsCenteredBlock(caption: reason) {
                VStack(spacing: 10) {
                    Text(RemoteDeviceGroupCopy.failedTitle)
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(UD.text)
                    UDButton(title: "好", style: .secondary) { model.cancelJoin() }
                }
            }
            .settingsDivider(inset: nil)
        case .joined, nil:
            EmptyView()
        }
    }

    private func isShowingCode(_ model: RemoteDeviceGroup) -> Bool {
        if case .showingCode = model.joinState { return true }
        return false
    }

    // MARK: 已进组

    @ViewBuilder
    private func memberList(_ model: RemoteDeviceGroup) -> some View {
        if let waiting = model.awaitingAcknowledgement {
            SettingsInlineNote(tone: .neutral, text: RemoteDeviceGroupCopy.awaiting(waiting))
        }
        ForEach(model.members) { row in
            SettingsListRow(icon: symbol(for: row.device), tint: UD.accent, title: row.device.name,
                            subtitle: RemoteDeviceGroupCopy.memberSubtitle(row)) {
                SettingsMoreMenu(items: [menuItem(for: row, model: model)])
            }
        }
    }

    private func menuItem(for row: RemoteDeviceGroup.MemberRow, model: RemoteDeviceGroup) -> UDMenuItem {
        if row.isLocal {
            return UDMenuItem(label: String(localized: "离开…"), systemImage: "rectangle.portrait.and.arrow.right", danger: true) {
                confirmingLeave = true
            }
        }
        return UDMenuItem(label: String(localized: "移除…"), systemImage: "minus.circle", danger: true) {
            removing = RemoteGroupRemovalPlan(target: row.device, cascade: model.devicesAdmitted(by: row.device.id))
        }
    }

    private func symbol(for device: RemoteGroupDevice) -> String {
        settingsDeviceSymbol(for: device)
    }
}

/// 移除前的确认：列出由它加进来的设备（默认一起移除，可以取消勾选）。`onDone(nil)` 是取消。
struct RemoteGroupRemoveSheet: View {
    @State var plan: RemoteGroupRemovalPlan
    let onDone: ([UUID]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(RemoteDeviceGroupCopy.removeTitle(plan.target))
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(UD.text)
            Text(RemoteDeviceGroupCopy.removeMessage)
                .font(.system(size: 12)).foregroundStyle(UD.text2)
                .fixedSize(horizontal: false, vertical: true)
            if !plan.cascade.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(RemoteDeviceGroupCopy.cascadeHeader)
                        .font(.system(size: 12)).foregroundStyle(UD.text2)
                    ForEach(plan.cascade) { device in
                        UDCheckbox(device.name, isOn: Binding(get: { plan.includes(device.id) },
                                                              set: { plan.set(device.id, included: $0) }))
                    }
                }
            }
            HStack {
                Spacer()
                UDButton(title: "取消", style: .secondary) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                UDButton(title: "移除", style: .danger) { onDone(plan.ids) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(UD.bg)
    }
}
