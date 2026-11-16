import SwiftUI

/// 设置 › 远程控制 › 我的设备：同一 Apple ID 下的其它设备，在这里确认（两台设备核对同一个 6 位数）。
/// 状态与操作在共享的 `RemoteSiblingDevices`；这一页开着时才轮询名册。
struct RemoteMyDevicesScreen: View {
    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(RemoteSiblingService.self) private var service
    /// 输入框里的核对码。
    @State private var codeText = ""

    private var model: RemoteSiblingDevices? { service.model }
    /// 等确认要报告丢失的那台。
    @State private var reportingLost: RemoteSiblingDevice?

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
        // 替别的设备开通要问到配对过的 Mac：页面开着时问中继谁在线（局域网浏览要用户在主机页打开过，这里不替他打开）。
        .task {
            service.ensureModel()
            await service.keepActive()
        }
        .task { await directory.keepLiveStatusFresh() }
        .confirmationDialog(RemoteSiblingCopy.lostConfirmTitle(reportingLost?.name ?? ""),
                            isPresented: Binding(get: { reportingLost != nil }, set: { if !$0 { reportingLost = nil } }),
                            titleVisibility: .visible) {
            Button("报告丢失", role: .destructive) {
                if let device = reportingLost { model?.markLost(device.id) }
                reportingLost = nil
            }
            Button("取消", role: .cancel) { reportingLost = nil }
        } message: {
            Text(RemoteSiblingCopy.lostConfirmMessage)
        }
    }

    @ViewBuilder
    private func content(_ model: RemoteSiblingDevices) -> some View {
        if let confirmation = model.confirmation {
            confirmationGroup(confirmation, model: model)
        }
        if model.localReportedLost {
            MInsetGroup {
                MInsetRow(icon: "warn", iconColor: M.danger, label: "这台设备被报告丢失", sub: RemoteSiblingCopy.localLost, last: true)
            }
        }
        if !model.lost.isEmpty {
            MInsetGroup(header: RemoteSiblingCopy.lostHeader, footer: RemoteSiblingCopy.lostFooter) {
                ForEach(Array(model.lost.enumerated()), id: \.element.id) { index, item in
                    MInsetRow(icon: "warn", iconColor: M.danger, label: item.tombstone.deviceName, sub: item.subtitle,
                              last: index == model.lost.count - 1,
                              trailing: AnyView(MMenu {
                                  Button("找回来了，取消报告", systemImage: "arrow.uturn.backward") { model.clearLostReport(item.id) }
                              } label: {
                                  MIcon(name: "ellipsis", size: 16, color: M.text3).frame(width: 32, height: 32).contentShape(Rectangle())
                              }))
                }
            }
        }
        if !model.received.isEmpty {
            MInsetGroup(header: RemoteSiblingCopy.receivedHeader, footer: RemoteSiblingCopy.receivedFooter) {
                ForEach(Array(model.received.enumerated()), id: \.element.id) { index, item in
                    MInsetRow(icon: "mac", iconColor: item.status.isUsable ? nil : M.text3, label: item.hostName,
                              sub: item.subtitle, last: index == model.received.count - 1)
                }
            }
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
            Button("这台设备丢了…", systemImage: "exclamationmark.triangle", role: .destructive) { reportingLost = row.device }
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
        case .entering(let device, let attemptsLeft):
            MInsetGroup(footer: RemoteSiblingCopy.enteringDetail(attemptsLeft: attemptsLeft)) {
                VStack(spacing: 12) {
                    Text(RemoteSiblingCopy.enteringTitle(device))
                        .font(M.sans(15, weight: .semibold)).foregroundStyle(M.text)
                        .multilineTextAlignment(.center)
                    TextField("000000", text: $codeText)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: codeText) { _, text in
                            // 输满 6 位就核对，不用再点按钮。
                            guard text.filter(\.isNumber).count == RemoteSiblingCode.codeLength else { return }
                            model.submitCode(text)
                            codeText = ""
                        }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                MInsetRow(icon: "x", label: "取消", danger: true, last: true) {
                    codeText = ""
                    model.cancel()
                }
            }
        case .failed(_, let reason):
            MInsetGroup(footer: reason) {
                MInsetRow(icon: "warn", iconColor: M.danger, label: "确认没有完成")
                MInsetRow(icon: "check", label: "好", last: true) { model.cancel() }
            }
        }
    }

    private func glyph(for device: RemoteSiblingDevice) -> String {
        if device.isMac { return "mac" }
        return (device.model ?? device.name).localizedCaseInsensitiveContains("ipad") ? "ipad" : "iphone"
    }
}
