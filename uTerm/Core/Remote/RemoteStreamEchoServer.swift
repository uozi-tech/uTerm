import Foundation

// 被控端（远控进程里的中继注册）用；单独成文件，远控进程不必编主控端的诊断矩阵。
/// Mac 这一端：把中继回拨进来的字节原样弹回，到时间就关。
nonisolated enum RemoteStreamEchoServer {
    static let lifetime: Duration = .seconds(30)

    static func serve(_ transport: any RemoteTransport) async {
        let queue = DispatchQueue(label: "com.uozi.uTerm.remote.relay-echo")
        let done = RemoteEchoDone()
        transport.start(queue: queue) { event in
            switch event {
            case .failed, .cancelled: done.finish()
            case .ready, .waiting: break
            }
        }
        @Sendable func pump() {
            transport.receive(maximumLength: 64 * 1024) { data, isComplete, error in
                if let data, !data.isEmpty { transport.send(data) { _ in } }
                if isComplete || error != nil {
                    done.finish()
                    return
                }
                pump()
            }
        }
        queue.async { pump() }
        let clock = ContinuousClock()
        let deadline = clock.now + lifetime
        while !done.isFinished, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        queue.async { transport.cancel() }
    }
}

private nonisolated final class RemoteEchoDone: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func finish() {
        lock.lock()
        finished = true
        lock.unlock()
    }
}
