import SwiftUI

/// 居中模态 / 确认对话框等覆盖层原语（设计稿 `m-kit` 的 `CenterModal` + `m-shell` 的 `ConfirmDialog`）。
///
/// 底部抽屉直接用 SwiftUI 原生 `.sheet` + `.presentationDetents` / `.presentationDragIndicator`，
/// 全屏覆盖用 `.fullScreenCover`；此处只补原生没有的「居中卡片弹层」。

// MARK: - 居中模态卡片外壳

struct MCenterModalContainer<Content: View>: View {
    var width: CGFloat = 360
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: width)
            .background(M.overlayHi)
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(M.borderHi, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .mCardShadow()
            .padding(22)
    }
}

extension View {
    /// 在当前视图之上叠加一个可点击背板 + 居中弹出的卡片（pop 动画）。
    func mCenterModal<C: View>(isPresented: Binding<Bool>,
                              dismissable: Bool = true,
                              width: CGFloat = 360,
                              @ViewBuilder content: @escaping () -> C) -> some View {
        ZStack {
            self
            if isPresented.wrappedValue {
                M.backdrop.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if dismissable { isPresented.wrappedValue = false } }
                    .transition(.opacity)
                MCenterModalContainer(width: width, content: content)
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isPresented.wrappedValue)
    }

    /// 基于可选 item 的居中弹层（用于主机密钥挑战等）。
    func mCenterModal<Item: Identifiable, C: View>(item: Binding<Item?>,
                                                  dismissable: Bool = true,
                                                  width: CGFloat = 400,
                                                  @ViewBuilder content: @escaping (Item) -> C) -> some View {
        ZStack {
            self
            if let value = item.wrappedValue {
                M.backdrop.ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { if dismissable { item.wrappedValue = nil } }
                    .transition(.opacity)
                MCenterModalContainer(width: width) { content(value) }
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: item.wrappedValue == nil)
    }
}

// MARK: - 删除确认对话框（设计稿 `ConfirmDialog`）

struct MConfirmDialog: View {
    var title: String
    var message: String
    var danger: Bool = false
    var confirmLabel: String = "确认"
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @Environment(\.mAccent) private var accent

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                MIcon(name: "warn", size: 19, color: M.danger)
                    .frame(width: 38, height: 38)
                    .background(M.danger.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(M.danger.opacity(0.3), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                    Text(message).font(M.sans(13)).foregroundStyle(M.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                MBtn(title: "取消", kind: .secondary, full: true, height: 46, action: onCancel)
                MBtn(title: confirmLabel, kind: danger ? .danger : .primary, full: true, height: 46, action: onConfirm)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
    }
}
