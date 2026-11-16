import SwiftUI

/// 设置 › 远程控制 › 我的设备：设备组（docs/remote-device-group-design.md §6），状态与 Mac 那一页相同：
/// 还没进组（说明、「加入」、你的其它设备）、显示核对码、加入失败、已进组（组员名单，「移除…」/「离开…」，
/// 还没通的 Mac，还没进组的设备）、这台被移出了。状态与操作在共享的 `RemoteDeviceGroup`，文案在 `RemoteDeviceGroupCopy`；
/// 别的设备想加入时由根视图上的 `RemoteGroupJoinHandler` 弹输码单子，不在这一页。
struct RemoteMyDevicesScreen: View {
    @Environment(RemoteDeviceGroupService.self) private var service
    /// 等确认的移除（连带的设备可以取消勾选）。
    @State private var removing: RemoteGroupRemovalPlan?
    @State private var confirmingLeave = false

    private var model: RemoteDeviceGroup? { service.model }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let model {
                    content(model)
                } else {
                    MInsetGroup(footer: RemoteDeviceGroupCopy.intro) {
                        MInsetRow(icon: "warn", iconColor: M.danger, label: RemoteDeviceGroupCopy.unavailable, last: true)
                    }
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: M.readableWidth)
            .frame(maxWidth: .infinity)
        }
        .background(M.canvas)
        .navigationTitle("我的设备")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            service.ensureModel()
            await service.keepActive()
        }
        .sheet(item: $removing) { plan in
            RemoveMemberSheet(plan: plan) { ids in
                removing = nil
                if let ids { model?.remove(ids) }
            }
            .presentationDetents([.medium, .large])
            .presentationBackground(M.canvas)
        }
        .confirmationDialog(RemoteDeviceGroupCopy.leaveTitle, isPresented: $confirmingLeave, titleVisibility: .visible) {
            Button("离开", role: .destructive) { model?.leave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(RemoteDeviceGroupCopy.leaveMessage)
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteDeviceGroup) -> some View {
        if let error = model.storageError {
            MInsetGroup {
                MInsetRow(icon: "warn", iconColor: M.danger, label: error, last: true)
            }
        }
        if model.isInGroup, !model.isSelfRemoved {
            memberGroup(model)
            if !model.pendingHosts.isEmpty {
                MInsetGroup(header: RemoteDeviceGroupCopy.pendingHostsHeader, footer: RemoteDeviceGroupCopy.pendingHostsFooter) {
                    ForEach(Array(model.pendingHosts.enumerated()), id: \.element.id) { index, host in
                        MInsetRow(icon: "mac", iconColor: M.text3, label: host.name,
                                  value: RemoteDeviceGroupCopy.pendingHostStatus(host.status),
                                  last: index == model.pendingHosts.count - 1)
                    }
                }
            }
            if !model.otherDevices.isEmpty {
                MInsetGroup(header: RemoteDeviceGroupCopy.outsideHeader, footer: RemoteDeviceGroupCopy.outsideFooter) {
                    deviceRows(model.otherDevices)
                }
            }
        } else {
            if model.isSelfRemoved {
                MInsetGroup {
                    MInsetRow(icon: "warn", iconColor: M.danger, label: RemoteDeviceGroupCopy.selfRemoved, last: true)
                }
            }
            joinGroup(model)
            MInsetGroup(header: String(localized: "你的其它设备")) {
                if model.listedOtherDevices.isEmpty {
                    MInsetRow(icon: "icloud", iconColor: M.text3, label: String(localized: "还没有你的其它设备"),
                              sub: String(localized: "在另一台登录同一 Apple ID 的设备上打开 uTerm"), last: true)
                } else {
                    deviceRows(model.listedOtherDevices)
                }
            }
        }
    }

    private func deviceRows(_ devices: [RemoteGroupDevice]) -> some View {
        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
            MInsetRow(icon: glyph(for: device), iconColor: M.text3, label: device.name, sub: device.modelDetail,
                      last: index == devices.count - 1)
        }
    }

    // MARK: 还没进组

    @ViewBuilder
    private func joinGroup(_ model: RemoteDeviceGroup) -> some View {
        switch model.joinState {
        case .showingCode(let code, let attemptsLeft):
            MInsetGroup(footer: RemoteDeviceGroupCopy.codeCaption(attemptsLeft: attemptsLeft)) {
                VStack(spacing: 10) {
                    Text(RemoteDeviceGroupCopy.codeTitle)
                        .font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                        .multilineTextAlignment(.center)
                    Text(RemotePairingCode.grouped(code))
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .foregroundStyle(M.text)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .overlay(alignment: .bottom) { MRowDivider() }
                MInsetRow(icon: "x", label: String(localized: "取消"), danger: true, last: true) { model.cancelJoin() }
            }
        case .failed(let reason):
            MInsetGroup(footer: reason) {
                MInsetRow(icon: "warn", iconColor: M.danger, label: RemoteDeviceGroupCopy.failedTitle)
                MInsetRow(icon: "check", label: String(localized: "好"), last: true) { model.cancelJoin() }
            }
        case .joined, nil:
            MInsetGroup(footer: RemoteDeviceGroupCopy.intro + RemoteDeviceGroupCopy.howToJoin) {
                MInsetRow(icon: glyph(for: model.local), label: model.local.name,
                          sub: [RemoteDeviceGroupCopy.thisDevice, RemoteDeviceGroupCopy.notJoined].joined(separator: " · "),
                          last: false)
                MInsetRow(icon: "plus", label: String(localized: "加入"), last: true) {
                    model.startJoin()
                    service.poke()
                }
            }
        }
    }

    // MARK: 已进组

    private func memberGroup(_ model: RemoteDeviceGroup) -> some View {
        MInsetGroup(header: String(localized: "设备组"), footer: RemoteDeviceGroupCopy.groupFooter) {
            if let waiting = model.awaitingAcknowledgement {
                MInsetRow(icon: "clock", iconColor: M.text3, label: RemoteDeviceGroupCopy.awaiting(waiting))
            }
            ForEach(Array(model.members.enumerated()), id: \.element.id) { index, row in
                MInsetRow(icon: glyph(for: row.device), label: row.device.name,
                          sub: RemoteDeviceGroupCopy.memberSubtitle(row), last: index == model.members.count - 1,
                          trailing: AnyView(menu(for: row, model: model)))
            }
        }
    }

    private func menu(for row: RemoteDeviceGroup.MemberRow, model: RemoteDeviceGroup) -> some View {
        MMenu {
            if row.isLocal {
                Button("离开…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmingLeave = true }
            } else {
                Button("移除…", systemImage: "minus.circle", role: .destructive) {
                    removing = RemoteGroupRemovalPlan(target: row.device, cascade: model.devicesAdmitted(by: row.device.id))
                }
            }
        } label: {
            MIcon(name: "ellipsis", size: 16, color: M.text3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }

    private func glyph(for device: RemoteGroupDevice) -> String { device.mGlyph }
}

/// 移除前的确认：列出由它加进来的设备（默认一起移除，可以取消勾选）。`onDone(nil)` 是取消。
private struct RemoveMemberSheet: View {
    @State var plan: RemoteGroupRemovalPlan
    let onDone: ([UUID]?) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(RemoteDeviceGroupCopy.removeTitle(plan.target))
                        .font(M.sans(18, weight: .bold)).foregroundStyle(M.text)
                        .multilineTextAlignment(.center)
                    Text(RemoteDeviceGroupCopy.removeMessage)
                        .font(M.sans(13)).foregroundStyle(M.text3)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                if !plan.cascade.isEmpty {
                    MInsetGroup(header: RemoteDeviceGroupCopy.cascadeHeader) {
                        ForEach(Array(plan.cascade.enumerated()), id: \.element.id) { index, device in
                            MInsetRow(label: device.name, sub: device.modelDetail, last: index == plan.cascade.count - 1,
                                      trailing: AnyView(MCheck(checked: plan.includes(device.id)) { plan.set(device.id, included: $0) }))
                        }
                    }
                }
                VStack(spacing: 10) {
                    MBtn(title: String(localized: "移除"), kind: .danger, full: true) { onDone(plan.ids) }
                    MBtn(title: String(localized: "取消"), kind: .secondary, full: true) { onDone(nil) }
                }
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: M.readableWidth)
            .frame(maxWidth: .infinity)
        }
    }
}
