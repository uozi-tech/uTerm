import SwiftUI

/// 端口转发编辑器的保存载荷（纯值类型）。`ForwardEditorSheet` 校验通过后产出，
/// 由 `PortForwardListView.save(_:)` 写入 `modelContext`/`ForwardingRuleStore`。
/// `editingID` 非 nil = 编辑既有规则，nil = 新建。
struct ForwardEditorDraft: Equatable {
    let editingID: UUID?
    let name: String
    let kind: ForwardKind
    let listenHost: String
    let listenPort: Int
    let destHost: String?
    let destPort: Int
    let autostart: Bool
}

/// 新建 / 编辑端口转发规则的浮层卡（设计稿 `pages/port-forwarding.jsx` 的 `ForwardEditor`）。
///
/// 460pt 卡：类型 `UDSegmented` + 类型说明、备注名称、监听段（地址 flex2 / 端口 flex1）、
/// 目标段（主机 / 端口，dynamic 隐藏）、autostart 行、`ssh` 命令预览（终端底色 mono）。
///
/// 实时校验经 `PortConflictChecker`（对比其它规则的 snapshot + 知名端口表）：端口框标红
/// +「端口 X 已被『Y』占用」+「改用 N」建议 chip（点击填入 `suggestFreePort`）；冲突未解决
/// 禁用保存、底部「端口冲突，请先解决」；`<1024` 非阻断 amber 警告。
struct ForwardEditorSheet: View {
    let server: ServerProfile
    let existing: ForwardingRule?
    let allRules: [ForwardingRuleSnapshot]
    let onCancel: () -> Void
    let onSave: (ForwardEditorDraft) -> Void

    @State private var kind: ForwardKind
    @State private var name: String
    @State private var listenHost: String
    @State private var listenPortText: String
    @State private var destHost: String
    @State private var destPortText: String
    @State private var autostart: Bool

