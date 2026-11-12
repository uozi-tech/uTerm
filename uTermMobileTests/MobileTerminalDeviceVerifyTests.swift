import Security
import SwiftData
import UIKit
import XCTest
@testable import uTermMobile

/// 真机验证：会话留在主机上（`holder/`）这条链路在真的 iOS 上走一遍——App 真的进后台、进程真的被系统挂起、
/// 进程真的被杀掉再重开。和 `MobileTerminalLiveHostSessionTests` 的区别：那条在一个进程里把对象丢掉重建，
/// 这里每一步都由 Mac 上的驱动脚本 `holder/scripts/device-verify.sh` 从外面动手（切后台、掐连接、杀进程、切回前台），
/// 用例只管连上、发命令、核对结果。终端挂在真窗口里（产品的 `MTerminalContainerView`），画面也一并核对。
///
/// 不单独跑：由驱动脚本按阶段各起一次（`TEST_RUNNER_UTERM_DEVICE_PHASE`）。阶段之间靠主机上的标记文件
///（`/tmp/uterm-verify/…`，由会话里的 shell 自己写）对拍。
///
/// - `suspend`：连上，起一个每半秒吐一行的循环；驱动脚本把 App 切到后台、挂起进程、在主机那头掐掉 SSH 连接、
///   再恢复进程、切回前台。核对：每一行恰好出现一次、顺序不乱，shell 还是原来那个，画面和影子终端一致。
/// - `create`：连上，屏幕上放内容，标签记进归档；驱动脚本把 App 切到后台（终端状态存到主机上），然后杀掉进程。
/// - `restore`：新进程凭归档把标签开回来。核对：被杀之前的内容和之后主机上继续吐的行都在，shell 还是原来那个。
/// - `cleanup`：`restore` 没跑成时，把钥匙串条目和归档清掉。
///
/// 不碰真实数据：主机是内存库里新造的（固定 id，两个阶段要对得上）；密码写成**不同步**的钥匙串条目
///（`KeychainStore.save` 写的是经 iCloud 钥匙串同步的，测试服务器的密码不该出现在别的设备上）；
/// 归档写在单独的偏好域里，不动 `mobile.restorableTerminalTabs`。
@MainActor
final class MobileTerminalDeviceVerifyTests: XCTestCase {
    private nonisolated static let hostID = UUID(uuidString: "D0D0D0D0-0000-4000-8000-00000000F00D")!
    private nonisolated static let suite = "com.uozi.uTerm.deviceVerify"
    private static let markerDirectory = "/tmp/uterm-verify"
    /// `create` 阶段主机上那个循环吐多少行（一秒一行）：要比「杀进程 → 新进程起来」长，重开时它还在跑。
    private static let lifeLines = 150

    private var container: ModelContainer!
    private var profile: ServerProfile!
    private var window: UIWindow?
    private let relay = HostKeyChallengeRelay()

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    private func requirePhase(_ phase: String) throws {
        guard environment["UTERM_DEVICE_PHASE"] == phase else {
            throw XCTSkip("真机验证的 \(phase) 阶段由 holder/scripts/device-verify.sh 起")
        }
    }

    // MARK: 准备

