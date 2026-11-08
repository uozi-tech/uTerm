import SwiftUI
import UDesignKit

/// 欢迎窗口里的「我的 Mac」面板：从这台 Mac 去控制别的 Mac。列配对过的与局域网里还没配对的，点「打开」开它的窗口
///（`RemoteMacWindowView`）；不在同一网络的，粘贴那台 Mac 设置里拷出的邀请链接配对。
struct RemoteMacsPane: View {
    @Environment(RemoteMacDirectory.self) private var directory
    @Environment(\.openWindow) private var openWindow
    @State private var pasting = false
    /// 打开链接带来的邀请：预先填进粘贴框。
    @State private var linkText = ""
    @State private var forgetting: RemoteMacDirectory.Mac?

    var body: some View {
        // 欢迎窗口整窗一块卡面色，这里跟着用 UD.panel，不另起卡片。
        SettingsScroll(background: UD.panel) {
            SettingsPageHeader(title: String(localized: "控制其他 Mac"),
                               subtitle: String(localized: "打开另一台 Mac 上的终端。每台 Mac 第一次连接都要配对，配对是单向的：这里配上的 Mac 不能反过来控制这台。"))
            pairedGroup
            if !directory.nearbyMacs.isEmpty { nearbyGroup }
        }
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
                if let mac { openWindow(value: RemoteMacWindowID(macID: mac.id)) }
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

    private var pairedGroup: some View {
        SettingsGroup(title: String(localized: "已配对"),
                      footer: String(localized: "不在同一网络的 Mac：在它的「设置 › 远程控制」里显示邀请并拷贝链接，粘贴到这里。")) {
            SettingsListRow(icon: "link", tint: UD.accent, title: String(localized: "粘贴邀请链接"),
                            subtitle: String(localized: "uterm://pair 开头，10 分钟内有效")) {
                UDButton(title: "粘贴…", style: .secondary) { pasting = true }
            }
            if directory.macs.isEmpty {
                SettingsEmptyRow(symbol: "desktopcomputer", text: String(localized: "还没有配对的 Mac"))
            } else {
                ForEach(directory.macs) { mac in
                    SettingsListRow(icon: "desktopcomputer", tint: mac.isOnline ? UD.success : UD.text4,
                                    title: mac.name, subtitle: Self.status(of: mac)) {
                        HStack(spacing: 6) {
                            UDButton(title: "打开", style: .secondary) {
                                openWindow(value: RemoteMacWindowID(macID: mac.id))
                            }
                            .disabled(!mac.isOnline)
                            SettingsMoreMenu(items: [
                                UDMenuItem(label: String(localized: "查看屏幕"), systemImage: "display") {
                                    openWindow(value: RemoteDesktopWindowID(macID: mac.id))
                                },
                                UDMenuItem(label: String(localized: "网络诊断"), systemImage: "stethoscope") {
                                    openWindow(value: RemoteDiagnosticsWindowID(macID: mac.id))
                                },
                                UDMenuItem(label: String(localized: "忘记这台 Mac…"), systemImage: "xmark.circle",
                                           danger: true) { forgetting = mac },
                            ])
                        }
                    }
                }
            }
        }
    }

    private var nearbyGroup: some View {
        SettingsGroup(title: String(localized: "附近的 Mac"),
                      footer: String(localized: "同一局域网里打开了远程控制、还没配对的 Mac。点「配对」后在那台 Mac 上核对数字并点「允许」。")) {
            ForEach(directory.nearbyMacs) { mac in
                SettingsListRow(icon: "desktopcomputer", tint: UD.accent, title: mac.name, subtitle: nil) {
                    UDButton(title: "配对…", style: .secondary) {
                        openWindow(value: RemoteMacWindowID(macID: mac.id))
                    }
                }
            }
        }
    }

    static func status(of mac: RemoteMacDirectory.Mac) -> String {
        if mac.endpoint != nil { return String(localized: "在线 · 局域网") }
        if mac.isOnRelay { return String(localized: "在线 · 公网") }
        return String(localized: "不在线")
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
