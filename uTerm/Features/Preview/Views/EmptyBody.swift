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
        // minHeight: 0 —— 只给 maxHeight 的 frame 在提议高度小于内容时会**按内容高度**
        // 定尺寸。组外壳（`UPaneGroupArea` 的定高 frame）装不下就整体居中溢出，把
        // 组的标签条顶出预览区上沿。给了下限才肯被压扁，溢出部分顶端对齐后裁掉。
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// 空间不够时逐级退化：图标 + 文案 → 只剩文案 → 什么都不画。
    private var emptyHint: some View {
        ViewThatFits(in: .vertical) {
            hintStack(showsIcon: true)
            hintStack(showsIcon: false)
            Color.clear.frame(height: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func hintStack(showsIcon: Bool) -> some View {
        VStack(spacing: 8) {
            if showsIcon {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(UD.text3)
            }
            Text("从左侧选择文件预览")
                .font(.callout)
                .foregroundStyle(UD.text2)
        }
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
            Text(UFormat.relative(entry.lastOpenedAt))
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
}
