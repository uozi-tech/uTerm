import Foundation
@testable import uTerm

/// 可控的 `AssistantBackend` 测试替身。
struct MockAssistantBackend: AssistantBackend {
    let deltas: [String]
    let failWith: Error?
    /// 记录最近一次收到的 messages / system。
    final class Captured: @unchecked Sendable {
        var messages: [ChatMessage] = []
        var system: String = ""
    }
    let captured = Captured()

    init(deltas: [String] = [], failWith: Error? = nil) {
        self.deltas = deltas
        self.failWith = failWith
    }

    func stream(messages: [ChatMessage], system: String, apiKey: String)
        -> AsyncThrowingStream<String, Error> {
        captured.messages = messages
        captured.system = system
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

/// 永不主动结束的 `AssistantBackend` 测试替身：用于把 `AssistantModel`
/// 钉在 `.streaming` 状态，直到流被终止（取消）。
struct BlockingAssistantBackend: AssistantBackend {
    func stream(messages: [ChatMessage], system: String, apiKey: String)
        -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .seconds(60))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
