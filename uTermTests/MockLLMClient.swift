import Foundation
@testable import uTerm

/// 可控的 LLMClient 测试替身。
struct MockLLMClient: LLMClient {
    let deltas: [String]
    let failWith: Error?

    final class Captured: @unchecked Sendable {
        var messages: [ChatMessage] = []
        var system: String = ""
        var config: LLMRequestConfig?
    }
    let captured = Captured()

    init(deltas: [String] = [], failWith: Error? = nil) {
        self.deltas = deltas
        self.failWith = failWith
    }

    func stream(messages: [ChatMessage], system: String,
                config: LLMRequestConfig) -> AsyncThrowingStream<String, Error> {
        captured.messages = messages
        captured.system = system
        captured.config = config
        let deltas = deltas
        let failWith = failWith
        return AsyncThrowingStream { continuation in
            for d in deltas { continuation.yield(d) }
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
                config: LLMRequestConfig) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
