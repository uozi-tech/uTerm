import AgentKit
import Foundation

/// `AssistantModel` 依赖的 LLM 后端抽象。每家 provider 一个实现。
nonisolated protocol LLMClient: Sendable {
    nonisolated func stream(messages: [ChatMessage],
                            system: String,
                            config: LLMRequestConfig)
        -> AsyncThrowingStream<LLMEvent, Error>

    /// 这个后端自己按 `config.streamIdleTimeout` 管静默超时。真实的 HTTP 后端为 true：只有
    /// 传输层看得见不产出事件的进展（thinking 与工具参数的增量、思考期间的心跳），按事件计时
    /// 会把「模型还在想」判成卡住。缺省 false（测试替身等），由调用点按事件兜底。
    nonisolated var enforcesIdleTimeout: Bool { get }
}

nonisolated extension LLMClient {
    var enforcesIdleTimeout: Bool { false }

    /// 调用点统一走这个：静默超时恰好套一层 —— 后端自己管的不再套，不管的按事件兜底。
    func streamWithIdleTimeout(messages: [ChatMessage], system: String,
                               config: LLMRequestConfig) -> AsyncThrowingStream<LLMEvent, Error> {
        let events = stream(messages: messages, system: system, config: config)
        return enforcesIdleTimeout ? events : withIdleTimeout(events, timeout: config.streamIdleTimeout)
    }
}

/// 按**事件**计时的静默超时（实现在 AgentKit）：连续 `timeout` 没有事件就以
/// `LLMClientError.streamIdleTimeout` 结束。只给不经传输层的后端兜底用，见 `enforcesIdleTimeout`。
nonisolated func withIdleTimeout(
    _ stream: AsyncThrowingStream<LLMEvent, Error>,
    timeout: Duration
) -> AsyncThrowingStream<LLMEvent, Error> {
    AgentKit.withIdleTimeout(stream, timeout: timeout, timeoutError: LLMClientError.streamIdleTimeout)
}

/// 把请求层抛的 `LLMWireError` 折成本应用的 `LLMClientError`；其余错误（`URLError`、取消…）
/// 原样透传。事件不动。
nonisolated func mappingWireErrors(
    _ stream: AsyncThrowingStream<LLMEvent, Error>
) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                for try await event in stream { continuation.yield(event) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: LLMClientError.map(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}
