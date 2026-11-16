import SwiftUI

/// 设置 › 远程控制 › 我的设备：同一 Apple ID 下的其它设备，在这里确认（两台设备核对同一个 6 位数）。
/// 状态与操作在共享的 `RemoteSiblingDevices`；这一页开着时才轮询名册。
struct RemoteMyDevicesScreen: View {
    @State private var model = RemoteSiblingDevices.live()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let model {
                    content(model)
                } else {
                    MInsetGroup(footer: RemoteSiblingCopy.footer) {
                        MInsetRow(icon: "warn", iconColor: M.danger, label: "读不到这台设备的远程控制身份",
                                  sub: "钥匙串不可用", last: true)
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
            guard let model else { return }
            await model.run()
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteSiblingDevices) -> some View {
        ForEach(model.incoming) { incoming in
            MInsetGroup(footer: RemoteSiblingCopy.incomingDetail(incoming.voucher)) {
                codeBlock(title: RemoteSiblingCopy.incomingTitle(incoming.voucher), code: incoming.code)
            }
        }
        if let confirmation = model.confirmation {
            confirmationGroup(confirmation, model: model)
        }
        MInsetGroup(header: "我的设备", footer: RemoteSiblingCopy.footer) {
            if let error = model.storageError {
                MInsetRow(icon: "warn", iconColor: M.danger, label: error, last: model.rows.isEmpty)
            }
            if model.rows.isEmpty {
                MInsetRow(icon: "icloud", iconColor: M.text3, label: "还没有别的设备",
                          sub: "在你的其它设备上打开 uTerm 后会出现在这里", last: true)
            }
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                MInsetRow(icon: glyph(for: row.device), iconColor: row.needsConfirmation ? M.text3 : nil,
                          label: row.device.name, sub: row.subtitle, last: index == model.rows.count - 1,
                          trailing: AnyView(menu(for: row, model: model)))
            }
        }
    }

    private func menu(for row: RemoteSiblingDevices.Row, model: RemoteSiblingDevices) -> some View {
        MMenu {
            if row.needsConfirmation {
                Button("确认…", systemImage: "checkmark.shield") { model.confirm(row.id) }
            } else {
                Button("取消确认", systemImage: "xmark.circle") { model.forgetConfirmation(row.id) }
            }
            Button("从名单移除", systemImage: "trash", role: .destructive) { model.remove(row.id) }
        } label: {
            MIcon(name: "ellipsis", size: 16, color: M.text3)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private func confirmationGroup(_ confirmation: RemoteSiblingDevices.Confirmation,
                                   model: RemoteSiblingDevices) -> some View {
        switch confirmation {
        case .waiting(let device):
            MInsetGroup(footer: RemoteSiblingCopy.waitingDetail(device)) {
                MInsetRow(icon: "refresh", label: RemoteSiblingCopy.waitingTitle(device),
                          trailing: AnyView(ProgressView()))
                MInsetRow(icon: "x", label: "取消", danger: true, last: true) { model.cancel() }
            }
        case .comparing(let device, let code):
            MInsetGroup(footer: RemoteSiblingCopy.comparingDetail) {
                codeBlock(title: RemoteSiblingCopy.comparingTitle(device), code: code)
                MInsetRow(icon: "check", iconColor: M.success, label: "一致") { model.accept() }
                MInsetRow(icon: "x", label: "不一致", danger: true, last: true) { model.cancel() }
            }
        case .failed(_, let reason):
            MInsetGroup(footer: reason) {
                MInsetRow(icon: "warn", iconColor: M.danger, label: "确认没有完成")
                MInsetRow(icon: "check", label: "好", last: true) { model.cancel() }
            }
        }
    }

    private func codeBlock(title: String, code: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                .multilineTextAlignment(.center)
            Text(RemotePairingCode.grouped(code))
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .foregroundStyle(M.text)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
    }

    private func glyph(for device: RemoteSiblingDevice) -> String {
        if device.isMac { return "mac" }
        return (device.model ?? device.name).localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }
}
