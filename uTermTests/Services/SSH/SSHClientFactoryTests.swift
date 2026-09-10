import Citadel
import XCTest
@testable import uTerm

/// `SSHClientFactory` 里唯一能脱离真连接单测的东西：SSH 子通道窗口的取值。
///
/// 建连本身要真的握手（`USSHKitIntegration.connect` 不构造也不返回 settings，全在
/// uAppKit 内部拼），所以这里只钉住常量本身 —— 它是 SFTP 并行下载能不能跑满流水线
/// 的唯一旋钮，改错了不会编译失败，只会悄悄退化成 128 KiB 默认窗口。
final class SSHClientFactoryTests: XCTestCase {

    func testChannelWindowOptionsRequestOneMebibytePackets() {
        XCTAssertEqual(
            SSHClientFactory.channelWindowOptions,
            [.maximumPacketSize(1 << 20)],
            "子通道入站窗口 = maximumPacketSize；掉回默认 128 KiB 会把 SFTP 下载卡在 4 个在途读请求"
        )
    }

    /// NIOSSH 的 `SSHPacketParser.init` 有两条 precondition：`>= 32768` 与
    /// `<= (1 << 24)`，越界不是报错而是**进程 abort**。把边界也钉在测试里，免得
    /// 以后有人「顺手调大一点」调到 32 MiB。
    func testChannelWindowSizeStaysInsideNIOSSHPreconditions() {
        let size = 1 << 20
        XCTAssertGreaterThanOrEqual(size, 32_768, "低于 RFC 4254 最小包长，NIOSSH 会 precondition 失败")
        XCTAssertLessThanOrEqual(size, 1 << 24, "超过 NIOSSH 上限，NIOSSH 会 precondition 失败")
    }
}
