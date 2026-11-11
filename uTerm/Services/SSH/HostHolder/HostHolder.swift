import Foundation

/// 主机上的会话保持进程（仓库里的 `holder/`，Go 写的 `uterm-holder`）在 App 这头的常量和命令。
///
/// 它持有 PTY：SSH 连接断了（手机退后台、换网络）shell 接着跑，重新连上经 exec 通道接回，
/// 按「已收到的位置」补上断开期间的输出。帧协议与 Mac 上的 `uterm-holder` 相同（`HolderWire.swift`）。
///
/// 二进制随 App 打包（`make holder`），第一次连某台主机时传到用户目录，不需要 root。
/// 传不了、跑不了的主机（不是 Linux、退出登录时会清进程）退回普通的 PTY 通道。
nonisolated enum HostHolder {
    /// 与 `holder/cmd/uterm-holder/main.go` 的 `version` 一字不差（`HostHolderTests` 拦着）。
    /// 文件名带版本：升级 App 后新会话用新版，旧版起的会话不受影响。
    static let version = "0.1.0"
    static let protocolVersion: UInt32 = 1
    /// 没有客户端接着超过这么久，主机上的会话自己结束。App 被系统杀掉之后没人会回来接它，不能永远占着主机。
    static let detachedTimeoutSeconds = 24 * 60 * 60

    /// `uterm-holder` 自己的退出码，加上启动脚本用的两个。
    enum ExitCode {
        static let noSession = 3
        /// 这台主机用不了（装的时候判定过，留了标记）。
        static let unsupported = 126
        static let notInstalled = 127
    }

    /// 主机上放二进制的目录和文件（`$HOME` 留给主机上的 sh 展开）。
    private static let directory = #"$HOME/.local/share/uterm/bin"#
    private static var binary: String { "\(directory)/uterm-holder-\(version)" }

    /// 接入（`create`：没有就新建）会话的命令。之后通道上走帧协议。
    ///
    /// 包一层 `sh -c '…'`：exec 走的是用户的登录 shell，可能是 fish / csh。脚本里不能出现单引号。
    /// 没装返回 127，装的时候判定过用不了返回 126。
    static func attachCommand(sessionID: UUID, create: Bool, cols: UInt16, rows: UInt16,
                              environment: [(name: String, value: String)]) -> String {
        var arguments = "attach --id \(sessionID.uuidString)"
        if create {
            arguments += " --create --cols \(cols) --rows \(rows) --term xterm-256color"
            arguments += " --detached-timeout \(detachedTimeoutSeconds)s"
            for entry in environment where isSafeWord(entry.name) && isSafeWord(entry.value) {
                arguments += " --env \(entry.name)=\(entry.value)"
            }
        }
        return script("""
            if [ -x "$p" ]; then exec "$p" \(arguments); fi; \
            if [ -e "$p.unsupported" ]; then exit \(ExitCode.unsupported); fi; exit \(ExitCode.notInstalled)
            """)
    }

    /// 结束一个会话（连同 shell）。
    static func killCommand(sessionID: UUID) -> String {
        script(#"[ -x "$p" ] && "$p" kill --id \#(sessionID.uuidString)"#)
    }

    /// 装二进制：标准输入送 `byteCount` 字节，装好后跑一次 `probe`（输出一行 JSON）。顺手清掉别的版本。
    static func installCommand(byteCount: Int) -> String {
        script("""
            mkdir -p "$d" && head -c \(byteCount) > "$p.tmp" && chmod 700 "$p.tmp" && mv "$p.tmp" "$p" || exit 1; \
            for f in "$d"/uterm-holder-*; do [ "$f" = "$p" ] || rm -f "$f"; done; "$p" probe
            """)
    }

    /// 记下「这台主机用不了」，之后的连接不再试着装。
    static func markUnsupportedCommand(reason: String) -> String {
        let note = reason.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" }
        return script(#"mkdir -p "$d" && rm -f "$p" && echo "\#(note)" > "$p.unsupported""#)
    }

    private static func script(_ body: String) -> String {
        "sh -c 'd=\"\(directory)\"; p=\"\(binary)\"; \(body)'"
    }

    /// 能不加引号直接放进命令行的词。
    private static func isSafeWord(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "_.-:/@+,".unicodeScalars.contains($0)
        }
    }

    // MARK: - 打包的二进制

    /// `uname -sm` 的输出对应的打包资源名。不是 Linux、或不是这两种架构返回 nil。
    static func resourceName(forUname uname: String) -> String? {
        let words = uname.split(whereSeparator: \.isWhitespace)
        guard words.count >= 2, words[0] == "Linux" else { return nil }
        switch words[1] {
        case "x86_64", "amd64": return "uterm-holder-linux-amd64"
        case "aarch64", "arm64": return "uterm-holder-linux-arm64"
        default: return nil
        }
    }

    /// 打包时用 LZFSE 压过（`scripts/build-host-holder.sh`）。没打进包（没跑 `make holder`）返回 nil。
    static func bundledBinary(named name: String, in bundle: Bundle = .main) -> Data? {
        guard let url = bundle.url(forResource: name, withExtension: "lzfse"),
              let packed = try? Data(contentsOf: url),
              let unpacked = try? (packed as NSData).decompressed(using: .lzfse) else { return nil }
        return unpacked as Data
    }

    // MARK: - probe

    /// `uterm-holder probe` 的输出。
    struct ProbeReport: Decodable, Equatable {
        var version: String
        var `protocol`: UInt32
        /// yes / no / unknown。
        var survivesLogout: String

        /// 能不能用：版本对得上，而且退出登录后会话留得下（查不到算留得下：没有 systemd 的主机查不到）。
        var isUsable: Bool {
            version == HostHolder.version && `protocol` == HostHolder.protocolVersion && survivesLogout != "no"
        }
    }

    /// 输出里可能夹着登录 shell 的 rc 打印的内容，找那一行 JSON。
    static func parseProbe(_ output: String) -> ProbeReport? {
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("{"), let data = line.data(using: .utf8),
                  let report = try? JSONDecoder().decode(ProbeReport.self, from: data) else { continue }
            return report
        }
        return nil
    }
}
