import Foundation
@testable import uTerm

/// 可控的 LLMClient 测试替身。
///
/// 三种构造：
/// - `init(deltas:)`：文本增量（向后兼容旧测试）。
/// - `init(events:)`：单次 stream 产出的 `LLMEvent` 列表。
/// - `init(scripts:)`：多轮脚本——每次 `stream(...)` 调用依次出列下一段事件数组，
///   用于工具调用「续轮」的多次流式测试。
struct MockLLMClient: LLMClient {
    let scripts: [[LLMEvent]]
    let failWith: Error?

    final class Captured: @unchecked Sendable {
        var messages: [ChatMessage] = []
        var system: String = ""
        var config: LLMRequestConfig?
        /// 已发生的 stream 调用次数（用于 scripts 出列）。
        var callCount = 0
    }
    let captured = Captured()

    /// 以文本增量构造（向后兼容旧测试）。
    init(deltas: [String] = [], failWith: Error? = nil) {
        self.scripts = [deltas.map { .text($0) }]
        self.failWith = failWith
    }

    /// 以 LLMEvent 列表构造（单轮）。
    init(events: [LLMEvent] = [], failWith: Error? = nil) {
        self.scripts = [events]
        self.failWith = failWith
    }

    /// 以多轮脚本构造：每段对应一次 stream 调用，按顺序出列。
    init(scripts: [[LLMEvent]], failWith: Error? = nil) {
        self.scripts = scripts
        self.failWith = failWith
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        captured.messages = messages
        captured.system = system
        captured.config = config
        let call = captured.callCount
        captured.callCount += 1
        let events = call < scripts.count ? scripts[call] : []
        let failWith = failWith
        return AsyncThrowingStream { continuation in
            for e in events { continuation.yield(e) }
            if let failWith {
                continuation.finish(throwing: failWith)
            } else {
                continuation.finish()
            }
        }
    }
}

/// 永不主动结束：把 AssistantModel 钉在 .streaming，直到流被取消。
struct BlockingLLMClient: LLMClient {
    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 先发送一批事件，随后保持连接静默，复现 provider 已有输出但 SSE 不结束的现场。
struct HangingAfterEventsLLMClient: LLMClient {
    let events: [LLMEvent]

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            let task = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
