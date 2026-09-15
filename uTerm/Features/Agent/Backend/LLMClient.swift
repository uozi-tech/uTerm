import AgentKit
import Foundation

/// `AssistantModel` 依赖的 LLM 后端抽象。每家 provider 一个实现。
nonisolated protocol LLMClient: Sendable {
    nonisolated func stream(messages: [ChatMessage],
                            system: String,
                            config: LLMRequestConfig)
        -> AsyncThrowingStream<LLMEvent, Error>
}

/// 为 provider 的事件流增加应用层 idle timeout。watchdog 每收到一个事件就续期；
/// 超时后先结束包装流，再取消仍挂在底层 SSE 上的 producer。
nonisolated func withIdleTimeout(
    _ stream: AsyncThrowingStream<LLMEvent, Error>,
    timeout: Duration
) -> AsyncThrowingStream<LLMEvent, Error> {
    AsyncThrowingStream { continuation in
        let controller = LLMStreamIdleTimeoutController(
            timeout: timeout,
            continuation: continuation)
        let producer = Task {
            await controller.start()
            do {
                for try await event in stream {
                    await controller.yield(event)
                }
                if await controller.complete() {
                    continuation.finish()
                }
            } catch {
                if await controller.complete() {
                    continuation.finish(throwing: error)
                }
            }
        }
        Task { await controller.attach(producer) }
        continuation.onTermination = { _ in
            Task { await controller.cancel() }
        }
    }
}

private actor LLMStreamIdleTimeoutController {
    private let timeout: Duration
    private let continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    private var producer: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isFinished = false

    init(
        timeout: Duration,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) {
        self.timeout = timeout
        self.continuation = continuation
    }

    func attach(_ producer: Task<Void, Never>) {
        guard !isFinished else {
            producer.cancel()
            return
        }
        self.producer = producer
    }

    func start() {
        armWatchdog()
    }

    func yield(_ event: LLMEvent) {
        guard !isFinished else { return }
        continuation.yield(event)
        armWatchdog()
    }

    /// 返回 true 表示调用方赢得了落定权，应结束 continuation。
    func complete() -> Bool {
        guard !isFinished else { return false }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        producer = nil
        return true
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        watchdog?.cancel()
        watchdog = nil
        producer?.cancel()
        producer = nil
    }

    private func armWatchdog() {
        watchdog?.cancel()
        let timeout = timeout
        watchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.timeOut()
        }
    }

    private func timeOut() {
        guard !isFinished else { return }
        isFinished = true
        watchdog = nil
        continuation.finish(throwing: LLMClientError.streamIdleTimeout)
        producer?.cancel()
        producer = nil
    }
}
