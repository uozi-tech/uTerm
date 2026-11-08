import AppKit
import SwiftUI
import UDesignKit

/// 欢迎窗口里的「我的 Mac」：从这台 Mac 去控制别的 Mac。与「全部」「快捷命令」同构——左列表、右详情。
///
/// 左列配对过的（在上）与局域网里还没配对的（另起一组），双击打开它的窗口（`RemoteMacWindowView`，
/// 没配对的在那里走配对）；不在同一网络的，粘贴那台 Mac 设置里拷出的邀请链接配对。
/// 右栏是选中那台的详情：在线状态与路径、打开终端 / 屏幕、网络诊断、忘记。
struct RemoteMacsPane: View {
    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.openWindow) private var openWindow
    @State private var pasting = false
    /// 打开链接带来的邀请：预先填进粘贴框。
    @State private var linkText = ""
    @State private var forgetting: RemoteMacDirectory.Mac?
    @State private var selectedID: String?
    /// 一进来先选中哪台（截图用例用）；nil = 第一台。
    var initialSelectionID: String?

    private var allMacs: [RemoteMacDirectory.Mac] { directory.macs + directory.nearbyMacs }

    private var selected: RemoteMacDirectory.Mac? {
        guard let selectedID else { return nil }
        return allMacs.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if allMacs.isEmpty {
                RemoteMacsEmptyState { pasting = true }
            } else {
                HStack(spacing: 0) {
                    listColumn
                    if let selected {
                        RemoteMacDetailPanel(mac: selected,
                                             onOpen: { open(selected) },
                                             onOpenScreen: { openWindow(value: RemoteDesktopWindowID(macID: selected.id)) },
                                             onDiagnose: { openWindow(value: RemoteDiagnosticsWindowID(macID: selected.id)) },
                                             onForget: { forgetting = selected })
                            .id(selected.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 欢迎窗口整窗一块卡面色，主从两栏同底色、靠竖线分开（分区方案 v3.4）。
        .background(UD.panel)
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: allMacs.map(\.id)) { _, _ in selectFirstIfNeeded() }
        // 列表在看时按间隔问中继谁在线；关掉窗口、切走这一栏就不再问。
        .task { await directory.keepLiveStatusFresh() }
        .onAppear {
            if directory.isActivated { directory.startBrowsing() } else { directory.activate() }
            takePendingInvitation()
        }
        .onChange(of: directory.pendingInvitation) { _, _ in takePendingInvitation() }
        .sheet(isPresented: $pasting, onDismiss: { linkText = "" }) {
            RemotePairingLinkSheet(initialText: linkText) { mac in
                pasting = false
                if let mac {
                    selectedID = mac.id
                    openWindow(value: RemoteMacWindowID(macID: mac.id))
                }
            }
        }
        .alert("忘记「\(forgetting?.name ?? "")」？",
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
               presenting: forgetting) { mac in
            Button("忘记", role: .destructive) { directory.forget(mac) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("这台 Mac 不再出现在这里，再连要重新配对。它上面的终端不受影响。")
        }
    }

    private func takePendingInvitation() {
        guard let invitation = directory.pendingInvitation else { return }
        directory.pendingInvitation = nil
        linkText = invitation.url.absoluteString
        pasting = true
    }

    private func selectFirstIfNeeded() {
        if let selectedID, allMacs.contains(where: { $0.id == selectedID }) { return }
        selectedID = allMacs.first { $0.id == initialSelectionID }?.id ?? allMacs.first?.id
    }

    /// 打开这台 Mac 的窗口：配对过的直接连，没配对的在窗口里走配对。不在线的配对过的 Mac 打不开。
    private func open(_ mac: RemoteMacDirectory.Mac) {
        guard mac.source == .nearby || mac.isOnline else { return }
        openWindow(value: RemoteMacWindowID(macID: mac.id))
    }

    // MARK: 左列表

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Text("我的 Mac")
                        .font(.system(size: 12))
                        .foregroundStyle(UD.text3)
                        .tracking(0.3)
                    Text(verbatim: "· \(directory.macs.count)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(UD.text4)
                }
                Spacer()
                UDButton(title: String(localized: "粘贴邀请链接…"), style: .secondary, systemImage: "link") {
                    pasting = true
                }
                .controlSize(.small)
                .help(Text("不在同一网络的 Mac：在它的「设置 › 远程控制」里显示邀请并拷贝链接，粘贴到这里。"))
            }
            .padding(.horizontal, 16)
            // 分区方案 v3：列表头并入卡顶，无底线（同快捷命令列表）。
            .frame(height: 44)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sectionHeader("已配对")
                    if directory.macs.isEmpty {
                        Text("还没有配对的 Mac")
                            .font(.system(size: 12))
                            .foregroundStyle(UD.text3)
                            .padding(.horizontal, ServerRowLayout.contentPadding)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(directory.macs) { row($0) }
                    }
                    if !directory.nearbyMacs.isEmpty {
                        sectionHeader("附近的 Mac").padding(.top, 10)
                        ForEach(directory.nearbyMacs) { row($0) }
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(UD.text4)
            .tracking(0.3)
            .padding(.horizontal, ServerRowLayout.contentPadding)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func row(_ mac: RemoteMacDirectory.Mac) -> some View {
        RemoteMacRow(mac: mac, isSelected: selectedID == mac.id,
                     onSelect: { selectedID = mac.id },
                     onOpen: {
                         selectedID = mac.id
                         open(mac)
                     })
            .contextMenu { contextMenu(for: mac) }
    }

    @ViewBuilder
    private func contextMenu(for mac: RemoteMacDirectory.Mac) -> some View {
        if mac.source == .nearby {
            Button("配对…") { open(mac) }
        } else {
            Button("打开终端") { open(mac) }.disabled(!mac.isOnline)
            Button("打开屏幕") { openWindow(value: RemoteDesktopWindowID(macID: mac.id)) }
            Button("网络诊断") { openWindow(value: RemoteDiagnosticsWindowID(macID: mac.id)) }
            Divider()
            Button("忘记这台 Mac…", role: .destructive) { forgetting = mac }
        }
    }

    /// 列表行与详情共用的一行状态：「在线 · 局域网」「在线 · 公网」「不在线」；没配对的是「局域网 · 未配对」。
    static func status(of mac: RemoteMacDirectory.Mac) -> String {
        if mac.source == .nearby { return String(localized: "局域网 · 未配对") }
        if mac.endpoint != nil { return String(localized: "在线 · 局域网") }
        if mac.isOnRelay { return String(localized: "在线 · 公网") }
        return String(localized: "不在线")
    }

    /// 状态点与图标的颜色：在线绿、没配对强调色、不在线灰。
    static func tint(of mac: RemoteMacDirectory.Mac) -> Color {
        if mac.source == .nearby { return UD.accent }
        return mac.isOnline ? UD.success : UD.text4
    }
}

// MARK: - 列表行

/// 一台 Mac：图标 + 名字 + 状态。选中 / 悬停与主机列表同样铺满整行的中性灰。
///
/// 单击选中、双击打开：只挂一个单击手势，在里面读 `NSApp.currentEvent?.clickCount`。
/// 不用 `onTapGesture(count: 2)`——它会让单击也等满系统双击间隔才响应。
private struct RemoteMacRow: View {
    let mac: RemoteMacDirectory.Mac
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            SettingsListIcon.symbol("desktopcomputer", RemoteMacsPane.tint(of: mac))
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(UD.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(RemoteMacsPane.status(of: mac))
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
        }
        .padding(ServerRowLayout.contentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture {
            onSelect()
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { onOpen() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect() }
        .accessibilityAction(named: Text("打开")) { onOpen() }
    }

    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.06) }
        if hover { return Color.primary.opacity(0.028) }
        return .clear
    }
}

// MARK: - 详情

/// 选中那台 Mac 的详情：状态、路径与往返、配对时间，底部动作。宽度与主机详情一致。
private struct RemoteMacDetailPanel: View {
    let mac: RemoteMacDirectory.Mac
    let onOpen: () -> Void
    let onOpenScreen: () -> Void
    let onDiagnose: () -> Void
    let onForget: () -> Void

    @Environment(RemoteMacDirectory.self) private var directory
    /// 开着这台 Mac 窗口时的那条连接（目录里的 `clients` 不在观察跟踪里，见 `existingClient`）。
    @State private var client: RemoteMacClient?
    @State private var pairedAt: Date?

    private var isNearby: Bool { mac.source == .nearby }
    private var connectedClient: RemoteMacClient? { client?.state == .connected ? client : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            statusLine.padding(.top, 6)
            if isNearby {
                Text("同一局域网里打开了远程控制、还没配对的 Mac。点「配对」后在那台 Mac 上核对数字并点「允许」。")
                    .font(.system(size: 12))
                    .foregroundStyle(UD.text3)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 18)
            } else {
                metaGrid.padding(.top, 22)
            }
            Spacer(minLength: 16)
            actions
        }
        .padding(EdgeInsets(top: 22, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        // 分区方案 v3.3：与左侧列表同为卡面色，靠 1pt 竖线分开（同主机详情）。
        .overlay(alignment: .leading) { Rectangle().fill(UD.border).frame(width: 1) }
        .task(id: mac.id) { await track() }
    }

    /// 连接是开窗口时才建的、目录不通知：看着详情时每秒取一次。拿到之后它自己是 `@Observable`。
    private func track() async {
        if let deviceID = mac.deviceID { pairedAt = directory.identity.peer(id: deviceID)?.pairedAt }
        while !Task.isCancelled {
            let current = directory.existingClient(macID: mac.id)
            if current !== client { client = current }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            SettingsListIcon.symbol("desktopcomputer", RemoteMacsPane.tint(of: mac))
            Text(mac.name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(UD.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(mac.name)
            Spacer(minLength: 0)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(RemoteMacsPane.tint(of: mac)).frame(width: 6, height: 6)
            Text(connectedClient == nil ? RemoteMacsPane.status(of: mac) : String(localized: "已连接"))
                .font(.system(size: 12))
                .foregroundStyle(UD.text2)
        }
        .accessibilityElement(children: .combine)
    }

    private var metaGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 18) {
            GridRow {
                DetailMetaCell(label: String(localized: "网络路径"), value: pathText)
                DetailMetaCell(label: String(localized: "往返"), value: roundTripText, mono: true)
            }
            GridRow {
                DetailMetaCell(label: String(localized: "中继"), value: relayText)
                DetailMetaCell(label: String(localized: "配对时间"),
                               value: pairedAt.map { UTermFormat.date($0) } ?? "—", mono: pairedAt != nil)
            }
        }
    }

    /// 连上了就是这条连接实际走的路；没连上时只知道目录看到的：局域网里在、中继上在，或都不在。
    private var pathText: String {
        if let path = connectedClient?.path { return path.label }
        if mac.endpoint != nil { return String(localized: "局域网") }
        if mac.isOnRelay { return String(localized: "公网") }
        return String(localized: "不在线")
    }

    private var roundTripText: String {
        guard let millis = connectedClient?.roundTripMillis else { return "—" }
        return "\(millis) ms"
    }

    private var relayText: String {
        mac.relay?.name ?? directory.relayServerName() ?? String(localized: "未设置")
    }

    @ViewBuilder
    private var actions: some View {
        if isNearby {
            DetailActionButton(title: "配对…", shortcutHint: "↵", prominent: true, action: onOpen)
                .keyboardShortcut(.return, modifiers: [])
        } else {
            VStack(spacing: 9) {
                DetailActionButton(title: "打开终端", systemImage: "terminal", shortcutHint: "↵", prominent: true,
                                   action: onOpen)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!mac.isOnline)
                HStack(spacing: 8) {
                    DetailActionButton(title: "打开屏幕", systemImage: "display", action: onOpenScreen)
                    DetailActionButton(title: "网络诊断", systemImage: "stethoscope", action: onDiagnose)
                }
                UDButton(title: String(localized: "忘记这台 Mac…"), style: .ghost, action: onForget)
                    .padding(.top, 2)
            }
        }
    }
}

