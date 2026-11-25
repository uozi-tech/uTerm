import Foundation
import Synchronization
import NIOCore
import USSHKit

/// 把打包的 `uterm-holder` 装到主机上（用户目录，不需要 root）。
///
/// 只在接入时发现「没装」才走这里，一台主机一个版本只装一次。经 exec 通道把二进制写进文件：
/// 不依赖 SFTP 子系统（有的主机关掉了）。
nonisolated enum HostHolderInstaller {
    enum Outcome: Sendable, Equatable {
        case installed
        /// 这台主机用不了（不是 Linux、架构不支持、退出登录时会清进程）。已在主机上留了标记，之后不再试。
        case unsupported(String)
        /// 这次没装成（连接问题、App 包里没有二进制）。下次连接再试。
        case failed(String)
    }

    private static let timeout = Duration.seconds(60)
    private static let uploadChunkBytes = 64 * 1024

    static func install(on client: ConnectedClient, bundle: Bundle = .main) async -> Outcome {
        let outcome = await BoundedTask.run(timeout: timeout) { await performInstall(on: client, bundle: bundle) }
        return outcome ?? .failed("安装超时")
    }

    private static func performInstall(on client: ConnectedClient, bundle: Bundle) async -> Outcome {
        guard let uname = try? await client.exec("uname -sm") else { return .failed("读不到主机的系统信息") }
        guard let resource = HostHolder.resourceName(forUname: uname) else {
            let reason = "unsupported system " + uname.trimmingCharacters(in: .whitespacesAndNewlines)
            await markUnsupported(on: client, reason: reason)
            return .unsupported(reason)
        }
        guard let binary = HostHolder.bundledBinary(named: resource, in: bundle) else {
            return .failed("App 包里没有 \(resource)")
        }
        guard let report = HostHolder.parseProbe(await upload(binary, on: client)) else {
            return .failed("传到主机上之后没能运行")
        }
        guard report.isUsable else {
            let reason = report.survivesLogout == "no" ? "logind kills user processes at logout" : "version mismatch"
            await markUnsupported(on: client, reason: reason)
            return .unsupported(reason)
        }
        return .installed
    }

    /// 标准输入送二进制，返回标准输出（装成了的话里面有 `probe` 的结果）。
    ///
    /// 不看有没有抛错：成不成只看输出里有没有 `probe` 的那一行（命令非零退出、通道出错都体现在输出里少了那一行）。
    private static func upload(_ binary: Data, on client: ConnectedClient) async -> String {
        let collected = Mutex(Data())
        try? await client.target.withExec(HostHolder.installCommand(byteCount: binary.count)) { inbound, writer in
            var sent = 0
            while sent < binary.count {
                let end = min(sent + uploadChunkBytes, binary.count)
                try await writer.write(ByteBuffer(bytes: binary[sent..<end]))
                sent = end
            }
            for try await chunk in inbound {
                if case .stdout(let buffer) = chunk {
                    collected.withLock { $0.append(contentsOf: buffer.readableBytesView) }
                }
            }
        }
        return collected.withLock { String(decoding: $0, as: UTF8.self) }
    }

    private static func markUnsupported(on client: ConnectedClient, reason: String) async {
        _ = try? await client.exec(HostHolder.markUnsupportedCommand(reason: reason))
    }
}

/// 给一段操作加时限：到点先返回 nil，并取消那段操作（USSHCore 的 exec / 开通道响应取消，会随之结束）。
nonisolated enum BoundedTask {
    static func run<Value: Sendable>(timeout: Duration,
                                     operation: @escaping @Sendable () async -> Value) async -> Value? {
        let (results, continuation) = AsyncStream.makeStream(of: Value?.self)
        let working = Task { continuation.yield(await operation()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            continuation.yield(nil)
        }
        defer {
            working.cancel()
            timer.cancel()
            continuation.finish()
        }
        for await result in results { return result }
        return nil
    }
}
