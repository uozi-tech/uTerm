import NIOCore
import NIOEmbedded
import XCTest
@testable import USSHKit

final class DirectTCPIPAsyncChannelTests: XCTestCase {
    func testPreparedChannelKeepsServerGreetingDeliveredImmediatelyAfterInitialization() async throws {
        let channel = NIOAsyncTestingChannel()
        let asyncChannel = try await channel.testingEventLoop.executeInContext {
            try DirectTCPIPAsyncChannelPreparation.wrap(channel)
        }

        var greeting = channel.allocator.buffer(capacity: 8)
        greeting.writeString("greeting")

        try await asyncChannel.executeThenClose { inbound, _ in
            var iterator = inbound.makeAsyncIterator()
            try await channel.writeInbound(greeting)
            let received = try await iterator.next()

            XCTAssertEqual(received.map { String(buffer: $0) }, "greeting")
        }
    }
}
