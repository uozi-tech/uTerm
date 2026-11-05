import Foundation
import Markdown
import Observation

/// 流式 Markdown 的重解析节流器，macOS（`StreamingMarkdownView`）与 iOS（`MStreamingMarkdown`）
/// 共用（这个文件两个 target 都编）。
///
/// 节流窗口里保存最新的 source，而不是让定时任务捕获安排时的旧 View 值：定时器触发时总是解析
/// `latestSource`；流落定时立即冲掉最终文本。
///
/// 两个可选项只有 iOS 打开，macOS 用默认值（固定 100ms、不缓存），探针读数不受影响：
/// - `scalesDelayWithLength`：节流间隔随文本长度放大。每次重解析都是整段全文，几十 KB 的长回复
///   按固定 100ms 解析会占掉主线程的一大块；长度翻几倍、间隔跟着翻，单位时间里的解析量大致恒定。
/// - `settledCache`：落定消息的解析结果按全文缓存。外层懒栈回收后再出现会重新 `onAppear`，
///   往上翻长历史时每条都要在主线程重解析一遍；命中缓存就不用。
@MainActor
@Observable
final class StreamingMarkdownRenderer {
    static let reparseDelay: Duration = .milliseconds(100)

    private(set) var document: Markdown.Document
    private(set) var renderedSource: String

    @ObservationIgnored private let reparseDelay: Duration
    @ObservationIgnored private let scalesDelayWithLength: Bool
    @ObservationIgnored private let settledCache: MarkdownDocumentCache?
    @ObservationIgnored private var latestSource: String
    @ObservationIgnored private var pendingReparse: Task<Void, Never>?

    init(reparseDelay: Duration = StreamingMarkdownRenderer.reparseDelay,
         scalesDelayWithLength: Bool = false,
         settledCache: MarkdownDocumentCache? = nil) {
        self.reparseDelay = reparseDelay
        self.scalesDelayWithLength = scalesDelayWithLength
        self.settledCache = settledCache
        self.latestSource = ""
        self.renderedSource = ""
        self.document = Markdown.Document(parsing: "")
    }

    /// 立即解析（首次出现 / 流落定）。`isStreaming` 为真时不进缓存——流式中的中间态每一版只用一次。
    func renderImmediately(_ source: String, isStreaming: Bool = false) {
        latestSource = source
        pendingReparse?.cancel()
        pendingReparse = nil
        renderLatest(cacheable: !isStreaming)
    }

    func update(_ source: String, isStreaming: Bool) {
        latestSource = source
        guard isStreaming else {
            renderImmediately(source)
            return
        }
        guard latestSource != renderedSource, pendingReparse == nil else { return }
        let delay = scalesDelayWithLength
            ? Self.scaledDelay(base: reparseDelay, bytes: source.utf8.count)
            : reparseDelay
        pendingReparse = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingReparse = nil
            self.renderLatest(cacheable: false)
        }
    }

    func cancel() {
        pendingReparse?.cancel()
        pendingReparse = nil
    }

    /// 按长度放大的节流间隔：8KB 以内一个 `base`；之后每多 8KB 加一个 `base`，最多 5 个。
    nonisolated static func scaledDelay(base: Duration, bytes: Int) -> Duration {
        base * min(5, 1 + bytes / 8192)
    }

    private func renderLatest(cacheable: Bool) {
        guard latestSource != renderedSource else { return }
        renderedSource = latestSource
        if cacheable, let settledCache {
            document = settledCache.document(for: latestSource)
        } else {
            document = Markdown.Document(parsing: latestSource)
        }
    }
}

/// 落定消息的解析结果缓存（只在主线程用），按全文为键、先进先出淘汰。
@MainActor
final class MarkdownDocumentCache {
    /// 聊天里所有落定消息共用的一份。
    static let shared = MarkdownDocumentCache(capacity: 64)

    private let capacity: Int
    private var documents: [String: Markdown.Document] = [:]
    private var order: [String] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    func document(for text: String) -> Markdown.Document {
        if let hit = documents[text] { return hit }
        let parsed = Markdown.Document(parsing: text)
        documents[text] = parsed
        order.append(text)
        if order.count > capacity { documents.removeValue(forKey: order.removeFirst()) }
        return parsed
    }
}
