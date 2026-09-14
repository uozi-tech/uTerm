import AgentKit
import Foundation

/// A separate, tool-free review turn with both a hard deadline and an output cap.
nonisolated func reviewToolApproval(client: LLMClient, config: LLMRequestConfig,
                                    system: String, prompt: String,
                                    timeout: Duration = .seconds(20)) async throws -> String {
    var reviewConfig = config
    reviewConfig.tools = []
    let boundedConfig = reviewConfig
    return try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            var result = ""
            for try await event in client.stream(
                messages: [ChatMessage(role: .user, text: prompt)], system: system, config: boundedConfig) {
                try Task.checkCancellation()
                guard case .text(let text) = event else { throw LLMClientError.invalidResponse }
                result += text
                guard result.utf8.count <= 8192 else { throw LLMClientError.invalidResponse }
            }
            return result
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw LLMClientError.streamIdleTimeout
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw LLMClientError.invalidResponse }
        return result
    }
}
