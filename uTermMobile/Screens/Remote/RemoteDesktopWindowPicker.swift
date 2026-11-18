import SwiftUI

/// 远程桌面里的「窗口模式」：选只看哪一个窗口。打开时向 Mac 要一次窗口列表，下拉再要一次。
///
/// 选中后会话按那个窗口重开流（`RemoteDesktopSession.switchWindow`）：画面只有这一个窗口，Mac 会先把它提到最前。
struct RemoteDesktopWindowPicker: View {
    let session: RemoteDesktopSession
    /// 画布此刻的点尺寸：开着「调成这里的大小」时请 Mac 把窗口调成这么大。
    let canvasSize: CGSize
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mAccent) private var accent
    @AppStorage(DefaultsKey.remoteDesktopFitWindow) private var fitsWindow = true
    @AppStorage(DefaultsKey.remoteDesktopWindowTextScale) private var textScale = RemoteDesktopWindowFit.defaultTextScale
    @Environment(\.displayScale) private var displayScale
    @AppStorage(DefaultsKey.remoteDesktopWindowTouchMode) private var touchMode = false
    @AppStorage(DefaultsKey.remoteDesktopWindowKeepFront) private var keepsFront = false
    @AppStorage(DefaultsKey.remoteDesktopWindowIndependentInput) private var independentInput = true
    @State private var windows: [RemoteDesktopWindowSummary] = []
    /// Mac 列不出来时给的原因，或请求本身失败的原因。
    @State private var note: String?
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    choice(title: Text("整个屏幕"), detail: nil, selected: session.windowID == nil) { choose(nil) }
                }
                .listRowBackground(M.card)
                Section {
                    Toggle("把窗口调成这里的大小", isOn: $fitsWindow)
                    if fitsWindow {
                        // 字越大，窗口调得越小（排得下的内容越少），整个画面放大铺满这里。
                        RemoteWindowTextScalePicker(selection: $textScale)
                    }
                } footer: {
                    Text("Mac 上的窗口会改成适合这里的大小，里面的内容重新排版。「最清晰」时 Mac 的像素和这里的像素一一对应，画面最利、字最小；「标准」时字和在 Mac 上一样大；字越大，窗口里排得下的内容越少。看完后窗口恢复原来的大小。")
                }
                .listRowBackground(M.card)
                // 正看着一个窗口时改这两项：马上按新的重调。
                .onChange(of: fitsWindow) { _, _ in refit() }
                .onChange(of: textScale) { _, _ in refit() }
                if session.supportsWindowFront {
                    Section {
                        Toggle("看着时保持在最前", isOn: $keepsFront)
                    } footer: {
                        Text("被别的窗口盖住、或者它的 App 退到后面时，Mac 不再让这个窗口重绘，动画会停在最后一帧。打开后，看着的这段时间 Mac 会一直把它提到最前；坐在 Mac 前用别的 App 的人会被打断。")
                    }
                    .listRowBackground(M.card)
                    .onChange(of: keepsFront) { _, _ in refit() }
                }
                if session.supportsWindowInput {
                    Section {
                        Toggle("独立键鼠", isOn: $independentInput)
                    } footer: {
                        Text("鼠标和键盘直接发给这个窗口：Mac 上的指针不动，窗口被别的窗口盖住也能操作，坐在 Mac 前的人可以同时用自己的键鼠。个别 App 不响应这样发来的操作，遇到时关掉。")
                    }
                    .listRowBackground(M.card)
                    .onChange(of: independentInput) { _, _ in refit() }
                }
                Section {
                    Toggle("触摸屏模式", isOn: $touchMode)
                } footer: {
                    Text("点哪里就是哪里，不显示鼠标指针：单指拖动滚动内容，按住再拖是拖拽，双指轻点是右键。关着时像触控板一样移动指针。")
                }
                .listRowBackground(M.card)
                Section {
                    if loading, windows.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在读取窗口…").foregroundStyle(M.text3)
                        }
                    }
                    ForEach(windows, id: \.id) { window in
                        choice(title: Text(verbatim: window.menuTitle), detail: window.menuDetail,
                               selected: session.windowID == window.id) { choose(window.id) }
                    }
                } header: {
                    Text("窗口")
                } footer: {
                    if let note {
                        Text(verbatim: note)
                    } else if !loading, windows.isEmpty {
                        Text("那台 Mac 上此刻没有可以单独看的窗口。")
                    }
                }
                .listRowBackground(M.card)
            }
            // 底色和卡片用 App 自己的颜色，不用系统默认的半透明材质：这个弹层盖在 Mac 的画面上，
            // 半透明时下面亮的画面透上来，深色模式下整块发灰、字看不清。
            .scrollContentBackground(.hidden)
            .background(M.canvas)
            .navigationTitle("窗口模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .refreshable { await load() }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(M.canvas)
    }

    private func choice(title: Text, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    // 颜色写明：按钮里的 `.primary` / `.secondary` 取的是强调色的两档，整列都成了蓝字。
                    title.foregroundStyle(M.text).lineLimit(1)
                    if let detail {
                        Text(verbatim: detail).font(.footnote).foregroundStyle(M.text3).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fit: CGSize? {
        fitsWindow ? RemoteDesktopWindowFit.size(canvas: canvasSize, textScale: textScale, displayScale: displayScale) : nil
    }

    private func choose(_ id: UInt32?) {
        dismiss()
        let fit = fit, front = keepsFront, independent = independentInput
        Task { await session.switchWindow(to: id, fit: fit, keepFront: front, independentInput: independent) }
    }

    private func refit() {
        guard let id = session.windowID else { return }
        let fit = fit, front = keepsFront, independent = independentInput
        Task { await session.switchWindow(to: id, fit: fit, keepFront: front, independentInput: independent) }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let list = try await session.client.desktopWindows()
            windows = list.windows
            note = list.message
        } catch {
            note = error.localizedDescription
        }
    }
}

/// 「文字大小」那一行，两处窗口模式的选项页共用。「最清晰」见 `RemoteDesktopWindowFit.sharpest`。
struct RemoteWindowTextScalePicker: View {
    @Binding var selection: Double

    var body: some View {
        Picker("文字大小", selection: $selection) {
            Text("最清晰").tag(RemoteDesktopWindowFit.sharpest)
            Text("小").tag(0.8)
            Text("标准").tag(1.0)
            Text("大").tag(1.25)
            Text("特大").tag(1.5)
        }
        .pickerStyle(.segmented)
    }
}
