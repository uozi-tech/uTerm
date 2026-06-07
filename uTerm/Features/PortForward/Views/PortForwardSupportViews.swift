import SwiftUI

// MARK: - 空状态（设计稿 PFEmpty）

/// 端口转发空状态：虚线框 + 文案 +「新建转发」。`filtered` 区分「该类型暂无」与
/// 「还没有任何规则」（对齐设计稿 `PFEmpty` 的两套文案）。
struct PFEmptyState: View {
    let filtered: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(filtered ? "该类型暂无转发规则" : "还没有端口转发规则")
                .font(.system(size: 13))
                .foregroundStyle(UD.text2)
            Text("把远端数据库等服务映射到本机，或开一个 SOCKS5 代理。")
                .font(.system(size: 12))
                .foregroundStyle(UD.text4)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
                .lineSpacing(2)
            UDButton(title: "新建转发", style: .primary, action: onAdd)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 48)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(UD.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}

// MARK: - 删除确认（设计稿 PFDeleteConfirm，仿 GroupDeleteConfirm 结构）

/// 删除转发规则确认浮层：380pt 卡，警示图标 + 标题（含规则名）+ 说明（含类型 flag +
/// 监听地址 mono）+ 取消 / 删除（`UDButton(.danger)`）。
struct PortForwardDeleteConfirm: View {
    let rule: ForwardingRuleSnapshot
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture(perform: onCancel)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(UD.danger.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(UD.danger.opacity(0.3), lineWidth: 1))
                        .frame(width: 36, height: 36)
                        .overlay(Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 16, weight: .medium)).foregroundStyle(UD.danger))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("删除「\(rule.name)」？")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(UD.text)
                        message
                            .font(.system(size: 12))
                            .lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack(spacing: 8) {
                    Spacer()
                    UDButton(title: "取消", style: .secondary, action: onCancel)
                    UDButton(title: "删除", style: .danger, action: onConfirm)
                }
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 12).fill(UD.overlay))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(UD.borderHi, lineWidth: 1))
            .shadow(color: .black.opacity(0.6), radius: 30, y: 18)
        }
    }

    private var message: Text {
        let lead = Text("将移除这条 \(rule.kind.label) 规则").foregroundStyle(UD.text2)
        let addr = Text(" \(rule.kind.flag) \(rule.listenHost):\(rule.listenPort)")
            .font(UD.mono(12)).foregroundStyle(UD.text3)
        let tail = Text("。").foregroundStyle(UD.text2)
        return Text("\(lead)\(addr)\(tail)")
    }
}

// MARK: - 表单原语（编辑器用，仿 GroupsManagerView 的 FormSection）

/// 表单小节：标题（caption / text3）+ 内容。对齐设计稿 `FormSection`。
struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(UD.text3)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// 表单行：横排两个 `FormField`（地址 / 端口），底部对齐，10pt 间距。
struct FormRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            content()
        }
    }
}

/// 表单字段：可选标签（11 / text3）+ 内容。`flex` 用于横排时按权重分配宽度
/// （地址 flex2 / 端口 flex1，对齐设计稿）；不传 `flex` 则占满可用宽。
struct FormField<Content: View>: View {
    let label: String?
    let flex: Int?
    @ViewBuilder let content: () -> Content

    init(label: String? = nil, flex: Int? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.flex = flex
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(UD.text3)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(flex.map { Double($0) } ?? 1)
    }
}
