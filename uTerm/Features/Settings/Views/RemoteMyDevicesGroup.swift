import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 我的设备：同一 Apple ID 下的其它设备，在这里确认（在本机输入对方显示的 6 位数）。
/// 状态在 App 级的 `RemoteSiblingService`（全 App 一个、后台一直在读名册）；别的设备来确认本机时由
/// `RemoteSiblingPrompt` 单独弹面板，不在这一页。页面开着时轮询改快。
struct RemoteMyDevicesGroup: View {
    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(RemoteSiblingService.self) private var service
    /// 等确认要报告丢失的那台。
    @State private var reportingLost: RemoteSiblingDevice?
    /// 输入框里的核对码。
    @State private var codeText = ""

    private var model: RemoteSiblingDevices? { service.model }

    var body: some View {
        SettingsGroup(title: "我的设备", footer: RemoteSiblingCopy.footer) {
            if let model {
                content(model)
            } else {
                SettingsEmptyRow(symbol: "exclamationmark.triangle", text: String(localized: "读不到这台 Mac 的远程控制身份（钥匙串不可用）"))
            }
        }
        // 替别的设备开通要问到配对过的 Mac：页面开着时找局域网里的 Mac、问中继谁在线。
        .task {
            service.ensureModel()
            if directory.isActivated { directory.startBrowsing() }
            await service.keepActive()
        }
        .task { await directory.keepLiveStatusFresh() }
        .alert(RemoteSiblingCopy.lostConfirmTitle(reportingLost?.name ?? ""),
               isPresented: Binding(get: { reportingLost != nil }, set: { if !$0 { reportingLost = nil } })) {
            Button("取消", role: .cancel) { reportingLost = nil }
            Button("报告丢失", role: .destructive) {
                if let device = reportingLost { model?.markLost(device.id) }
                reportingLost = nil
            }
        } message: {
            Text(RemoteSiblingCopy.lostConfirmMessage)
        }
        if let model, !model.lost.isEmpty {
            SettingsGroup(title: RemoteSiblingCopy.lostHeader, footer: RemoteSiblingCopy.lostFooter) {
                ForEach(model.lost) { item in
                    SettingsListRow(icon: "exclamationmark.triangle", tint: UD.danger, title: item.tombstone.deviceName,
                                    subtitle: item.subtitle) {
                        SettingsMoreMenu(items: [
                            UDMenuItem(label: String(localized: "找回来了，取消报告"), systemImage: "arrow.uturn.backward") {
                                model.clearLostReport(item.id)
                            },
                        ])
                    }
                }
            }
        }
        if let model, !model.received.isEmpty {
            SettingsGroup(title: RemoteSiblingCopy.receivedHeader, footer: RemoteSiblingCopy.receivedFooter) {
                ForEach(model.received) { item in
                    SettingsListRow(icon: "desktopcomputer", tint: item.status.isUsable ? UD.accent : UD.text3,
                                    title: item.hostName, subtitle: item.subtitle) { EmptyView() }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteSiblingDevices) -> some View {
        if let confirmation = model.confirmation {
            confirmationBlock(confirmation, model: model)
                .settingsDivider(inset: nil)
        }
        if model.localReportedLost {
            SettingsListRow(icon: "exclamationmark.triangle", tint: UD.danger, title: RemoteSiblingCopy.localLost) { EmptyView() }
        }
        if let error = model.storageError {
            SettingsListRow(icon: "exclamationmark.triangle", tint: UD.danger, title: error) { EmptyView() }
        }
        if model.rows.isEmpty {
            SettingsEmptyRow(symbol: "laptopcomputer.and.iphone",
                             text: String(localized: "还没有别的设备。在你的 iPhone、iPad 或其它 Mac 上打开 uTerm 后会出现在这里"))
        } else {
            ForEach(model.rows) { row in
                SettingsListRow(icon: symbol(for: row.device),
                                tint: row.needsConfirmation ? UD.text3 : UD.accent,
                                title: row.device.name, subtitle: row.subtitle) {
                    HStack(spacing: 8) {
                        if row.needsConfirmation {
                            UDButton(title: "确认…", style: .secondary) { model.confirm(row.id) }
                                .disabled(model.confirmation?.device.id == row.id)
                        }
                        SettingsMoreMenu(items: menuItems(for: row, model: model),
                                         help: String(localized: "从名单移除后，它下次打开 uTerm 会重新出现，要重新确认"))
                    }
                }
            }
        }
    }

    private func menuItems(for row: RemoteSiblingDevices.Row, model: RemoteSiblingDevices) -> [UDMenuItem] {
        var items: [UDMenuItem] = []
        if !row.needsConfirmation {
            items.append(UDMenuItem(label: String(localized: "取消确认"), systemImage: "xmark.circle") {
                model.forgetConfirmation(row.id)
            })
        }
        items.append(UDMenuItem(label: String(localized: "从名单移除"), systemImage: "trash", danger: true) {
            model.remove(row.id)
        })
        items.append(UDMenuItem(label: String(localized: "这台设备丢了…"), systemImage: "exclamationmark.triangle", danger: true) {
            reportingLost = row.device
        })
        return items
    }

    @ViewBuilder
    private func confirmationBlock(_ confirmation: RemoteSiblingDevices.Confirmation,
                                   model: RemoteSiblingDevices) -> some View {
        switch confirmation {
        case .waiting(let device):
            SettingsCenteredBlock(caption: RemoteSiblingCopy.waitingDetail(device)) {
                VStack(spacing: 10) {
                    Text(RemoteSiblingCopy.waitingTitle(device))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(UD.text)
                    ProgressView().controlSize(.small)
                    UDButton(title: "取消", style: .secondary) { model.cancel() }
                }
            }
        case .entering(let device, let attemptsLeft):
            SettingsCenteredBlock(caption: RemoteSiblingCopy.enteringDetail(attemptsLeft: attemptsLeft)) {
                VStack(spacing: 10) {
                    Text(RemoteSiblingCopy.enteringTitle(device))
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(UD.text)
                    HStack(spacing: 8) {
                        UDTextField(placeholder: "000 000", text: $codeText, autoFocus: true)
                            .frame(width: 140)
                            .onSubmit { submit(model) }
                        UDButton(title: "核对", style: .primary) { submit(model) }
                            .disabled(codeText.filter(\.isNumber).count != RemoteSiblingCode.codeLength)
                        UDButton(title: "取消", style: .secondary) {
                            codeText = ""
                            model.cancel()
                        }
                    }
                }
            }
        case .failed(_, let reason):
            SettingsCenteredBlock(caption: reason) {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 20)).foregroundStyle(UD.danger)
                    UDButton(title: "好", style: .secondary) { model.cancel() }
                }
            }
        }
    }

    private func submit(_ model: RemoteSiblingDevices) {
        if model.submitCode(codeText) || model.confirmation == nil { codeText = "" }
    }

    private func symbol(for device: RemoteSiblingDevice) -> String {
        let name = device.model ?? device.name
        guard device.isMac else { return settingsDeviceSymbol(for: name) }
        return name.localizedCaseInsensitiveContains("MacBook") ? "laptopcomputer" : "desktopcomputer"
    }
}
