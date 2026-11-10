import AgentKit
import Foundation

/// A separate, tool-free review turn with both a hard deadline and an output cap.
///
/// 审查请求不带思考参数，也不把 thinking 块当成坏响应：
/// - 对话那边选了思考深度时，带着它来审查，模型对稍复杂一点的命令就会先吐 thinking 块；
///   原先这里遇到任何非文字事件都抛错，结果是「命令一长就审批未完成」，简单命令反而能过。
/// - 审查只要一段很短的 JSON，还有硬期限；思考只会把它拖过期限。
/// - 有的型号不带参数也会思考，所以 thinking 事件照样可能来 —— 它不是答案的一部分，跳过。
///
/// 失败原因记日志（category `agent`）：界面上只有一句「AI 审批未完成」，分不出是超时、
/// 端点报错还是响应形状不对。
nonisolated func reviewToolApproval(client: LLMClient, config: LLMRequestConfig,
                                    system: String, prompt: String,
                                    timeout: Duration = .seconds(20)) async throws -> String {
    var reviewConfig = config
    reviewConfig.tools = []
    reviewConfig.reasoning = nil
    let boundedConfig = reviewConfig
    do {
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                var result = ""
                for try await event in client.stream(
                    messages: [ChatMessage(role: .user, text: prompt)], system: system, config: boundedConfig) {
                    try Task.checkCancellation()
                    switch event {
                    case .text(let text):
                        result += text
                        guard result.utf8.count <= 8192 else { throw LLMClientError.invalidResponse }
                    case .thinking:
                        continue
                    case .toolCall:
                        // 没给工具还要调工具：不是一份审查结论。
                        throw LLMClientError.invalidResponse
                    }
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
    } catch {
        if !(error is CancellationError) {
            let detail = String(String(describing: error).prefix(300))
            AppLogger.warn("AI 审批请求失败（model=\(config.model)）：\(detail)", category: "agent")
        }
        throw error
    }
}
