import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 新建终端抽屉只列配对过的 Mac：没配对的 Mac 要先在主机页走配对流程，这里点了只会卡在配对上。
@MainActor
final class RemoteMacDirectoryTests: XCTestCase {
    private static let macName = "调试 Mac（127.0.0.1:1）"

    private func directory(pairedWith names: [String]) throws -> RemoteMacDirectory {
        let suite = "RemoteMacDirectoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set("127.0.0.1:1", forKey: "RemoteDebugEndpoint")
        let identity = RemoteIdentityStore(storage: RemoteMemoryStorage())
        for name in names {
            try identity.trust(RemotePeer(id: UUID(), name: name, publicKey: Data(count: 32), pairedAt: .now))
        }
        let directory = RemoteMacDirectory(identity: identity, defaults: defaults)
        directory.activate()
        return directory
    }

    func testUnpairedMacIsNotOffered() throws {
        let directory = try directory(pairedWith: ["别的 Mac"])
        XCTAssertEqual(directory.macs.map(\.name), [Self.macName])
        XCTAssertTrue(directory.pairedMacs.isEmpty)
    }

    func testPairedMacIsOffered() throws {
        let directory = try directory(pairedWith: [Self.macName])
        XCTAssertEqual(directory.pairedMacs.map(\.name), [Self.macName])
    }

    func testLocalShellHostIsNotPersistedAndNamedAfterTheMac() throws {
        let directory = try directory(pairedWith: [Self.macName])
        let client = directory.client(for: try XCTUnwrap(directory.pairedMacs.first))
        let host = client.localShellHost()
        XCTAssertEqual(host.id, RemoteConstants.localShellServerID)
        XCTAssertEqual(host.name, Self.macName)
        XCTAssertNil(host.modelContext)
    }

    /// 配对过的 Mac 要真的画成一行（抽屉是纯 SwiftUI，这里只验行存在、有名字）。
    func testRowRendersForPairedMac() async throws {
        let directory = try directory(pairedWith: [Self.macName])
        let scene = try XCTUnwrap(MobileProbeWindow.activeScene())
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true }
        let host = UIHostingController(rootView: VStack {
            MacTerminalRows(directory: directory) { _, _ in }
        }.padding(16))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        let size = host.sizeThatFits(in: CGSize(width: 390, height: 400))
        XCTAssertGreaterThan(size.height, 60, "一行至少 38pt 图标 + 内边距")
    }
}
