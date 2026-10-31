import Foundation
import Observation

/// 设置页模型下拉背后的实时模型列表（一个 provider 端点一份）。
///
/// 每次 `load` 都顶掉上一次：用户已经改掉的端点，其在途请求的结果不会落地。
/// 在 Base URL / API Key 输入框里打字时带去抖，不至于每敲一下发一次请求。
@MainActor
@Observable
final class ProviderModelList {
    nonisolated struct Request: Equatable, Sendable {
        var kind: ProviderKind
        var baseURL: String
        var apiKey: String
    }

    nonisolated enum Phase: Equatable, Sendable {
        /// 还没法问（Base URL 不合法；输入框自己会报错）。
        case idle
        case loading
        /// 端点答复了，可能为空。
        case loaded([String])
        /// 面向用户的原因；`retry()` 重发上一次请求。
        case failed(String)
    }

    typealias Fetch = @Sendable (ProviderKind, URL, String) async throws -> [String]

    private(set) var phase: Phase = .idle

    @ObservationIgnored private let fetch: Fetch
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastRequest: Request?

    init(fetch: @escaping Fetch = { kind, baseURL, apiKey in
        try await ProviderModelCatalog.fetchModels(kind: kind, baseURL: baseURL, apiKey: apiKey)
    }) {
        self.fetch = fetch
    }

    var isLoading: Bool { phase == .loading }

    func load(_ request: Request, debounce: Duration = .zero) {
        task?.cancel()
        lastRequest = request
        guard case .success(let baseURL) = ProviderEndpointPolicy.resolve(
            configuredBaseURL: request.baseURL, kind: request.kind) else {
            phase = .idle
            return
        }
        phase = .loading
        let fetch = fetch
        task = Task { [weak self] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            let result: Phase
            do {
                result = .loaded(try await fetch(request.kind, baseURL, request.apiKey))
            } catch {
                result = .failed(ProviderModelCatalog.message(for: error))
            }
            guard !Task.isCancelled else { return }
            self?.phase = result
        }
    }

    func retry() {
        if let lastRequest { load(lastRequest) }
    }

    /// 等在途请求落定；测试用来观察最终 phase。
    func waitUntilSettled() async {
        await task?.value
    }
}

/// 模型下拉实际展示的选项：拉到的列表，外加「已保存但端点不再提供」的那个模型
/// —— 旧选择保持可见（照常使用）并打警示，而不是被悄悄换掉。
nonisolated struct ProviderModelChoices: Equatable {
    let models: [String]
    /// `saved` 非空，且不在端点**确实返回了**的列表里。
    let savedIsMissing: Bool

    init(phase: ProviderModelList.Phase, saved: String) {
        guard case .loaded(let fetched) = phase else {
            models = saved.isEmpty ? [] : [saved]
            savedIsMissing = false
            return
        }
        if saved.isEmpty || fetched.contains(saved) {
            models = fetched
            savedIsMissing = false
        } else {
            models = [saved] + fetched
            savedIsMissing = true
        }
    }

    /// 搜索框用：不区分大小写的子串过滤。
    func filtered(by query: String) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(needle) }
    }
}