    private nonisolated static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.uozi.uTerm",
            kSecAttrAccount as String: "\(hostID.uuidString)/\(SecretKind.password.rawValue)",
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
    }

    private nonisolated static func removePassword() {
        SecItemDelete(keychainQuery as CFDictionary)
    }

    private nonisolated static func removeArchive() {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private func savePassword(_ password: String) throws {
        Self.removePassword()
        var query = Self.keychainQuery
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse!
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = KeychainStore.accessibility
        let status = SecItemAdd(query as CFDictionary, nil)
        XCTAssertEqual(status, errSecSuccess, "写钥匙串失败（设备锁着的话会是 -25308）")
    }

    /// 内存库里的测试主机，密码进钥匙串。
    private func prepareHost() throws {
        let env = environment
        guard let raw = env["UTERM_LIVE_SSH_PORT"], let port = Int(raw), let host = env["UTERM_LIVE_SSH_HOST"],
              let password = env["UTERM_LIVE_SSH_PASSWORD"] else {
            throw XCTSkip("没给测试主机的地址和密码")
        }
        container = try MobileFixtures.emptyContainer()
        profile = ServerProfile()
        profile.id = Self.hostID
        profile.name = "device-verify"
        profile.host = host
        profile.port = port
        profile.username = env["UTERM_LIVE_SSH_USER"] ?? "dev"
        profile.authMethod = .password
        container.mainContext.insert(profile)
        try container.mainContext.save()
        try savePassword(password)
    }

    /// 把标签的终端挂进真窗口（产品的容器视图，尺寸提交走的也是产品那条路）。
    private func mount(_ tab: TermTab) throws {
        let window = try makeSpikeWindow(size: CGSize(width: 390, height: 600))
        let view = MTerminalContainerView(terminal: tab.controller.terminal, fontSize: 11)
        view.frame = window.bounds
        window.addSubview(view)
        view.layoutIfNeeded()
        self.window = window
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window = nil
        try await super.tearDown()
    }

    // MARK: 读屏

    /// 等条件成立；期间出现的主机密钥确认一律信任（只对测试服务器）。
    private func wait(_ what: String, timeout: Duration = .seconds(30), until done: () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !done() {
            if relay.pendingChallenge != nil { relay.resolve(true) }
            guard ContinuousClock.now < deadline else {
                XCTFail("等不到：\(what)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 终端里的行（含回滚）。命令行本身也会回显在屏幕上，所以下面一律按**整行**比，输出和命令行的写法也故意不一样
    ///（`echo ticks-"done"` 打出来是 `ticks-done`）。
    private func lines(_ tab: TermTab, last count: Int = 600) -> [String] {
        tab.controller.terminal.shadow.recentLines(count).lines
    }

    private func value(_ key: String, in tab: TermTab) -> String? {
        lines(tab).last { $0.hasPrefix("\(key)=") && Int($0.dropFirst(key.count + 1)) != nil }
            .map { String($0.dropFirst(key.count + 1)) }
    }

    /// 形如 `前缀-数字` 的整行，按出现的先后取数字。
    private func numbers(_ prefix: String, in tab: TermTab) -> [Int] {
        lines(tab).compactMap { line in
            guard line.hasPrefix("\(prefix)-") else { return nil }
            return Int(line.dropFirst(prefix.count + 1))
        }
    }

    private func assertSurfaceMatchesShadow(_ tab: TermTab, file: StaticString = #filePath, line: UInt = #line) async {
        let bridge = tab.controller.terminal
        var difference: String?
        await wait("画面和影子终端一致", timeout: .seconds(10), until: {
            guard bridge.isSurfaceReady, bridge.outputPump.isFeedingSurface else { return false }
            difference = GhosttyViewportDiff.firstDifference(surface: bridge.session.readViewportText() ?? "",
                                                             shadow: bridge.shadow.viewportText())
            return difference == nil
        }, file: file, line: line)
        if let difference { XCTFail("画面与影子终端不一致：\(difference)", file: file, line: line) }
    }

    /// 把一段文字经会话写成主机上的文件，驱动脚本从容器里读（真机上测试进程的标准输出不一定能到 xcodebuild）。
    private func report(_ text: String, as name: String, through tab: TermTab) async {
        print(text)
        let done = "report-\(name)-written"
        tab.controller.sendText("cat > \(Self.markerDirectory)/\(name) <<'UTERM_EOF'\n\(text)\nUTERM_EOF\necho report-\(name)-\"written\"\n")
        await wait("写报告 \(name)") { self.lines(tab).contains(done) }
    }

    // MARK: 采样

    /// 每 200 ms 记一次：进程有没有在跑（两次采样隔得远 = 进程被挂起过）、App 在前台还是后台、连接状态、收到第几行。
    private final class Sampler {
        struct Sample {
            var at: TimeInterval
            var appState: String
            var connection: String
            var tick: Int
        }

        private(set) var samples: [Sample] = []
        private var task: Task<Void, Never>?
        private let start = Date()

        @MainActor
        func run(_ read: @escaping @MainActor () -> (connection: String, tick: Int)) {
            task = Task { @MainActor [weak self] in
                while !Task.isCancelled, let self {
                    let state: String = switch UIApplication.shared.applicationState {
                    case .active: "active"
                    case .inactive: "inactive"
                    case .background: "background"
                    @unknown default: "unknown"
                    }
                    let now = read()
                    self.samples.append(Sample(at: Date().timeIntervalSince(self.start), appState: state,
                                               connection: now.connection, tick: now.tick))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }

        func stop() { task?.cancel() }

        /// 给人看的经过：前后台切换、挂起的那段、连接状态的变化、每个节点收到第几行。
        func summary(tickInterval: Double) -> String {
            var out: [String] = []
            func stamp(_ sample: Sample) -> String { String(format: "+%.1fs", sample.at) }
            var stalls: [(from: Sample, to: Sample)] = []
            for (previous, current) in zip(samples, samples.dropFirst()) {
                if current.at - previous.at > 2 { stalls.append((previous, current)) }
                if current.appState != previous.appState {
                    out.append("app \(previous.appState) -> \(current.appState) at \(stamp(current)) (tick \(current.tick))")
                }
                if current.connection != previous.connection {
                    out.append("connection \(previous.connection) -> \(current.connection) at \(stamp(current)) (tick \(current.tick))")
                }
            }
            if stalls.isEmpty {
                out.append("process never stalled (no sampling gap over 2s): it was not suspended")
            }
            for stall in stalls {
                out.append(String(format: "process suspended %@ -> %@ (%.1fs); tick before %d, first sample after %d",
                                  stamp(stall.from), stamp(stall.to), stall.to.at - stall.from.at, stall.from.tick, stall.to.tick))
            }
            if let entered = samples.first(where: { $0.appState == "background" }) {
                let stalledAt = stalls.first(where: { $0.from.at >= entered.at })?.from
                let lastInBackground = stalledAt ?? samples.last(where: { $0.appState == "background" }) ?? entered
                out.append(String(format: "ran in background for %.1fs %@, receiving ticks %d..%d",
                                  lastInBackground.at - entered.at,
                                  stalledAt == nil ? "(until it was brought back)" : "before being suspended",
                                  entered.tick, lastInBackground.tick))
            }
            if let resumed = stalls.last?.to, let host = samples.last {
                // 回来之后多久追平：主机上的循环一直在跑，按时间推它该吐到第几行。
                let caughtUp = samples.first { sample in
                    sample.at >= resumed.at && sample.connection == "connected"
                        && Double(host.tick - sample.tick) * tickInterval <= host.at - sample.at + 1
                }
                if let caughtUp {
                    out.append(String(format: "caught up %.1fs after resuming (tick %d)", caughtUp.at - resumed.at, caughtUp.tick))
                }
            }
            return out.joined(separator: "\n")
        }
    }

    // MARK: 阶段

    /// 进后台 → 进程被挂起 → 连接在主机那头被掐掉 → 回前台：输出一行不多、一行不少，shell 没换。
    func testSuspendedInBackgroundThenBack() async throws {
        try requirePhase("suspend")
        try prepareHost()
        addTeardownBlock { Self.removePassword() }
        let ticks = Int(environment["UTERM_DEVICE_TICKS"] ?? "") ?? 200
        let interval = 0.5

        let tab = TermTab(host: profile)
        try mount(tab)
        tab.controller.start(profile: profile, container: container, relay: relay)
        await wait("连上") { tab.controller.state == .connected }
        tab.controller.sendText("stty -echo; clear; echo PID=$$\n")
        await wait("shell 的进程号") { self.value("PID", in: tab) != nil }
        let pid = try XCTUnwrap(value("PID", in: tab))
        await assertSurfaceMatchesShadow(tab)

        let sampler = Sampler()
        sampler.run {
            (tab.controller.isReconnecting ? "reconnecting" : String(describing: tab.controller.state),
             self.numbers("tick", in: tab).last ?? 0)
        }
        defer { sampler.stop() }
        tab.controller.sendText("mkdir -p \(Self.markerDirectory); touch \(Self.markerDirectory)/suspend-ready; "
            + "for i in $(seq 1 \(ticks)); do echo tick-$i; sleep \(interval); done; echo ticks-\"done\"\n")

        // 之后的事都由驱动脚本做；被挂起的那段时间这个循环也不转，所以超时给足。
        await wait("驱动脚本把 App 切到后台", timeout: .seconds(120)) {
            UIApplication.shared.applicationState == .background
        }
        XCTAssertTrue(tab.controller.isAppInBackground, "控制器要跟着真的进后台通知走")
        await wait("驱动脚本把 App 切回前台", timeout: .seconds(600)) {
            UIApplication.shared.applicationState == .active
        }
        await wait("循环跑完", timeout: .seconds(Double(ticks) * interval + 120)) {
            self.lines(tab).contains("ticks-done")
        }
        await wait("连接恢复") { tab.controller.state == .connected }

        XCTAssertEqual(numbers("tick", in: tab), Array(1...ticks), "每一行恰好一次、顺序不乱")
        tab.controller.sendText("echo AGAIN=$$\n")
        await wait("同一个 shell") { self.value("AGAIN", in: tab) == pid }
        await assertSurfaceMatchesShadow(tab)

        sampler.stop()
        await report(sampler.summary(tickInterval: interval), as: "suspend-report", through: tab)
        tab.controller.close()
    }

    /// 第一次运行：连上、屏幕上有内容、标签记进归档；之后被驱动脚本切到后台、杀掉。
    func testCreateSessionThenGetKilled() async throws {
        try requirePhase("create")
        try prepareHost()
        Self.removeArchive()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))

        let workspace = MobileWorkspace()
        let tab = TermTab(host: profile)
        try mount(tab)
        tab.controller.start(profile: profile, container: container, relay: relay)
        workspace.open(.terminal(tab))
        await wait("连上") { tab.controller.state == .connected }
        tab.controller.sendText("stty -echo; clear; echo PID=$$; echo first-\"run\"-line\n")
        await wait("第一次运行的输出") { self.lines(tab).contains("first-run-line") }
        let pid = try XCTUnwrap(value("PID", in: tab))
        await assertSurfaceMatchesShadow(tab)

        workspace.terminalTabArchive(showsWorkspace: true).save(to: defaults)
        XCTAssertEqual(MobileTerminalTabArchive.load(from: defaults).tabs,
                       [.init(hostID: Self.hostID, sessionID: tab.controller.hostSessionID)])

        // 主机上接着每秒吐一行：进程被杀之后的那些，重开时要补回来。
        tab.controller.sendText("mkdir -p \(Self.markerDirectory); echo \(pid) > \(Self.markerDirectory)/shell-pid; "
            + "touch \(Self.markerDirectory)/create-ready; for i in $(seq 1 \(Self.lifeLines)); do echo life-$i; sleep 1; done; echo life-\"done\"\n")
        await wait("驱动脚本把 App 切到后台", timeout: .seconds(120)) {
            UIApplication.shared.applicationState == .background
        }
        // 进后台时终端状态存到主机上；然后等着被杀。
        try? await Task.sleep(for: .seconds(120))
        XCTFail("驱动脚本没有杀掉进程")
    }

    /// 重新打开：凭归档把标签开回来，画面回来、shell 还是原来那个。
    func testRestoreAfterBeingKilled() async throws {
        try requirePhase("restore")
        try prepareHost()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        addTeardownBlock {
            Self.removePassword()
            Self.removeArchive()
        }

        let archive = MobileTerminalTabArchive.load(from: defaults)
        XCTAssertEqual(archive.tabs.map(\.hostID), [Self.hostID], "被杀之前记下的标签要还在")
        XCTAssertTrue(archive.showsWorkspace)
        let workspace = MobileWorkspace()
        let started = Date()
        let opened = archive.restore(into: workspace, hosts: [profile]) { term in
            term.controller.start(profile: term.host, container: self.container, relay: self.relay)
        }
        let tab = try XCTUnwrap(opened.first)
        try mount(tab)
        await wait("接回") { tab.controller.state == .connected }
        await wait("被杀之前的内容回来了") { self.lines(tab).contains("first-run-line") }
        let restoredAfter = Date().timeIntervalSince(started)
        let firstSeen = numbers("life", in: tab).last ?? 0
        await wait("主机上的循环跑完", timeout: .seconds(Double(Self.lifeLines) + 60)) { self.lines(tab).contains("life-done") }

        XCTAssertEqual(numbers("life", in: tab), Array(1...Self.lifeLines), "被杀前后的输出每一行恰好一次、顺序不乱")
        let pid = try XCTUnwrap(value("PID", in: tab))
        tab.controller.sendText("echo AGAIN=$$\n")
        await wait("同一个 shell") { self.value("AGAIN", in: tab) == pid }
        await assertSurfaceMatchesShadow(tab)

        await report(String(format: "old screen back %.1fs after reopening (terminal at life-%d of %d at that moment); shell pid %@",
                            restoredAfter, firstSeen, Self.lifeLines, pid),
                     as: "restore-report", through: tab)
        _ = workspace.close(tab.id)
        tab.controller.close()
        XCTAssertTrue(workspace.terminalTabArchive(showsWorkspace: false).tabs.isEmpty)
    }

    /// `restore` 没跑成时的善后。
    func testCleanup() throws {
        try requirePhase("cleanup")
        Self.removePassword()
        Self.removeArchive()
    }
}
