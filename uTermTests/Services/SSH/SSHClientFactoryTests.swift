import USSHKit
import XCTest
@testable import uTerm

/// `SSHClientFactory` 里唯一能脱离真连接单测的东西：SSH 子通道窗口的取值。
///
/// 建连本身要真的握手（配置全在 uAppKit 内部拼），所以这里只钉住数字本身 —— 它是 SFTP 并行下载能不能跑满
/// 流水线的唯一旋钮，改错了不会编译失败，只会悄悄变成别的窗口。NIOSSH 0.15 的窗口 = 最大包长 × 64。
final class SSHClientFactoryTests: XCTestCase {

    /// 终端 / 转发 / 共享连接原来要 1 MiB 窗口，现在拿不到（下限 2 MiB），取最小的包长 32 KiB → 2 MiB。
    /// 照搬旧的 `1 << 20` 当包长会被夹成 512 KiB → 32 MiB 窗口，每条通道最坏压 64 MiB 内存。
    func testChannelMaximumPacketSizeIsTheSmallestAvailable() {
        XCTAssertEqual(SSHClientFactory.channelMaximumPacketSize, 32_768)
        XCTAssertEqual(SSHClientFactory.channelMaximumPacketSize * SSHClientFactory.windowBytesPerPacket, 2 << 20)
    }

    /// 并行传输的专用连接要 16 MiB 窗口：包长 256 KiB。
    func testTransferWindowMapsToPacketSize() {
        XCTAssertEqual(SSHClientFactory.maximumPacketSize(forWindowBytes: ParallelTransfer.Tuning.standard.windowBytes),
                       256 << 10)
        XCTAssertEqual(SSHClientFactory.maximumPacketSize(forWindowBytes: 16 << 20) * SSHClientFactory.windowBytesPerPacket,
                       16 << 20)
    }

    /// 区间与 USSHCore 的一致（它自己也会夹；这里先夹，app 里算出来的数才和真正生效的一样）。
    func testMaximumPacketSizeRangeMatchesUSSHCore() {
        XCTAssertEqual(SSHClientFactory.maximumPacketSizeRange, 32_768...(1 << 19))
        XCTAssertEqual(SSHClientFactory.maximumPacketSizeRange, SSHClient.maximumPacketSizeRange)
    }

    /// 越界值夹回区间。
    func testClampedMaximumPacketSizePinsOutOfRangeValues() {
        XCTAssertEqual(SSHClientFactory.clampedMaximumPacketSize(0), 32_768)
        XCTAssertEqual(SSHClientFactory.clampedMaximumPacketSize(-1), 32_768)
        XCTAssertEqual(SSHClientFactory.clampedMaximumPacketSize(1 << 25), 1 << 19)
        XCTAssertEqual(SSHClientFactory.clampedMaximumPacketSize(.max), 1 << 19)
        XCTAssertEqual(SSHClientFactory.maximumPacketSize(forWindowBytes: 1 << 30), 1 << 19)
        XCTAssertEqual(SSHClientFactory.maximumPacketSize(forWindowBytes: 0), 32_768)
    }

    /// 区间内的值原样通过 —— 夹钳不能顺手改动正常取值。
    func testClampedMaximumPacketSizePassesInRangeValues() {
        for size in [32_768, 1 << 17, 1 << 18, 1 << 19] {
            XCTAssertEqual(SSHClientFactory.clampedMaximumPacketSize(size), size)
        }
    }
}
