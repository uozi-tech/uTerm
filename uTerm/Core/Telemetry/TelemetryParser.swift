import Foundation

/// 远程主机遥测的**纯解析**层 —— 把一次合并命令的输出解析成原始数值。
/// 无状态、无格式化（CPU% 差分与滚动历史在 `TelemetryModel`），便于单测。
///
/// Linux 优先：数据取自 `/proc`、`/etc/os-release`、`df`。非 Linux（无 `/proc`）
/// 时对应字段解析为 nil —— 调用方据此降级，不伪造。
nonisolated enum TelemetryParser {

    /// 一次轮询发的合并命令。各段以 `echo __UT_X__` 行分隔；每条取数命令都
    /// `2>/dev/null`，整串恒以 `echo` 收尾 → 退出码 0，避免
    /// `executeCommand` 在非零退出时抛 `SSHCommandError.nonZeroExit`。sshd 把整串交给登录 shell 执行，故
    /// `;` / 管道 / 重定向都成立。
    static let command: String = [
        "echo __UT_OS__",    "uname -s 2>/dev/null",
        "echo __UT_REL__",   "cat /etc/os-release 2>/dev/null",
        "echo __UT_UP__",    "cat /proc/uptime 2>/dev/null",
        "echo __UT_LOAD__",  "cat /proc/loadavg 2>/dev/null",
        "echo __UT_STAT__",  "grep '^cpu ' /proc/stat 2>/dev/null",
        "echo __UT_NPROC__", "nproc 2>/dev/null",
        "echo __UT_MEM__",   "cat /proc/meminfo 2>/dev/null",
        "echo __UT_DISK__",  "df -kP / 2>/dev/null | tail -1",
        "echo __UT_TIME__",  "date +%s 2>/dev/null",
        "echo __UT_END__",
    ].joined(separator: "; ")

    /// 一次解析得到的原始数值快照（全 optional —— 非 Linux / 命令缺失时为 nil）。
    struct RawSample: Equatable, Sendable {
        var osName: String?          // uname -s，如 "Linux" / "Darwin"
        var prettyName: String?      // os-release PRETTY_NAME，如 "Ubuntu 22.04 LTS"
        var uptimeSeconds: Double?
        var load1: Double?
        var cpuIdle: UInt64?         // idle + iowait jiffies
        var cpuTotal: UInt64?        // 所有 jiffies 之和
        var cores: Int?
        var memTotalKB: UInt64?
        var memAvailableKB: UInt64?
        var diskTotalKB: UInt64?
        var diskUsedKB: UInt64?
        var diskPercent: Int?
        var epoch: Int?

        /// 拿到了 /proc 数据即视为 Linux 主机。
        var isLinux: Bool { uptimeSeconds != nil || memTotalKB != nil || cpuTotal != nil }
    }

    static func parse(_ output: String) -> RawSample {
        var sample = RawSample()
        let sections = splitSections(output)

        if let os = sections["OS"]?.first, !os.isEmpty { sample.osName = os }

        if let rel = sections["REL"] {
            for line in rel where line.hasPrefix("PRETTY_NAME=") {
                sample.prettyName = unquote(String(line.dropFirst("PRETTY_NAME=".count)))
                break
            }
        }

        if let up = sections["UP"]?.first {
            sample.uptimeSeconds = Double(up.split(separator: " ").first.map(String.init) ?? "")
        }

        if let load = sections["LOAD"]?.first {
            sample.load1 = Double(load.split(separator: " ").first.map(String.init) ?? "")
        }

        if let stat = sections["STAT"]?.first {
            // 格式：cpu  user nice system idle iowait irq softirq steal guest guest_nice
            let nums = stat.split(separator: " ", omittingEmptySubsequences: true)
                .dropFirst()                       // 去掉 "cpu" 标签
                .compactMap { UInt64($0) }
            if nums.count >= 4 {
                let idle = nums[3] + (nums.count > 4 ? nums[4] : 0)  // idle + iowait
                sample.cpuIdle = idle
                sample.cpuTotal = nums.reduce(0, +)
            }
        }

        if let np = sections["NPROC"]?.first { sample.cores = Int(np) }

        if let mem = sections["MEM"] {
            for line in mem {
                if line.hasPrefix("MemTotal:") { sample.memTotalKB = firstUInt(line) }
                else if line.hasPrefix("MemAvailable:") { sample.memAvailableKB = firstUInt(line) }
            }
        }

        if let disk = sections["DISK"]?.first {
            // df -kP /：Filesystem 1024-blocks Used Available Capacity Mounted-on
            let cols = disk.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            if cols.count >= 5 {
                sample.diskTotalKB = UInt64(cols[1])
                sample.diskUsedKB = UInt64(cols[2])
                sample.diskPercent = Int(cols[4].replacingOccurrences(of: "%", with: ""))
            }
        }

        if let t = sections["TIME"]?.first { sample.epoch = Int(t) }

        return sample
    }

    /// 相邻两次 `/proc/stat` 采样算 CPU 利用率（%）。首次（prev 为 nil）或数据异常
    /// 返回 nil。结果夹到 0...100。
    static func cpuPercent(prevIdle: UInt64?, prevTotal: UInt64?,
                           idle: UInt64?, total: UInt64?) -> Double? {
        guard let pi = prevIdle, let pt = prevTotal,
              let i = idle, let t = total, t > pt else { return nil }
        let dTotal = Double(t - pt)
        let dIdle = Double(i >= pi ? i - pi : 0)
        guard dTotal > 0 else { return nil }
        return min(100, max(0, (1 - dIdle / dTotal) * 100))
    }

    // MARK: - helpers

    /// 按 `__UT_X__` 标记行把输出切成各段（保留段内非空行）。
    private static func splitSections(_ output: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("__UT_"), line.hasSuffix("__") {
                let name = String(line.dropFirst(5).dropLast(2))  // __UT_OS__ → OS
                current = (name == "END") ? nil : name
                if let current { result[current] = [] }
            } else if let c = current, !line.isEmpty {
                result[c, default: []].append(line)
            }
        }
        return result
    }

    /// 去掉 os-release 值两侧的引号。
    private static func unquote(_ s: String) -> String {
        var r = s.trimmingCharacters(in: .whitespaces)
        if r.count >= 2, r.hasPrefix("\""), r.hasSuffix("\"") {
            r = String(r.dropFirst().dropLast())
        }
        return r
    }

    /// 取一行里第一个能解析的无符号整数（如 "MemTotal: 4030788 kB" → 4030788）。
    private static func firstUInt(_ line: String) -> UInt64? {
        for tok in line.split(separator: " ") where UInt64(tok) != nil {
            return UInt64(tok)
        }
        return nil
    }
}