// MARK: - 空态

/// 一台 Mac 都没有（没配对过、局域网里也没看到）时的大空态。
struct RemoteMacsEmptyState: View {
    let onPaste: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(UD.text4)
            Text("还没有配对的 Mac")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(UD.text)
                .padding(.top, 16)
            Text("打开另一台 Mac 上的终端。每台 Mac 第一次连接都要配对，配对是单向的：这里配上的 Mac 不能反过来控制这台。")
                .font(.system(size: 12.5))
                .foregroundStyle(UD.text3)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)
                .padding(.top, 8)
            Text("同一局域网里打开了远程控制的 Mac 会自动出现在这里；不在同一网络的，在它的「设置 › 远程控制」里显示邀请并拷贝链接，粘贴到这里。")
                .font(.system(size: 12))
                .foregroundStyle(UD.text4)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 380)
                .padding(.top, 10)
            UDButton(title: String(localized: "粘贴邀请链接…"), style: .primary, systemImage: "link", action: onPaste)
                .padding(.top, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

/// 粘贴邀请链接：先给人看是哪台 Mac、会不会带上中继，确认后配对。
private struct RemotePairingLinkSheet: View {
    var initialText = ""
    let onDone: (RemoteMacDirectory.Mac?) -> Void

    @Environment(RemoteMacDirectory.self) private var directory
    @State private var text = ""
    @State private var failure: String?

    private var invitation: RemotePairingInvitation? { RemotePairingInvitation(scanned: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("粘贴邀请链接").font(.system(size: 15, weight: .semibold)).foregroundStyle(UD.text)
            UDTextField(placeholder: "uterm://pair?…", text: $text)
            if let invitation {
                SettingsInlineNote(tone: .neutral, text: Self.summary(invitation))
            } else if !text.isEmpty {
                SettingsInlineNote(tone: .warning, text: String(localized: "这不是 uTerm 的邀请链接。"))
            }
            if let failure {
                SettingsInlineNote(tone: .warning, text: failure)
            }
            HStack {
                Spacer()
                UDButton(title: "取消", style: .secondary) { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                UDButton(title: "配对") { pair() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(invitation == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
        .background(UD.bg)
        .onAppear {
            if !initialText.isEmpty {
                text = initialText
            } else if let pasted = NSPasteboard.general.string(forType: .string),
                      RemotePairingInvitation(scanned: pasted) != nil {
                text = pasted
            }
        }
    }

    private func pair() {
        guard let invitation else { return }
        guard invitation.macID != RemoteLocalDevice.id() else {
            failure = String(localized: "这是这台 Mac 自己的邀请。")
            return
        }
        do {
            onDone(try directory.pair(with: invitation))
        } catch {
            failure = String(localized: "保存到钥匙串失败：\(error.localizedDescription)")
        }
    }

    static func summary(_ invitation: RemotePairingInvitation) -> String {
        guard let relay = invitation.relay else {
            return String(localized: "将与「\(invitation.macName)」配对。这张邀请没带中继，只能在同一局域网里连接。")
        }
        return String(localized: "将与「\(invitation.macName)」配对，并经它的中继「\(relay.name)」在外网连接。")
    }
}
