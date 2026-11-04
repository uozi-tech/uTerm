import Foundation
@preconcurrency import Network

/// 进程内 TCP 故障代理：测试把手机端的连接指向它，再由它转给真实的 `RemoteHostServer`，
/// 用来模拟「Mac 不可达」和「链路卡死」。不改任何生产代码。
///
/// - `.forwarding`：正常转发。
/// - `.refusing`：已有连接全部断开，新连接接受后立刻关闭（对手机端就是连不上 Mac）。
/// - `.stalled`：连接保持，字节不再转发，也不报错（Wi-Fi 假死、对端消失但 TCP 还没超时）。
nonisolated final class RemoteFaultProxy: @unchecked Sendable {
    enum Mode: Sendable {
        case forwarding
        case refusing
        case stalled
    }

    private final class Pair: @unchecked Sendable {
        let downstream: NWConnection
        let upstream: NWConnection

        init(downstream: NWConnection, upstream: NWConnection) {
            self.downstream = downstream
            self.upstream = upstream
        }

        func cancel() {
            downstream.cancel()
            upstream.cancel()
        }
    }

    private let target: NWEndpoint
    private let queue = DispatchQueue(label: "com.uozi.uTerm.tests.fault-proxy")
    private let listener: NWListener
    // 以下只在 queue 上读写。
    private var mode = Mode.forwarding
    private var pairs: [ObjectIdentifier: Pair] = [:]
    private var acceptedCount = 0
    private var portValue: UInt16?

    init(targetPort: UInt16) throws {
        target = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: targetPort)!)
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self else { return }
            self.portValue = self.listener.port?.rawValue
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    deinit {
        listener.cancel()
    }

    /// 监听端口；还没就绪时 nil。
    var port: UInt16? {
        queue.sync { portValue }
    }

    /// 连进来过多少条连接（判断手机端是否还在重试）。
    var accepted: Int {
        queue.sync { acceptedCount }
    }

    func setMode(_ newMode: Mode) {
        queue.sync {
            mode = newMode
            guard newMode == .refusing else { return }
            for pair in pairs.values { pair.cancel() }
            pairs.removeAll()
        }
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for pair in pairs.values { pair.cancel() }
            pairs.removeAll()
        }
    }

    private func accept(_ downstream: NWConnection) {
        acceptedCount += 1
        guard mode != .refusing else {
            downstream.start(queue: queue)
            downstream.cancel()
            return
        }
        let upstream = NWConnection(to: target, using: .tcp)
        let pair = Pair(downstream: downstream, upstream: upstream)
        pairs[ObjectIdentifier(pair)] = pair
        downstream.start(queue: queue)
        upstream.start(queue: queue)
        pump(from: downstream, to: upstream, pair: pair)
        pump(from: upstream, to: downstream, pair: pair)
    }

    private func pump(from source: NWConnection, to destination: NWConnection, pair: Pair) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty, self.mode != .stalled {
                destination.send(content: data, completion: .contentProcessed { _ in })
            }
            if isComplete || error != nil {
                pair.cancel()
                self.pairs[ObjectIdentifier(pair)] = nil
                return
            }
            self.pump(from: source, to: destination, pair: pair)
        }
    }
}
