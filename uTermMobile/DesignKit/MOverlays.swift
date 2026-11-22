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
            .overlay(RoundedRectangle(cornerRadius: MRadius.dialog).stroke(M.borderHi, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: MRadius.dialog))
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
    var confirmLabel: String = String(localized: "确认")
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @Environment(\.mAccent) private var accent

    /// 左上角图标块与弹窗外框同心（距边 20pt）；底部按钮距底边 16pt，恰好与 `MRadius.dialog` 同心。
    private let iconRadius = MRadius.inner(of: MRadius.dialog, inset: 20)

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                MIcon(name: "warn", size: 19, color: M.danger)
                    .frame(width: 38, height: 38)
                    .background(M.danger.opacity(0.14))
                    .overlay(RoundedRectangle(cornerRadius: iconRadius).stroke(M.danger.opacity(0.3), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: iconRadius))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(M.sans(15.5, weight: .semibold)).foregroundStyle(M.text)
                    Text(message).font(M.sans(13)).foregroundStyle(M.text2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                MBtn(title: String(localized: "取消"), kind: .secondary, full: true, height: 46, action: onCancel)
                MBtn(title: confirmLabel, kind: danger ? .danger : .primary, full: true, height: 46, action: onConfirm)
            }
            .padding(.top, 18)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
    }
}

// MARK: - 弹窗内容安全边距

/// `.sheet` 弹窗里内容与弹窗边的距离。弹窗四角是大圆角（iOS 26 与屏幕圆角同心），屏内那套
/// 16pt 边距搬进弹窗，卡片、行和按钮就顶进圆角的弧里，看着贴边。
nonisolated enum MSheetMetrics {
    /// 内容离弹窗左右边的距离，与 `MBottomPanelMetrics.contentInset` 同值。
    static let contentInset: CGFloat = 24
    /// 屏内内容自带的左右边距（`MInsetGroup` / 表单字段的 16pt）。弹窗只补两者的差额，
    /// 内容内部的对齐关系（区段标题比卡片多缩 4pt 之类）原样保留。
    static let screenInset: CGFloat = 16
    /// 滚到底时最后一块内容与弹窗下圆角之间多留的距离。
    static let bottomInset: CGFloat = 12
}

/// 弹窗根视图的滚动容器类型：两者吃 `contentMargins` 的方式不同。
enum MSheetContent {
    /// `ScrollView` + 自带 16pt 边距的卡片：边距**叠加**在内容的 padding 外，只补差额。
    case scroll
    /// 系统 `List` / `Form`：边距**取代**系统默认的分组缩进，直接给到 `contentInset`。
    case form
}

extension View {
    /// 挂在弹窗根上（`.sheet { … }` 闭包里那一层）：给弹窗内所有滚动内容补左右与底部边距，
    /// 下钻进 `NavigationStack` 的子页同样生效。别在每个弹窗里各改各的 padding。
    func mSheetContentMargins(_ content: MSheetContent = .scroll) -> some View {
        let horizontal = switch content {
        case .scroll: MSheetMetrics.contentInset - MSheetMetrics.screenInset
        case .form: MSheetMetrics.contentInset
        }
        return contentMargins(.horizontal, horizontal, for: .scrollContent)
            .contentMargins(.bottom, MSheetMetrics.bottomInset, for: .scrollContent)
    }
}
