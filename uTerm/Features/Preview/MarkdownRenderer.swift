// uTerm/Preview/MarkdownRenderer.swift
import SwiftUI
import UDesignKit

typealias MarkdownImageLoader = @MainActor (String) async throws -> Data
typealias MarkdownBufferImageLoader = @MainActor (String, FileBuffer) async throws -> Data

/// 把 Markdown 源码渲染为 SwiftUI 视图（文件预览侧；跟随系统外观）。
/// 渲染逻辑在 `MarkdownBlocks`，此处仅包 ScrollView + .preview 皮肤 + 分段。
///
/// 分段（`MarkdownBlockWindow`）：`MarkdownBlocks` 刻意是非 lazy 的
/// （`1a0bd63d` 修的窗口缩放布局卡死），一份 5 万块的文档一次全建出来会把
/// 主线程按在地上。所以先挂一段，剩下的由底部「继续渲染」按需放开。
/// 常规文件（几百块）一次就挂完，行为与改前完全一致。
struct MarkdownRenderer: View {
    let source: String
    var imageLoader: MarkdownImageLoader?
    /// 首屏挂多少块。探针把它调成 `Int.max` 就是改前的「一次全挂」臂。
    var initialBlockLimit: Int = MarkdownBlockWindow.defaultLimit

    @State private var blockLimit: Int?

    private var effectiveLimit: Int { blockLimit ?? initialBlockLimit }

    var body: some View {
        ScrollView {
            StreamingMarkdownView(
                text: source,
                isStreaming: true,
                style: .preview,
                imageLoader: imageLoader,
                maxBlocks: effectiveLimit,
                moreBlocks: { remaining in AnyView(moreButton(remaining: remaining)) })
                .padding(.vertical, 4)
        }
        // 换文件就把分段收回第一段，否则上一份文档点开的进度会带进下一份。
        .onChange(of: source) { _, _ in blockLimit = nil }
    }

    private func moreButton(remaining: Int) -> some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                blockLimit = MarkdownBlockWindow.expanded(
                    effectiveLimit, total: effectiveLimit + remaining)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                    Text("继续渲染（还有 \(remaining) 块）")
                        .font(.system(size: 11))
                }
                .foregroundStyle(UD.text3)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(UD.fillSoft))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("继续渲染，还有 \(remaining) 块未渲染")
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
    }
}
