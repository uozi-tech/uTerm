import SwiftUI

/// 远程桌面里选「只看哪一个窗口」。打开时向 Mac 要一次窗口列表，下拉再要一次。
///
/// 选中后会话按那个窗口重开流（`RemoteDesktopSession.switchWindow`）：画面只有这一个窗口，Mac 会先把它提到最前。
struct RemoteDesktopWindowPicker: View {
    let session: RemoteDesktopSession
    /// 画布此刻的点尺寸：开着「调成这里的大小」时请 Mac 把窗口调成这么大。
    let canvasSize: CGSize
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DefaultsKey.remoteDesktopFitWindow) private var fitsWindow = true
    @AppStorage(DefaultsKey.remoteDesktopWindowTextScale) private var textScale = 1.0
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
                Section {
                    Toggle("把窗口调成这里的大小", isOn: $fitsWindow)
                    if fitsWindow {
                        // 字越大，窗口调得越小（排得下的内容越少），整个画面放大铺满这里。
                        Picker("文字大小", selection: $textScale) {
                            Text("小").tag(0.8)
                            Text("标准").tag(1.0)
                            Text("大").tag(1.25)
                            Text("特大").tag(1.5)
                        }
                        .pickerStyle(.segmented)
                    }
                } footer: {
                    Text("Mac 上的窗口会改成适合这里的大小，里面的内容重新排版。「标准」时字和在 Mac 上一样大；字越大，窗口里排得下的内容越少。看完后窗口恢复原来的大小。")
                }
                // 正看着一个窗口时改这两项：马上按新的重调。
                .onChange(of: fitsWindow) { _, _ in refit() }
                .onChange(of: textScale) { _, _ in refit() }
                Section {
                    if loading, windows.isEmpty {
                        HStack {
                            ProgressView()
                            Text("正在读取窗口…").foregroundStyle(.secondary)
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
            }
            .navigationTitle("只看一个窗口")
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
    }

    private func choice(title: Text, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    title.foregroundStyle(.primary).lineLimit(1)
                    if let detail {
                        Text(verbatim: detail).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if selected {
                    Image(systemName: "checkmark").fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var fit: CGSize? {
        fitsWindow ? RemoteDesktopWindowFit.size(canvas: canvasSize, textScale: textScale) : nil
    }

    private func choose(_ id: UInt32?) {
        dismiss()
        let fit = fit
        Task { await session.switchWindow(to: id, fit: fit) }
    }

    private func refit() {
        guard let id = session.windowID else { return }
        let fit = fit
        Task { await session.switchWindow(to: id, fit: fit) }
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
