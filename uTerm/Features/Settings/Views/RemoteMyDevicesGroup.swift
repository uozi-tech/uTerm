import SwiftUI
import UDesignKit

/// 设置 › 远程控制 › 我的设备：同一 Apple ID 下的其它设备，在这里确认（两台设备核对同一个 6 位数）。
/// 状态与操作在共享的 `RemoteSiblingDevices`；页面开着时才轮询名册。
struct RemoteMyDevicesGroup: View {
    @State private var model = RemoteSiblingDevices.live()

    var body: some View {
        SettingsGroup(title: "我的设备", footer: RemoteSiblingCopy.footer) {
            if let model {
                content(model)
            } else {
                SettingsEmptyRow(symbol: "exclamationmark.triangle", text: String(localized: "读不到这台 Mac 的远程控制身份（钥匙串不可用）"))
            }
        }
        .task {
            guard let model else { return }
            await model.run()
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteSiblingDevices) -> some View {
        ForEach(model.incoming) { incoming in
            SettingsCenteredBlock(caption: RemoteSiblingCopy.incomingDetail(incoming.voucher)) {
                codeBlock(title: RemoteSiblingCopy.incomingTitle(incoming.voucher), code: incoming.code)
            }
            .settingsDivider(inset: nil)
        }
        if let confirmation = model.confirmation {
            confirmationBlock(confirmation, model: model)
                .settingsDivider(inset: nil)
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
        case .comparing(let device, let code):
            SettingsCenteredBlock(caption: RemoteSiblingCopy.comparingDetail) {
                VStack(spacing: 10) {
                    codeBlock(title: RemoteSiblingCopy.comparingTitle(device), code: code)
                    HStack(spacing: 8) {
                        UDButton(title: "不一致", style: .secondary) { model.cancel() }
                        UDButton(title: "一致", style: .primary) { model.accept() }
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

    private func codeBlock(title: String, code: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(UD.text)
            Text(RemotePairingCode.grouped(code))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundStyle(UD.text)
                .textSelection(.enabled)
        }
    }

    private func symbol(for device: RemoteSiblingDevice) -> String {
        let name = device.model ?? device.name
        guard device.isMac else { return settingsDeviceSymbol(for: name) }
        return name.localizedCaseInsensitiveContains("MacBook") ? "laptopcomputer" : "desktopcomputer"
    }
}
