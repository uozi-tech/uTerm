import Foundation

/// 测试用 URLProtocol 拦截器：注册后由
/// `URLSession.shared.configuration.protocolClasses` 拦截，
/// 把请求回放成预设的 (statusCode, headers, body) 流。
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    // 用类锁保护——XCTest 串行跑同一文件，并发风险有限，但显式锁更稳。
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) private static var lastRequest: URLRequest?

    static func install(responder: @escaping (URLRequest) -> (HTTPURLResponse, Data)) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
        self.lastRequest = nil
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    static func uninstall() {
        lock.lock(); defer { lock.unlock() }
        URLProtocol.unregisterClass(StubURLProtocol.self)
        self.responder = nil
    }

    static func capturedRequest() -> URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return lastRequest
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.lastRequest = request
        let responder = Self.responder
        Self.lock.unlock()
        guard let (response, body) = responder?(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 用 StubURLProtocol 装一个独立 URLSession，避免污染 URLSession.shared。
func makeStubbedSession() -> URLSession {
    let cfg = URLSessionConfiguration.ephemeral
    cfg.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: cfg)
}
