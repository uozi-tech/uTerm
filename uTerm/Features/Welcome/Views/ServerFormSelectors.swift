import SwiftUI

/// 新建服务器表单里的「密钥」下拉选择器（设计稿 `new-server.jsx` 的 `KeySelector`）。
/// 从密钥库里挑一把 `SSHKey`；底部「打开密钥管理…」跳独立窗口。
struct KeySelectorView: View {
    let keys: [SSHKey]
    let selected: SSHKey?
    @Binding var open: Bool
    let onPick: (UUID) -> Void
    let onManage: () -> Void

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                if let key = selected {
                    KeyGlyph(type: key.type)
                    Text(key.name).font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                    Text(key.typeLabel).font(UD.mono(11)).foregroundStyle(UD.text3)
                    if key.hasPassphrase {
                        Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(UD.text4)
                    }
                } else {
                    Text("未选择密钥").font(.system(size: 13)).foregroundStyle(UD.text4)
                }
                Spacer(minLength: 0)
                Chevron(open: open)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(open ? UD.accent : UD.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                if keys.isEmpty {
                    Text("密钥管理器里还没有密钥")
                        .font(.system(size: 12)).foregroundStyle(UD.text4)
                        .padding(.vertical, 20).padding(.horizontal, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(keys) { key in keyRow(key) }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 240)
                }
                Rectangle().fill(UD.border).frame(height: 1)
                Button(action: onManage) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 10, weight: .medium))
                        Text("打开密钥管理…").font(.system(size: 12))
                        Spacer()
                    }
                    .foregroundStyle(UD.text2)
                    .padding(.horizontal, 10).padding(.vertical, 9)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 320)
            .background(UD.panelHi)
        }
    }

    private func keyRow(_ key: SSHKey) -> some View {
        let isSel = key.id == selected?.id
        return Button { onPick(key.id) } label: {
            HStack(spacing: 10) {
                KeyGlyph(type: key.type, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(key.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text)
                        if key.hasPassphrase {
                            Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(UD.text4)
                        }
                    }
                    Text(key.typeLabel).font(UD.mono(11)).foregroundStyle(UD.text4)
                }
                Spacer(minLength: 0)
                if isSel { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(UD.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? UD.accent.opacity(0.10) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSel ? UD.accent.opacity(0.2) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 「跳板机」下拉选择器（设计稿 `JumpHostSelector`）：只能从已有服务器里选一台。
struct JumpHostSelectorView: View {
    let hosts: [ServerProfile]
    let selected: ServerProfile?
    @Binding var open: Bool
    let onPick: (UUID) -> Void

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 10) {
                if let h = selected {
                    Circle().fill(UD.accent).frame(width: 6, height: 6)
                    Text(h.name).font(.system(size: 13, weight: .medium)).foregroundStyle(UD.text)
                    Text(endpoint(h)).font(UD.mono(11)).foregroundStyle(UD.text3).lineLimit(1).truncationMode(.middle)
                } else {
                    Text("从已有服务器选择跳板机…").font(.system(size: 13)).foregroundStyle(UD.text4)
                }
                Spacer(minLength: 0)
                Chevron(open: open)
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(UD.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(open ? UD.accent : UD.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                Text("已有服务器")
                    .font(.system(size: 10.5)).tracking(0.5).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)
                Rectangle().fill(UD.border).frame(height: 1)
                if hosts.isEmpty {
                    Text("没有可选的跳板机")
                        .font(.system(size: 12)).foregroundStyle(UD.text4)
                        .padding(.vertical, 20).padding(.horizontal, 12)
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(hosts) { h in hostRow(h) }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 240)
                }
            }
            .frame(width: 320)
            .background(UD.panelHi)
        }
    }

    private func hostRow(_ h: ServerProfile) -> some View {
        let isSel = h.id == selected?.id
        return Button { onPick(h.id) } label: {
            HStack(spacing: 10) {
                Circle().fill(UD.accent).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 1) {
                    Text(h.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(UD.text)
                    Text(endpoint(h)).font(UD.mono(11)).foregroundStyle(UD.text4).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let g = h.group, !g.isEmpty {
                    Text(g).font(.system(size: 10)).foregroundStyle(UD.text4)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(UD.border, lineWidth: 1))
                }
                if isSel { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(UD.accent) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6).fill(isSel ? UD.accent.opacity(0.10) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func endpoint(_ h: ServerProfile) -> String {
        h.port == 22 ? "\(h.username)@\(h.host)" : "\(h.username)@\(h.host):\(h.port)"
    }
}

// MARK: - 共用小件

private struct Chevron: View {
    let open: Bool
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(UD.text3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .animation(.easeOut(duration: 0.15), value: open)
    }
}

private struct KeyGlyph: View {
    let type: SSHKeyKind
    var size: CGFloat = 20
    var body: some View {
        let tint: Color = switch type {
        case .ed25519: UD.accent
        case .rsa: Color(hex: 0xFBBF24)
        case .ecdsaP256, .ecdsaP384, .ecdsaP521: Color(hex: 0x34D399)
        }
        RoundedRectangle(cornerRadius: size * 0.25)
            .fill(tint.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: size * 0.25).strokeBorder(tint.opacity(0.3), lineWidth: 1))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "key.fill").font(.system(size: size * 0.5)).foregroundStyle(tint))
    }
}
