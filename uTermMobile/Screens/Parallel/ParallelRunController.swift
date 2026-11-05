import Foundation
import SwiftData

// MARK: - iOS 侧的旧名：状态机与状态类型都与 macOS 共用（`uTerm/Features/ParallelRun/`）

typealias PMode = ParallelViewMode
typealias PStatus = ParallelRunStatus
typealias PTone = ParallelLaneTone
typealias PLine = ParallelTermLine
typealias PFailure = ParallelLaneFailure
typealias PAgentStep = ParallelAgentStep
typealias PServerState = ParallelServerState

typealias ParallelRunController = ParallelRunModel

extension ParallelRunModel {
    /// iOS 的装配：模型下发即执行（不审批，与 macOS 的安全档位无关），提示词里写「iOS SSH 终端」。
    convenience init(commandID: UUID, commandName: String, command: String, intent: String,
                     aiAssisted: Bool, targets: [ServerProfile], doctor: ParallelAIDoctor?,
                     store: QuickCommandStore, container: ModelContainer,
                     executor: ParallelCommandExecuting? = nil) {
        self.init(commandID: commandID, commandName: commandName, command: command, intent: intent,
                  aiAssisted: aiAssisted, targets: targets, doctor: doctor,
                  approval: .unrestricted, hostLabel: "iOS SSH 终端",
                  store: store, container: container, executor: executor)
    }
}
