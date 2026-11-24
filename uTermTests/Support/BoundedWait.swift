import Foundation
import Synchronization
import XCTest

/// 等产品异步事件的上限：到点没等到，用例带着「在等什么」失败，而不是整个套件卡住。
///
/// 等的东西本身不理会取消也没关系（比如停在 `withCheckedContinuation` 里）：结果交给一个续点，
/// 先到的那个（结果或超时）说了算，到点后只取消那个任务、不等它收尾。
struct BoundedWaitTimeout: Error, CustomStringConvertible {
    let what: String
    let seconds: Double
    var description: String { "等了 \(seconds) 秒仍没等到：\(what)" }
}

func bounded<T: Sendable>(
    _ what: String,
    within seconds: Double = 10,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let pending = Mutex<CheckedContinuation<T, any Error>?>(nil)
    @Sendable func finish(_ result: Result<T, any Error>) -> Bool {
        guard let continuation = pending.withLock({ value in defer { value = nil }; return value }) else { return false }
        continuation.resume(with: result)
        return true
    }
    do {
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            let work = Task {
                do { _ = finish(.success(try await operation())) } catch { _ = finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if finish(.failure(BoundedWaitTimeout(what: what, seconds: seconds))) { work.cancel() }
            }
        }
    } catch let timeout as BoundedWaitTimeout {
        XCTFail(timeout.description, file: file, line: line)
        throw timeout
    }
}

/// 逐个取异步流里的元素，每次都有上限。流结束了给 nil。
final class BoundedStream<Element: Sendable>: @unchecked Sendable {
    private var iterator: AsyncStream<Element>.AsyncIterator

    init(_ stream: AsyncStream<Element>) {
        iterator = stream.makeAsyncIterator()
    }

    func next(_ what: String, within seconds: Double = 10,
              file: StaticString = #filePath, line: UInt = #line) async throws -> Element? {
        try await bounded(what, within: seconds, file: file, line: line) { await self.pull() }
    }

    /// 一直取到满足条件的那个元素；流先结束了给 nil。
    func first(_ what: String, within seconds: Double = 10,
               file: StaticString = #filePath, line: UInt = #line,
               where matches: @escaping @Sendable (Element) -> Bool) async throws -> Element? {
        try await bounded(what, within: seconds, file: file, line: line) {
            while let element = await self.pull() {
                if matches(element) { return element }
            }
            return nil
        }
    }

    private func pull() async -> Element? {
        await iterator.next()
    }
}
