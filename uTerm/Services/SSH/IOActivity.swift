import Foundation

/// 「这件事还在往前走」的脉冲：长 I/O 每前进一步（一个 SFTP 回包、一块命令输出）就
/// `touch()` 一次，由外层看门狗据此判断**静默了多久**，而不是**跑了多久**。
///
/// 用 `@TaskLocal` 而不是层层传闭包：脉冲点在 `SFTPPipeline` 这种与调用方毫无关系的
/// 底层（GUI 的 SFTP 窗口也走它），挂在任务上下文里就不用给每个签名加参数；子任务
/// （TaskGroup 的分片、`Task {}`）自动继承。没人设置时 `touch()` 是空操作。
///
/// 现在的设置方是 `ControlServer`（CLI 请求按静默续期）；`Task.detached` 与 NIO
/// 回调不继承 task-local，脉冲点要放在 async 调用链上。
nonisolated enum IOActivity {
    @TaskLocal static var pulse: (@Sendable () -> Void)?

    static func touch() {
        pulse?()
    }
}
