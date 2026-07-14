import UDesignKit
import SwiftUI

/// PreviewArea 没有 active buffer 时的空态：展示最近打开。
struct EmptyBody: View {
    let model: FilePreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("最近打开")
                    .font(.headline)
                    .foregroundStyle(UD.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                if !model.recents.isEmpty {
                    UDButton(title: "清空", style: .ghost) { model.clearRecents() }
                }
            }
            if model.recents.isEmpty {
                emptyHint
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.recents) { entry in
                            recentRow(entry)
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(UD.text3)
            Text("从左侧选择文件预览")
                .font(.callout)
                .foregroundStyle(UD.text2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func recentRow(_ entry: RecentFileEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: entry.kindTag))
                .frame(width: 16)
                .foregroundStyle(UD.text3)
            VStack(alignment: .leading, spacing: 1) {
                Text((entry.remotePath as NSString).lastPathComponent)
                    .foregroundStyle(UD.text)
                    .lineLimit(1).truncationMode(.tail)
                Text(entry.remotePath)
                    .font(.caption)
                    .foregroundStyle(UD.text3)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer()
            Text(relative(entry.lastOpenedAt))
                .font(.caption)
                .foregroundStyle(UD.text3)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4).fill(Color.clear)
        )
        .onTapGesture {
            Task { await model.reopen(entry) }
        }
        .onHover { _ in
            // SwiftUI 无 hover 持久背景；如果想要 hover 高亮，包成 stateful 子 view
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func icon(for kindTag: String) -> String {
        if kindTag.hasPrefix("code:") { return "doc.text" }
        if kindTag == "markdown" { return "doc.richtext" }
        if kindTag == "image" { return "photo" }
        return "doc"
    }

    // 提到 static let：之前每次 row 渲染都分配新 formatter（list 里 N 次
    // 分配 = N 次 locale 查询）。NSFormatter 子类在主线程使用线程安全。
    // 不再写死 zh_CN —— 跟随 Locale.current（用户系统语言）。
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt
    }()

    private func relative(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
