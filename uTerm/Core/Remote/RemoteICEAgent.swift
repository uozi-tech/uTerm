import CJuice
import Foundation

/// libjuice 的一个 ICE agent：收集候选地址、打洞、收发 UDP 数据报。
///
/// 回调都切到 `queue` 上发出。`close()` 之后不会再有回调进队列，已经在队列里的可能还会执行。
nonisolated final class RemoteICEAgent: @unchecked Sendable {
    enum Phase: Equatable, Sendable {
        case disconnected, gathering, connecting, connected, completed, failed

        var isConnected: Bool { self == .connected || self == .completed }
    }

    struct Handlers: Sendable {
        var onPhase: @Sendable (Phase) -> Void = { _ in }
        var onCandidate: @Sendable (String) -> Void = { _ in }
        var onGatheringDone: @Sendable () -> Void = {}
        var onData: @Sendable (Data) -> Void = { _ in }
    }

    private final class Callbacks: @unchecked Sendable {
        let queue: DispatchQueue
        let handlers: Handlers

        init(queue: DispatchQueue, handlers: Handlers) {
            self.queue = queue
            self.handlers = handlers
        }
    }

    private static let configureLogging: Void = {
        // 日志里有 IP 地址，也不想让它往标准输出写。
        juice_set_log_level(JUICE_LOG_LEVEL_NONE)
    }()

    private let lock = NSLock()
    private var agent: OpaquePointer?
    private let callbacks: Unmanaged<Callbacks>

    /// `stunHost` 为 nil 时只有本机地址，打不了跨 NAT 的洞。
    init?(stunHost: String?, stunPort: UInt16, queue: DispatchQueue, handlers: Handlers) {
        _ = Self.configureLogging
        callbacks = Unmanaged.passRetained(Callbacks(queue: queue, handlers: handlers))
        var config = juice_config_t()
        config.concurrency_mode = JUICE_CONCURRENCY_MODE_POLL
        config.stun_server_port = stunPort
        config.user_ptr = callbacks.toOpaque()
        config.cb_state_changed = { _, state, pointer in
            guard let box = RemoteICEAgent.box(pointer) else { return }
            let phase = RemoteICEAgent.phase(state)
            box.queue.async { box.handlers.onPhase(phase) }
        }
        config.cb_candidate = { _, sdp, pointer in
            guard let box = RemoteICEAgent.box(pointer), let sdp else { return }
            let candidate = String(cString: sdp)
            box.queue.async { box.handlers.onCandidate(candidate) }
        }
        config.cb_gathering_done = { _, pointer in
            guard let box = RemoteICEAgent.box(pointer) else { return }
            box.queue.async { box.handlers.onGatheringDone() }
        }
        config.cb_recv = { _, data, size, pointer in
            guard let box = RemoteICEAgent.box(pointer), let data else { return }
            let bytes = Data(bytes: data, count: size)
            box.queue.async { box.handlers.onData(bytes) }
        }
        // juice_create 会复制这个字符串。
        let created: OpaquePointer?
        if let stunHost {
            created = stunHost.withCString { host in
                config.stun_server_host = host
                return juice_create(&config)
            }
        } else {
            created = juice_create(&config)
        }
        guard let created else {
            callbacks.release()
            return nil
        }
        agent = created
    }

    deinit {
        close()
    }

    func gather() -> Bool {
        withAgent { juice_gather_candidates($0) == JUICE_ERR_SUCCESS } ?? false
    }

    /// 本机的 ufrag、密码和目前收集到的候选地址。第一个调用它的一方成为 controlling。
    func localDescription() -> String? {
        withAgent { agent -> String? in
            var buffer = [CChar](repeating: 0, count: Int(JUICE_MAX_SDP_STRING_LEN))
            guard juice_get_local_description(agent, &buffer, buffer.count) == JUICE_ERR_SUCCESS else { return nil }
            return Self.string(buffer)
        } ?? nil
    }

    /// 对端的描述。一方在调用 `localDescription` 之前调这个，就成为 controlled。
    func setRemote(_ description: String) -> Bool {
        withAgent { agent in
            guard description.utf8.count < Int(JUICE_MAX_SDP_STRING_LEN),
                  juice_set_remote_description(agent, description) == JUICE_ERR_SUCCESS else { return false }
            return juice_set_remote_gathering_done(agent) == JUICE_ERR_SUCCESS
        } ?? false
    }

    @discardableResult
    func send(_ data: Data) -> Bool {
        withAgent { agent in
            data.withUnsafeBytes { bytes in
                juice_send(agent, bytes.bindMemory(to: CChar.self).baseAddress, bytes.count) == JUICE_ERR_SUCCESS
            }
        } ?? false
    }

    /// 打通后实际用的那对候选地址。
    func selectedCandidates() -> (local: String, remote: String)? {
        withAgent { agent -> (local: String, remote: String)? in
            let size = Int(JUICE_MAX_CANDIDATE_SDP_STRING_LEN)
            var local = [CChar](repeating: 0, count: size)
            var remote = [CChar](repeating: 0, count: size)
            guard juice_get_selected_candidates(agent, &local, size, &remote, size) == JUICE_ERR_SUCCESS else {
                return nil
            }
            return (Self.string(local), Self.string(remote))
        } ?? nil
    }

    func close() {
        lock.lock()
        let closing = agent
        agent = nil
        lock.unlock()
        guard let closing else { return }
        juice_destroy(closing)
        callbacks.release()
    }

    private func withAgent<Result>(_ body: (OpaquePointer) -> Result) -> Result? {
        lock.lock()
        defer { lock.unlock() }
        return agent.map(body)
    }

    /// C 缓冲区到第一个 0 为止。
    private static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func box(_ pointer: UnsafeMutableRawPointer?) -> Callbacks? {
        pointer.map { Unmanaged<Callbacks>.fromOpaque($0).takeUnretainedValue() }
    }

    private static func phase(_ state: juice_state_t) -> Phase {
        switch state {
        case JUICE_STATE_GATHERING: return .gathering
        case JUICE_STATE_CONNECTING: return .connecting
        case JUICE_STATE_CONNECTED: return .connected
        case JUICE_STATE_COMPLETED: return .completed
        case JUICE_STATE_FAILED: return .failed
        default: return .disconnected
        }
    }
}

/// 一个候选地址的类型和地址族，不含 IP 和端口。诊断记录只存这个。
nonisolated struct RemoteICECandidateKind: Codable, Hashable, Sendable {
    /// host（本机）、srflx（NAT 映射）、prflx（对端观察到）。
    var type: String
    var isIPv6: Bool

    /// `a=candidate:1 1 UDP 2122317823 192.168.1.2 49160 typ host`
    init?(sdp: String) {
        let fields = sdp.split(whereSeparator: \.isWhitespace)
        guard let typeIndex = fields.firstIndex(of: "typ"), typeIndex >= 2, typeIndex + 1 < fields.count else { return nil }
        type = String(fields[typeIndex + 1])
        isIPv6 = fields[typeIndex - 2].contains(":")
    }

    var label: String { "\(type)-\(isIPv6 ? "v6" : "v4")" }

    /// 一段描述里的全部候选地址。
    static func all(inDescription description: String) -> [RemoteICECandidateKind] {
        description.split(whereSeparator: \.isNewline).compactMap { line in
            line.hasPrefix("a=candidate:") ? RemoteICECandidateKind(sdp: String(line)) : nil
        }
    }
}
