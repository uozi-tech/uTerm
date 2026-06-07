import Foundation
@testable import uTerm

/// 可控的 `TerminalBackend` 测试替身。测试可注入输出、触发退出，
/// 并检查收到的写入与 resize。
actor MockBackend: TerminalBackend {
    nonisolated let outputStream: AsyncStream<Data>
    nonisolated let exitStream: AsyncStream<Void>
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let exitContinuation: AsyncStream<Void>.Continuation

    private(set) var didConnect = false
    private(set) var writtenData: [Data] = []
    private(set) var resizes: [(cols: UInt16, rows: UInt16)] = []
    private(set) var didClose = false
    /// 若设置，`connect()` 抛此错误。
    var connectError: Error?
    /// 若设置，`connect()` 会先 await 此 continuation，由测试调用
    /// `releaseConnect()` 放行 —— 用于构造 connect 挂起期间的重入场景。
    private var connectGate: CheckedContinuation<Void, Never>?
    private var connectGateArmed = false

    init() {
        (outputStream, outputContinuation) = AsyncStream<Data>.makeStream()
        (exitStream, exitContinuation) = AsyncStream<Void>.makeStream()
    }

    func connect() async throws {
        if connectGateArmed {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                connectGate = cont
            }
        }
        if let connectError { throw connectError }
        didConnect = true
    }

    /// 武装 connect 闸门：下一次 `connect()` 将挂起直到 `releaseConnect()`。
    func armConnectGate() { connectGateArmed = true }

    /// 放行被 `armConnectGate()` 挂起的 `connect()`。
    func releaseConnect() {
        connectGateArmed = false
        connectGate?.resume()
        connectGate = nil
    }
    func write(_ data: Data) async { writtenData.append(data) }
    func resize(cols: UInt16, rows: UInt16) async { resizes.append((cols, rows)) }
    func close() async { didClose = true; outputContinuation.finish() }

    // 测试驱动入口
    func emitOutput(_ data: Data) { outputContinuation.yield(data) }
    func emitExit() { exitContinuation.yield(()); exitContinuation.finish() }
    func setConnectError(_ error: Error) { connectError = error }
}
