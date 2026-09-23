import Darwin
import Foundation
import XCTest
@testable import uTerm

/// 真起一个 `ControlServer`，用裸 Unix socket 打它。从 uTable 的同名用例移植，
/// 去掉了依赖 Python 客户端的几条（`scripts/utermctl` 由另一条线负责，端到端用例
/// 跟着它走），保留纯服务端的不变式：并发上限、I/O 超时、handler 超时后晚到的响应
/// 不双关同一个 fd、stop 时 unlink、socket 路径超长不 bind。
final class ControlServerTests: XCTestCase {

    /// 路径两难：测试宿主是**沙盒**的（macOS 端 Debug 与 Release 都开沙盒），
    /// 写不了 `/tmp`（uTable 那边 Debug 不沙盒，所以它的同名用例用的是 `/tmp`）；
    /// 而沙盒容器里的 `NSTemporaryDirectory()` 又可能长到顶穿 `sun_path` 的 104 字节。
    /// 所以落在容器 tmp 里，并在 setUp 里量一次长度，超了就跳过而不是红一片。
    private var socketURL: URL!
    private var server: ControlServer?

    override func setUp() {
        super.setUp()
        socketURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "uc-\(UUID().uuidString.prefix(8)).sock")
            .standardizedFileURL
    }

    override func tearDown() {
        server?.stop()
        server = nil
        try? FileManager.default.removeItem(at: socketURL)
        super.tearDown()
    }

    /// 起服务端并等 socket 真正出现（accept 循环在自己的队列上异步铺开）。
    private func startServer(
        maxActiveClients: Int = 8,
        maxTransferClients: Int = 4,
        ioTimeout: TimeInterval = 5,
        handlerIdleTimeout: TimeInterval = 10,
        heartbeatInterval: TimeInterval = 10,
        _ handler: @escaping @MainActor @Sendable (ControlRequest) async -> ControlResponse
    ) async throws {
        try XCTSkipUnless(
            socketURL.path.utf8.count <= ControlProtocol.maxSunPathLength - 1,
            "容器临时目录太长，装不下 socket 路径：\(socketURL.path)"
        )
        let server = ControlServer(
            socketURL: socketURL,
            maxActiveClients: maxActiveClients,
            maxTransferClients: maxTransferClients,
            ioTimeout: ioTimeout,
            // 出问题时秒级失败，而不是让每条用例各等两分钟的生产默认值。
            handlerIdleTimeout: handlerIdleTimeout,
            heartbeatInterval: heartbeatInterval,
            requestHandler: handler
        )
        self.server = server
        XCTAssertNil(server.start())

        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: socketURL.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("socket 未在 5 秒内就绪：\(socketURL.path)")
    }

    private func request(_ action: String, id: String = "r1") -> Data {
        Data(#"{"id":"\#(id)","action":"\#(action)"}"#.utf8)
    }

    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - 用例

    func testRoundTripThroughRealSocket() async throws {
        try await startServer { request in
            .success(id: request.id, message: "pong")
        }
        let payload = try await json(sendRaw(request("ping")))
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message"] as? String, "pong")
        XCTAssertEqual(payload["id"] as? String, "r1", "请求 id 必须原样回来，否则并发调用无法对号入座")
    }

    /// 大请求必须**完整**读进来（`terminal-send` 的长文本、续传的长区间表）。读循环的
    /// 收包缓冲只是个 syscall 粒度，任何「按缓冲大小截断 / 只读一次」的退化都会静默丢尾巴。
    func testLargeRequestIsReceivedIntact() async throws {
        // 900 KB 正文（`terminal-send` 的文本），远超单次 recv 的 64 KiB 缓冲，又在 1 MiB 上限内。
        let contentLength = 900_000
        let content = String(repeating: "A", count: contentLength)
        let payload = Data(
            (#"{"id":"big","action":"terminal-send","terminal":"t","path":"/tmp/x","text":""# + content + #""}"#).utf8
        )
        XCTAssertLessThan(payload.count, ControlProtocol.maxRequestBytes, "夹具自身不能超过协议上限")

        // I/O 预算随已到字节增长，但基线要给足：CI 上走 Unix socket 也要几十毫秒。
        try await startServer(ioTimeout: 15) { request in
            .success(
                id: request.id,
                message: "\(request.text?.count ?? -1)|\(request.path ?? "")"
            )
        }

        let response = try await json(sendRaw(payload))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["id"] as? String, "big")
        XCTAssertEqual(
            response["message"] as? String,
            "\(contentLength)|/tmp/x",
            "正文被截断或串位了：服务端看到的 text 长度与发出的不一致"
        )
    }

    /// `SCM_RIGHTS` 随请求交来的 fd 要到得了 handler（经 `ControlRequestContext`），
    /// 而且是同一个文件：handler 往里写，客户端这边读得到。
    func testPassedFileDescriptorReachesTheHandler() async throws {
        try await startServer { request in
            guard let fd = ControlRequestContext.current?.takeFileDescriptor() else {
                return .failure(id: request.id, code: .invalid_request, message: "没收到 fd")
            }
            defer { Darwin.close(fd) }
            let written = Data("来自 handler".utf8).withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            return .success(id: request.id, message: "wrote \(written)")
        }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "fd-\(UUID().uuidString.prefix(6))")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let local = open(file.path, O_RDWR)
        defer { Darwin.close(local) }

        let payload = try await json(sendRaw(request("sftp-get", id: "fd"), passing: local))
        XCTAssertEqual(payload["ok"] as? Bool, true, "\(payload)")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "来自 handler")
    }

    /// 进度行在响应之前、一行一个 JSON；收尾时攒着的最后几段也要带出来（续传账不能缺尾巴）。
    func testProgressLinesPrecedeTheResponseAndNothingIsLost() async throws {
        try await startServer(handlerIdleTimeout: 5) { request in
            let context = ControlRequestContext.current
            context?.setTotal(300)
            for index in 0..<3 {
                context?.recordSegment(ControlByteRange(offset: Int64(index) * 100, length: 100))
                try? await Task.sleep(for: .milliseconds(index == 2 ? 0 : 700))
            }
            return .success(id: request.id, message: "done")
        }
        let text = try await sendRaw(request("sftp-get", id: "p"))
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let objects = try lines.map { line in
            do { return try json(line) } catch {
                XCTFail("读不懂的一行：\(line.debugDescription)；全文：\(text.debugDescription)")
                throw error
            }
        }
        let events = objects.filter { $0["event"] as? String == "progress" }
        XCTAssertGreaterThanOrEqual(events.count, 2, "处理 1.4 秒，0.5 秒一行，至少两行进度")
        let offsets = events.flatMap { ($0["done"] as? [[String: Any]] ?? []).compactMap { $0["offset"] as? Int } }
        XCTAssertEqual(offsets.sorted(), [0, 100, 200], "三段一段不落、不重复")
        XCTAssertEqual(objects.last?["message"] as? String, "done", "最后一行是响应")
        XCTAssertEqual(events.last?["totalBytes"] as? Int, 300)
    }

    func testMalformedRequestIsRejected() async throws {
        try await startServer { request in .success(id: request.id, message: "不该走到这里") }
        // 灌垃圾：服务端必须自己答一条错误，而不是挂死或崩掉。
        let payload = try await json(sendRaw(Data("not json at all".utf8)))
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, "invalid_request")
    }

    /// 读侧 I/O 超时：客户端只发了半条请求就不动了，服务端不能永远占着这条连接。
    func testRequestIOTimeout() async throws {
        try await startServer(ioTimeout: 0.4) { request in
            .success(id: request.id, message: "不该走到这里")
        }
        let text = try await sendRawWithoutEOF(Data(#"{"action":"pi"#.utf8))
        let payload = try json(text)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(payload["code"] as? String, "request_timeout")
    }

    /// handler 超时后**晚到**的响应必须被 token 丢弃：不能第二次关同一个 fd
    /// （fd 号会被下一条连接复用，双关就是把别人的连接关掉）。
    func testHandlerTimeoutAndLateResponseDoesNotDisruptLaterClients() async throws {
        try await startServer(handlerIdleTimeout: 0.3) { request in
            if request.action == .hosts {
                try? await Task.sleep(for: .seconds(1.2))
                return .success(id: request.id, message: "太晚了")
            }
            return .success(id: request.id, message: "pong")
        }

        let slow = try await json(sendRaw(request("hosts", id: "slow")))
        XCTAssertEqual(slow["ok"] as? Bool, false)
        XCTAssertEqual(slow["code"] as? String, "handler_timeout")

        // 等那条晚到的响应真的落下来，再验后续连接照常工作。
        try await Task.sleep(for: .seconds(1.5))
        let after = try await json(sendRaw(request("ping", id: "after")))
        XCTAssertEqual(after["ok"] as? Bool, true)
        XCTAssertEqual(after["message"] as? String, "pong")
        XCTAssertEqual(after["id"] as? String, "after")
    }

    /// handler 超时是**静默**预算而不是总时长：一直在 `IOActivity.touch()` 的 handler
    /// 跑得比预算久也不该被掐（慢链路上的大分片传输、长时间刷输出的命令）。
    func testHandlerThatKeepsReportingProgressOutlivesTheIdleBudget() async throws {
        try await startServer(handlerIdleTimeout: 0.3) { request in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                IOActivity.touch()
            }
            return .success(id: request.id, message: "做完了")
        }
        let payload = try await json(sendRaw(request("hosts")))
        XCTAssertEqual(payload["ok"] as? Bool, true, "持续有进展的 handler 被当成卡死掐掉了")
        XCTAssertEqual(payload["message"] as? String, "做完了")
    }

    /// 处理期间的心跳是前导 `\n`：客户端靠它按静默设 socket 超时，JSON 解析照常。
    func testHeartbeatsPrecedeTheResponseAndKeepItParseable() async throws {
        try await startServer(handlerIdleTimeout: 5, heartbeatInterval: 0.05) { request in
            try? await Task.sleep(for: .milliseconds(400))
            return .success(id: request.id, message: "pong")
        }
        let text = try await sendRaw(request("ping"))
        XCTAssertTrue(text.hasPrefix("\n"), "处理 400 ms、心跳 50 ms，响应前应当有心跳")
        let payload = try json(text)
        XCTAssertEqual(payload["ok"] as? Bool, true)
        XCTAssertEqual(payload["message"] as? String, "pong")
    }

    /// 传输与短请求的槽位分开：传输占满自己的份额后，新的传输拿 `server_busy`，
    /// 但 `ping` 这类短请求照样进得来 —— 并行下载不该把 `run` 挤掉。
    func testTransfersCannotStarveShortRequests() async throws {
        try await startServer(maxActiveClients: 4, maxTransferClients: 1) { request in
            if request.action == .sftpGet {
                try? await Task.sleep(for: .seconds(1))
                return .success(id: request.id, message: "传完了")
            }
            return .success(id: request.id, message: "pong")
        }
        // 第一片占住唯一的传输槽位：发完请求就先不读，最后再收它的响应。
        let first = try connectSocket()
        Self.sendAllBlocking(first, Data(#"{"id":"t1","action":"sftp-get","host":"h","path":"/a"}"#.utf8))
        Darwin.shutdown(first, SHUT_WR)
        try await Task.sleep(for: .milliseconds(300))

        let second = try await json(sendRaw(Data(#"{"id":"t2","action":"sftp-get","host":"h","path":"/b"}"#.utf8)))
        XCTAssertEqual(second["code"] as? String, "server_busy", "传输槽位满了，第二片应当被拒")
        XCTAssertEqual(second["id"] as? String, "t2")

        let ping = try await json(sendRaw(request("ping", id: "p")))
        XCTAssertEqual(ping["ok"] as? Bool, true, "传输占满不该挤掉短请求")

        let done = try await json(drain(first))
        Darwin.close(first)
        XCTAssertEqual(done["message"] as? String, "传完了")
    }

    /// 并发上限：占满槽位后，新连接**先收到 `server_busy` 再**被关掉（不排队、不吃
    /// 内存），已占位的那条仍然拿到自己的响应。
    ///
    /// 关键是那条响应：只 shutdown + close 的话客户端只看得到空响应，分不清
    /// 「服务端忙、退避重试就好」与「socket 坏了、该报错」。
    func testConcurrentClientCapAnswersServerBusyBeforeClosing() async throws {
        try await startServer(maxActiveClients: 1, ioTimeout: 1.5) { request in
            .success(id: request.id, message: "pong")
        }

        // 第一条连接握住槽位：只发半条请求，不发 EOF，服务端 worker 卡在读上。
        let holder = try connectSocket()
        let partial = Data(#"{"action":"pi"#.utf8)
        _ = partial.withUnsafeBytes { Darwin.send(holder, $0.baseAddress, partial.count, 0) }

        // 第二条连接：槽位满 → register 返回 nil → 回一条 server_busy 再 shutdown+close。
        let rejected = try await sendRaw(request("ping", id: "rejected"))
        XCTAssertFalse(rejected.isEmpty, "超出并发上限的连接必须先拿到一条响应，而不是空的 EOF")
        let payload = try json(rejected)
        XCTAssertEqual(payload["ok"] as? Bool, false)
        XCTAssertEqual(
            payload["code"] as? String,
            ControlErrorCode.server_busy.rawValue,
            "被拒的连接必须能和「socket 坏了」区分开"
        )
        XCTAssertFalse(
            (payload["message"] as? String ?? "").isEmpty,
            "错误码要配一句能给人看的话"
        )

        // 收尾：第一条连接读到自己的超时响应，槽位随之释放。
        let text = try await drain(holder)
        Darwin.close(holder)
        XCTAssertEqual(try json(text)["code"] as? String, "request_timeout")
    }

    func testStopRemovesTheSocketFile() async throws {
        try await startServer { request in .success(id: request.id, message: "ok") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        server?.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketURL.path),
            "主开关关掉后 socket 必须消失，客户端才能报「uTerm 没在跑」而不是连上再被拒"
        )
    }

    /// 第二个实例绝不能抢走已被服务的路径 —— 抢了会留下孤儿 listener，
    /// 表现为「uTerm 开着，CLI 却连不上」。
    func testSecondServerDoesNotStealAServedSocket() async throws {
        try await startServer { request in .success(id: request.id, message: "first") }
        let intruder = ControlServer(
            socketURL: socketURL,
            handlerIdleTimeout: 10,
            requestHandler: { request in .success(id: request.id, message: "intruder") }
        )
        intruder.start()
        defer { intruder.stop() }
        try await Task.sleep(for: .milliseconds(400))

        let payload = try await json(sendRaw(request("ping")))
        XCTAssertEqual(payload["message"] as? String, "first", "socket 被后来者抢走了")
    }

    /// 沙盒容器 + 长用户名会把 `sun_path` 顶穿 104 字节。此时必须**不 bind**、
    /// 直接回错误串（进 accept 循环就成了每 2 秒重试一次的死循环）。
    func testTooLongSocketPathIsRefusedBeforeBinding() {
        let long = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: String(repeating: "u", count: 200) + ".sock")
        let server = ControlServer(socketURL: long)
        let error = server.start()
        XCTAssertNotNil(error, "路径超过 sun_path 上限必须拒绝启动")
        XCTAssertTrue(error?.contains("socket 路径过长") == true, error ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: long.path))
        XCTAssertFalse(server.isRunning)
    }

    // MARK: - 裸 socket 工具（**必须离开主线程**）
    //
    // handler 派到 MainActor 上执行，而主线程若正被同步 recv 堵着，handler 永远排不
    // 上号，只会等到超时。所以每个阻塞调用都丢到全局队列上。

    private func connectSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        // 必须开 SO_NOSIGPIPE：并发上限用例里服务端会先把连接关掉，此时再 send
        // 就会收到 SIGPIPE —— 默认处置是**杀死测试宿主**（表现为整个 suite 重跑）。
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let length = MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count
        address.sun_len = UInt8(length)
        // 必须写 `Darwin.connect` —— 裸 `connect` 会撞上 Combine 的同名方法。
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(length))
            }
        }
        XCTAssertEqual(connected, 0, "connect 失败：\(String(cString: strerror(errno)))")
        return fd
    }

    private func sendRaw(_ payload: Data, passing passed: Int32? = nil) async throws -> String {
        let fd = try connectSocket()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                if let passed {
                    Self.sendPassingDescriptor(fd, payload, passed)
                } else {
                    Self.sendAllBlocking(fd, payload)
                }
                shutdown(fd, SHUT_WR)
                let text = Self.drainBlocking(fd)
                Darwin.close(fd)
                continuation.resume(returning: text)
            }
        }
    }

    /// 发一半就不发 EOF，让服务端在读侧等到超时。
    private func sendRawWithoutEOF(_ payload: Data) async throws -> String {
        let fd = try connectSocket()
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                Self.sendAllBlocking(fd, payload)
                let text = Self.drainBlocking(fd)
                Darwin.close(fd)
                continuation.resume(returning: text)
            }
        }
    }

    /// 把整个 payload 写完。阻塞 `send` 对 SOCK_STREAM 通常一次写满，但被信号打断
    /// 后会返回短计数；数 MB 的大请求下这一点不能赌，否则用例会变成间歇超时。
    /// 返回值 <= 0（对端已关 / EPIPE）时直接停，给并发上限那条用例留出正常出口。
    /// 用 `sendmsg` + `SCM_RIGHTS` 把 `passed` 挂在整段请求上发出去（与 utermctl 同形）。
    private static func sendPassingDescriptor(_ fd: Int32, _ payload: Data, _ passed: Int32) {
        var control = [UInt8](repeating: 0, count: MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size)
        control.withUnsafeMutableBytes { raw in
            var header = cmsghdr(
                cmsg_len: socklen_t(raw.count), cmsg_level: SOL_SOCKET, cmsg_type: SCM_RIGHTS)
            withUnsafeBytes(of: &header) { raw.copyMemory(from: $0) }
            var descriptor = passed
            withUnsafeBytes(of: &descriptor) {
                UnsafeMutableRawBufferPointer(rebasing: raw[MemoryLayout<cmsghdr>.size...]).copyMemory(from: $0)
            }
        }
        var bytes = [UInt8](payload)
        bytes.withUnsafeMutableBytes { body in
            control.withUnsafeMutableBytes { controlBytes in
                var vector = iovec(iov_base: body.baseAddress, iov_len: body.count)
                withUnsafeMutablePointer(to: &vector) { vectorPointer in
                    var message = msghdr()
                    message.msg_iov = vectorPointer
                    message.msg_iovlen = 1
                    message.msg_control = controlBytes.baseAddress
                    message.msg_controllen = socklen_t(controlBytes.count)
                    _ = sendmsg(fd, &message, 0)
                }
            }
        }
    }

    private static func sendAllBlocking(_ fd: Int32, _ payload: Data) {
        payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(fd, base + sent, raw.count - sent, 0)
                if count <= 0 {
                    if count < 0 && errno == EINTR { continue }
                    return
                }
                sent += count
            }
        }
    }

    private func drain(_ fd: Int32) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: Self.drainBlocking(fd))
            }
        }
    }

    private static func drainBlocking(_ fd: Int32) -> String {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(buffer, count: count)
        }
        return String(data: received, encoding: .utf8) ?? ""
    }
}