    init(server: ServerProfile,
         existing: ForwardingRule?,
         allRules: [ForwardingRuleSnapshot],
         onCancel: @escaping () -> Void,
         onSave: @escaping (ForwardEditorDraft) -> Void) {
        self.server = server
        self.existing = existing
        self.allRules = allRules
        self.onCancel = onCancel
        self.onSave = onSave
        _kind = State(initialValue: existing?.kind ?? .local)
        _name = State(initialValue: existing?.name ?? "")
        _listenHost = State(initialValue: existing?.listenHost ?? "127.0.0.1")
        _listenPortText = State(initialValue: (existing?.listenPort).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _destHost = State(initialValue: existing?.destHost ?? "")
        _destPortText = State(initialValue: (existing?.destPort).flatMap { $0 > 0 ? String($0) : nil } ?? "")
        _autostart = State(initialValue: existing?.autostart ?? false)
    }

    private var hostName: String { server.name.isEmpty ? server.host : server.name }
    private var portNum: Int { Int(listenPortText) ?? 0 }
    private var needsDest: Bool { kind.needsDest }

    /// 当前端口冲突（同侧规则或知名端口）。空端口 → 无冲突。
    private var conflict: PortConflictChecker.Conflict? {
        guard portNum > 0 else { return nil }
        return PortConflictChecker.conflict(
            kind: kind, listenPort: portNum,
            excluding: existing?.id, against: allRules)
    }

    private var suggestedPort: Int? {
        guard conflict != nil else { return nil }
        return PortConflictChecker.suggestFreePort(after: portNum, kind: kind, against: allRules)
    }

    private var privileged: Bool {
        portNum > 0 && PortConflictChecker.isPrivileged(portNum, hasConflict: conflict != nil)
    }

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && portNum > 0
            && conflict == nil
            && (!needsDest || (!destHost.trimmingCharacters(in: .whitespaces).isEmpty
                               && (Int(destPortText) ?? 0) > 0))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            card
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(UD.border).frame(height: 1)
            ScrollView { formBody }
            Rectangle().fill(UD.border).frame(height: 1)
            footer
        }
        .frame(width: 460)
        .frame(maxHeight: 620)
        .background(RoundedRectangle(cornerRadius: 12).fill(UD.overlay))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UD.borderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 18)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(existing == nil ? "新建端口转发" : "编辑转发规则")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(UD.text)
            Text("· \(hostName)")
                .font(UD.mono(12))
                .foregroundStyle(UD.text3)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 类型 + 说明。
            FormField(label: "转发类型") {
                VStack(alignment: .leading, spacing: 8) {
                    UDSegmented(selection: $kind, options: [
                        (value: ForwardKind.local, label: "本地 -L"),
                        (value: ForwardKind.remote, label: "远程 -R"),
                        (value: ForwardKind.dynamic, label: "动态 -D")
                    ])
                    Text(kind.desc)
                        .font(.system(size: 11.5))
                        .foregroundStyle(UD.text3)
                }
            }

            FormField(label: "备注名称") {
                UDTextField(placeholder: "例如：生产数据库", text: $name)
            }

            // 监听段。
            FormSection(title: kind.srcLabel) {
                FormRow {
                    FormField(label: "地址", flex: 2) {
                        UDTextField(placeholder: kind == .remote ? "0.0.0.0" : "127.0.0.1",
                                    text: $listenHost, monospaced: true)
                    }
                    FormField(label: "端口", flex: 1) {
                        UDTextField(placeholder: "端口",
                                    text: portBinding($listenPortText),
                                    errorMessage: conflict != nil ? "" : nil,
                                    monospaced: true)
                    }
                }
                if let conflict {
                    conflictRow(conflict)
                } else if privileged {
                    privilegedRow
                }
            }

            // 目标段（dynamic 隐藏）。
            if needsDest, let dstLabel = kind.dstLabel {
                FormSection(title: dstLabel) {
                    FormRow {
                        FormField(label: "主机", flex: 2) {
                            UDTextField(placeholder: kind == .remote ? "localhost" : "10.0.0.1",
                                        text: $destHost, monospaced: true)
                        }
                        FormField(label: "端口", flex: 1) {
                            UDTextField(placeholder: "端口",
                                        text: portBinding($destPortText),
                                        monospaced: true)
                        }
                    }
                }
            }

            // autostart 行。
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("连接时自动启动")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(UD.text)
                    Text("每次连接 \(hostName) 时自动建立")
                        .font(.system(size: 11))
                        .foregroundStyle(UD.text3)
                }
                Spacer(minLength: 0)
                UDToggle($autostart)
            }

            commandPreview
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private func conflictRow(_ conflict: PortConflictChecker.Conflict) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
                .foregroundStyle(UD.danger)
            Text("端口 \(conflict.port) 已被「\(conflict.occupant)」占用")
                .font(.system(size: 11.5))
                .foregroundStyle(UD.danger)
            if let suggested = suggestedPort {
                Button { listenPortText = String(suggested) } label: {
                    Text("改用 \(suggested)")
                        .font(UD.mono(11))
                        .foregroundStyle(UD.accent)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(UD.accent.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(UD.accent.opacity(0.33), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    private var privilegedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text("端口低于 1024，绑定可能需要管理员权限")
                .font(.system(size: 11.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(UD.caution)
    }

    private var commandPreview: some View {
        HStack(spacing: 0) {
            Text("$ ").foregroundStyle(UD.text4)
            Text(previewCommand).foregroundStyle(UD.text2)
            Spacer(minLength: 0)
        }
        .font(UD.mono(11.5))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(UD.terminal))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(UD.border, lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if conflict != nil {
                Text("端口冲突，请先解决")
                    .font(.system(size: 11.5))
                    .foregroundStyle(UD.danger)
            }
            Spacer(minLength: 0)
            UDButton(title: "取消", style: .secondary, action: onCancel)
            UDButton(title: existing == nil ? "创建" : "保存", style: .primary) {
                guard valid else { return }
                onSave(makeDraft())
            }
            .disabled(!valid)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    // MARK: - 预览 / 草稿

    private var previewCommand: String {
        let listenPortStr = listenPortText.isEmpty ? "?" : listenPortText
        let listenAddr = listenHost.isEmpty ? (kind == .remote ? "0.0.0.0" : "127.0.0.1") : listenHost
        if kind == .dynamic {
            return "ssh -D \(listenAddr):\(listenPortStr) \(hostName)"
        }
        let destHostStr = destHost.isEmpty ? "?" : destHost
        let destPortStr = destPortText.isEmpty ? "?" : destPortText
        return "ssh \(kind.flag) \(listenAddr):\(listenPortStr):\(destHostStr):\(destPortStr) \(hostName)"
    }

    private func makeDraft() -> ForwardEditorDraft {
        let trimmedHost = listenHost.trimmingCharacters(in: .whitespaces)
        return ForwardEditorDraft(
            editingID: existing?.id,
            name: name.trimmingCharacters(in: .whitespaces),
            kind: kind,
            listenHost: trimmedHost.isEmpty ? (kind == .remote ? "0.0.0.0" : "127.0.0.1") : trimmedHost,
            listenPort: portNum,
            destHost: needsDest ? destHost.trimmingCharacters(in: .whitespaces) : nil,
            destPort: needsDest ? (Int(destPortText) ?? 0) : 0,
            autostart: autostart)
    }

    /// 端口框 Binding：只保留数字（仿设计稿 `replace(/\D/g, '')`）。
    private func portBinding(_ source: Binding<String>) -> Binding<String> {
        Binding(
            get: { source.wrappedValue },
            set: { source.wrappedValue = $0.filter(\.isNumber) })
    }
}
