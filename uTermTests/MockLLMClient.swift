import Foundation
@testable import uTerm

/// 可控的 LLMClient 测试替身。
struct MockLLMClient: LLMClient {
    let events: [LLMEvent]
    let failWith: Error?

    final class Captured: @unchecked Sendable {
        var messages: [ChatMessage] = []
        var system: String = ""
        var config: LLMRequestConfig?
    }
    let captured = Captured()

    /// 以文本增量构造（向后兼容旧测试）。
    init(deltas: [String] = [], failWith: Error? = nil) {
        self.events = deltas.map { .text($0) }
        self.failWith = failWith
    }

    /// 以 LLMEvent 列表构造。
    init(events: [LLMEvent] = [], failWith: Error? = nil) {
        self.events = events
        self.failWith = failWith
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        captured.messages = messages
        captured.system = system
        captured.config = config
        let events = events
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
