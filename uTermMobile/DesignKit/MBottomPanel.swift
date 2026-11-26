import SwiftUI

/// 自绘的底部面板：悬浮在屏幕底部的一张卡片，高度完全由内容决定。
///
/// 为什么不用原生 `.sheet` + `.height` detent：detent 要靠内容测量，测量时机与系统对 detent 的处理
/// 在不同尺寸类下都不可控——iPhone Duo 展开（常规宽度）时系统按表单弹窗显示、不认 detent；首轮布局
/// 宽度未定时量得过高、之后系统又不一定收回。主机详情抽屉为此反复出现「有时候很高」（真机反馈，
/// 两次按测量修都没稳住）。这里不用 detent：卡片就是内容本身的高度。
///
/// 外观照 iOS 26 的悬浮抽屉：离屏幕左右与底边各 8pt，圆角与屏幕圆角同心（`ConcentricRectangle`），
/// 内容左右 24pt、底部再让出 Home 条，不贴着大圆角；宽屏（Duo 展开 / iPad）最宽 560pt 居中。
/// 点背板或向下拖动关闭。承载用透明的 `fullScreenCover`，因而盖得住标签栏与 Duo 侧列。
extension View {
    func mBottomPanel<Item: Identifiable, Panel: View>(
        item: Binding<Item?>, @ViewBuilder panel: @escaping (Item) -> Panel
    ) -> some View {
        modifier(MBottomPanelPresenter(item: item, panel: panel))
    }
}

nonisolated enum MBottomPanelMetrics {
    /// 卡片离屏幕边的距离。
    static let screenInset: CGFloat = 8
    /// 内容离卡片左右边的距离（卡片圆角大，别让文字和按钮贴着圆角）。
    static let contentInset: CGFloat = 24
    static let maxWidth: CGFloat = 560
    static let fallbackRadius: CGFloat = 28
    /// 背板遮罩的不透明度。
    static let scrimOpacity: Double = 0.28
}

private struct MBottomPanelPresenter<Item: Identifiable, Panel: View>: ViewModifier {
    @Binding var item: Item?
    var panel: (Item) -> Panel
    /// 驱动 fullScreenCover 的那份（呈现 / 撤下都不带系统动画，进出动画由卡片自己做）。
    @State private var presented: Item?
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, _ in
                if let item { present(item) } else { close() }
            }
            .fullScreenCover(item: $presented) { value in
                MBottomPanelChrome(shown: $shown, onDismiss: { item = nil }) { panel(value) }
                    .presentationBackground(.clear)
            }
    }

    private func present(_ value: Item) {
        // 底下的视图（终端等）若开着键盘，先收起：透明的 fullScreenCover 不换第一响应者，键盘会留着挡住面板。
        // 这里是全局收起，不记成用户点了「收起键盘」，之后切回终端照常弹回。
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { presented = value }
    }

    private func close() {
        guard presented != nil else { return }
        shown = false
        // 等卡片滑出再撤下承载层。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            guard item == nil else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { presented = nil }
        }
    }
}

private struct MBottomPanelChrome<Panel: View>: View {
    @Binding var shown: Bool
    var onDismiss: () -> Void
    @ViewBuilder var panel: Panel
    @State private var drag: CGFloat = 0
    /// 系统键盘（或外接键盘的快捷栏）露着。SwiftUI 的安全区分不出底部那一截是 Home 条还是键盘
    ///（忽略键盘区域的视图读到的底部安全区照样含键盘），只能听键盘的通知。
    @State private var keyboardShown = false

    var body: some View {
        GeometryReader { proxy in
            // 键盘弹出时 `proxy` 的底部安全区就是键盘的高度。卡片已经停在键盘上沿（外层只让出了容器的底边、没让键盘），
            // 内容底下再按它留白就等于被键盘的高度抬了两次：按钮离键盘空出一大截。这时只留固定的 24pt。
            ZStack(alignment: .bottom) {
                // 不用 M.backdrop：它在日间是透明的（设计语言 v2），面板会和底下的页面混在一起。
                Color.black.opacity(MBottomPanelMetrics.scrimOpacity)
                    .opacity(shown ? 1 : 0)
                    // 遮罩铺满四边（状态栏、Home 条、Duo 侧列）；外层 ZStack 只让出了底边，
                    // 遮罩跟着它走的话顶部状态栏那一条还是亮的（真机反馈）。
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onDismiss)
                    .accessibilityLabel(Text("关闭"))
                    .accessibilityAddTraits(.isButton)
                if shown {
                    card(bottomSafeArea: keyboardShown ? 0 : proxy.safeAreaInsets.bottom)
                        .transition(.move(edge: .bottom))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardShown = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardShown = false
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: shown)
        .onAppear { shown = true }
        .accessibilityAction(.escape, onDismiss)
    }

    private func card(bottomSafeArea: CGFloat) -> some View {
        VStack(spacing: 0) {
            Capsule().fill(M.text4.opacity(0.6))
                .frame(width: 36, height: 5)
                .padding(.top, 8).padding(.bottom, 14)
                .accessibilityHidden(true)
            panel
                .padding(.horizontal, MBottomPanelMetrics.contentInset)
                // 卡片伸到 Home 条底下：内容让出 Home 条，再留 24pt 离开底部大圆角。键盘弹出时卡片停在键盘上沿，只留 24pt。
                .padding(.bottom, 24 + max(0, bottomSafeArea - MBottomPanelMetrics.screenInset))
        }
        .frame(maxWidth: MBottomPanelMetrics.maxWidth)
        .background {
            MPanelShape().fill(M.card)
                .shadow(color: .black.opacity(0.12), radius: 24, y: 6)
        }
        .padding(.horizontal, MBottomPanelMetrics.screenInset)
        .padding(.bottom, MBottomPanelMetrics.screenInset)
        .offset(y: max(0, drag))
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                        onDismiss()
                    }
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) { drag = 0 }
                })
    }
}

/// 与屏幕圆角同心的卡片形状（iOS 26 `ConcentricRectangle`），更早的系统退回固定圆角。
private nonisolated struct MPanelShape: Shape {
    func path(in rect: CGRect) -> Path {
        if #available(iOS 26.0, *) {
            return ConcentricRectangle(corners: .concentric(minimum: .fixed(MBottomPanelMetrics.fallbackRadius)),
                                       isUniform: true).path(in: rect)
        }
        return RoundedRectangle(cornerRadius: MBottomPanelMetrics.fallbackRadius, style: .continuous).path(in: rect)
    }
}
