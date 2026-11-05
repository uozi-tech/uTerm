import BackgroundTasks
import Foundation
import SwiftData
import XCTest
@testable import uTermMobile

/// 并行执行在后台跑：会话由 store 持有（关掉全屏页不停）、后台进度怎么算、
/// 系统后台任务的标识确实登记在 Info.plist 里。
@MainActor
final class ParallelRunSessionTests: XCTestCase {

    private func makeSession(lines: Int = 4, seconds: Double = 0.2) throws -> ParallelRunSession {
        let container = try MobileFixtures.modelContainer(seed: .smoke)
        let profiles = Array(try container.mainContext.fetch(
            FetchDescriptor<ServerProfile>(sortBy: [SortDescriptor(\.sortOrder)])).prefix(2))
        let config = MobileFakeParallelRun.Config.streaming(hosts: 2, lines: lines, seconds: seconds)
        let fake = MobileFakeParallelRun(config: config, targets: profiles)
        let request = ParallelRunRequest(commandID: UUID(), name: "重启服务", command: config.command,
                                         intent: "", aiAssisted: false, serverIDs: profiles.map(\.id))
        let controller = ParallelRunController(
            commandID: request.commandID, commandName: request.name, command: request.command,
            intent: "", aiAssisted: false, targets: profiles, doctor: nil,
            store: QuickCommandStore(context: container.mainContext), container: container, executor: fake)
        let session = ParallelRunSession(request: request)
        session.controller = controller
        controller.start()
        return session
    }

    private func waitDone(_ session: ParallelRunSession) async throws {
        for _ in 0..<100 where session.isRunning { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(session.isRunning, "3 秒内没跑完")
    }

    /// 还在跑时关掉全屏页：会话留着（转到后台）；跑完再关：移除。
    func testClosingWhileRunningKeepsSessionAndClosingWhenDoneRemovesIt() async throws {
        let store = MobileStore()
        let session = try makeSession(lines: 40, seconds: 1.5)
        store.parallelSessions.append(session)
        store.presentedParallel = session

        store.closeParallel(session)
        XCTAssertNil(store.presentedParallel)
        XCTAssertEqual(store.parallelSessions.count, 1, "还在跑，关掉页面不该丢掉这次运行")
        XCTAssertTrue(session.isRunning)

        // 从「正在运行」条回来：拿回的是同一个控制器，不会重跑。
        let controller = session.controller
        store.showParallel(session)
        XCTAssertTrue(store.presentedParallel === session)
        XCTAssertTrue(store.presentedParallel?.controller === controller)

        try await waitDone(session)
        store.closeParallel(session)
        XCTAssertTrue(store.parallelSessions.isEmpty, "跑完了再关，就不必再挂在「正在运行」条上")
        session.controller?.cancel()
    }

    func testProgressTextFollowsController() async throws {
        let session = try makeSession()
        try await waitDone(session)
        XCTAssertEqual(session.progressText, "完成 2/2")
        XCTAssertEqual(ParallelRunSession(request: session.request).progressText, "准备中…")
    }

    /// 后台进度：落定的台记满；在跑的台按步数 / 输出给一点，封顶 80，不会在没落定时报满。
    func testBackgroundProgressUnits() async throws {
        let running = ParallelRunSession(request: ParallelRunRequest(
            commandID: UUID(), name: "x", command: "x", intent: "", aiAssisted: false, serverIDs: []))
        XCTAssertEqual(ParallelBackgroundKeeper.units([running]).total, 100, "控制器没造好也算一份")
        XCTAssertEqual(ParallelBackgroundKeeper.units([running]).done, 0)

        let session = try makeSession()
        try await waitDone(session)
        let (total, done) = ParallelBackgroundKeeper.units([session])
        XCTAssertEqual(total, 200)
        XCTAssertEqual(done, 200)
    }

    /// Info.plist 登记了 `com.uozi.uTerm.parallel.*`：动态标识能注册上；提交时系统不会以
    /// 「不允许」拒绝（不允许 = 少登记了什么）。模拟器上系统可能因为条件不满足拒绝立即运行，那不算错。
    func testContinuedProcessingIdentifierIsPermitted() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("BGContinuedProcessingTask 需要 iOS 26") }
        let identifier = ParallelBackgroundKeeper.identifierPrefix + "test." + UUID().uuidString
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            task.setTaskCompleted(success: true)
        }
        XCTAssertTrue(registered, "Info.plist 的 BGTaskSchedulerPermittedIdentifiers 没登记这个前缀")

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: "测试", subtitle: "测试")
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        } catch let error as BGTaskScheduler.Error {
            print("[bg-submit] \(error.code.rawValue) \(error)")
            XCTAssertNotEqual(error.code, .notPermitted, "系统说不允许：还缺 Info.plist / 后台模式配置")
        }
    }
}
