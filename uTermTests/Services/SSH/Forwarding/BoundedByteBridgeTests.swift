import XCTest
import NIOCore
@testable import uTerm

final class BoundedByteBridgeTests: XCTestCase {

    /// FIFO 且不丢字节：N 块按序进、按序出，数量与内容一致。
    func testFIFONoLoss() async {
        let bridge = BoundedByteBridge(highWaterMark: 1 << 19)
        let n: UInt32 = 300
        let producer = Task {
            for i in 0..<n {
                var b = ByteBuffer()
                b.writeInteger(i)
                await bridge.send(b)
            }
            bridge.finish()
        }
        var received: [UInt32] = []
        while let chunk = await bridge.next() {
            var c = chunk
            if let v = c.readInteger(as: UInt32.self) { received.append(v) }
        }
        await producer.value
        XCTAssertEqual(received, Array(0..<n))
    }

    /// 背压把内存钉在上限附近：快生产 + 慢消费，缓冲字节不超 highWaterMark + 单块；且全量不丢。
    func testBackpressureBoundsMemory() async {
        let hwm = 4096
        let chunkSize = 512
        let bridge = BoundedByteBridge(highWaterMark: hwm)
        let n = 600
        let producer = Task {
            for i in 0..<n {
                var b = ByteBuffer()
                b.writeBytes([UInt8](repeating: UInt8(i & 0xff), count: chunkSize))
                await bridge.send(b)
            }
            bridge.finish()
        }
        var count = 0
        var maxBuffered = 0
        while let _ = await bridge.next() {
            count += 1
            maxBuffered = max(maxBuffered, bridge.bufferedBytesForTesting)
            await Task.yield()   // 慢消费者：让生产者跑在前面，制造背压
        }
        await producer.value
        XCTAssertEqual(count, n, "不应丢块")
        XCTAssertLessThanOrEqual(maxBuffered, hwm + chunkSize, "背压应把缓冲钉在上限附近：\(maxBuffered)")
    }

    /// finish 后消费者先排空队列、再得 nil。
    func testFinishDrainsThenNil() async {
        let bridge = BoundedByteBridge()
        var a = ByteBuffer(); a.writeString("a")
        var b = ByteBuffer(); b.writeString("bb")
        await bridge.send(a)
        await bridge.send(b)
        bridge.finish()
        let r1 = await bridge.next()
        let r2 = await bridge.next()
        let r3 = await bridge.next()
        XCTAssertEqual(r1?.readableBytes, 1)
        XCTAssertEqual(r2?.readableBytes, 2)
        XCTAssertNil(r3)
    }

    /// finish 能唤醒挂在空桥上的消费者（→ nil），不死锁。
    func testFinishUnblocksWaitingConsumer() async {
        let bridge = BoundedByteBridge()
        let consumer = Task { await bridge.next() }
        try? await Task.sleep(for: .milliseconds(20))   // 让消费者先挂起
        bridge.finish()
        let r = await consumer.value
        XCTAssertNil(r)
    }

    /// 取消能唤醒挂在空桥上的消费者（→ nil），不死锁（否则本测试会超时）。
    func testCancelUnblocksWaitingConsumer() async {
        let bridge = BoundedByteBridge()
        let consumer = Task { await bridge.next() }
        try? await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        let r = await consumer.value
        XCTAssertNil(r)
    }

    /// 取消能唤醒挂在满桥上的生产者（send 返回），不死锁。
    func testCancelUnblocksBlockedProducer() async {
        let bridge = BoundedByteBridge(highWaterMark: 16)
        // 先把桥填满（不消费）。
        var seed = ByteBuffer(); seed.writeBytes([UInt8](repeating: 0, count: 64))
        await bridge.send(seed)   // 单块 > hwm，但队列空可入；之后桥满
        let producer = Task {
            var b = ByteBuffer(); b.writeBytes([UInt8](repeating: 1, count: 64))
            await bridge.send(b)   // 此时桥满 → 挂起
        }
        try? await Task.sleep(for: .milliseconds(20))
        producer.cancel()
        await producer.value      // 必须返回，不挂起
    }
}
