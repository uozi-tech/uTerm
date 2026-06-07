import Foundation

/// 所有 LLMClient 实现共享的错误类型。
enum LLMClientError: Error, Equatable {
    case httpError(status: Int, body: String)
    case invalidResponse
}
