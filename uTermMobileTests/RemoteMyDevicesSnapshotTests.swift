import CryptoKit
import SwiftUI
import UIKit
import XCTest
@testable import uTermMobile

/// 「我的设备」页面和别的设备想加入时的输码单子（设备组）在 iOS 上长什么样：把几个状态各画一张，存成附件。
///
/// 这两处只在模拟器 / 真机上才看得到，Mac 的 `SettingsPageSnapshotTests` 画的是 Mac 那一版。用例本身只断言
/// 状态走到了、画出来的图不是空的；图是给人看的（`xcresulttool export attachments`，或者日志里打出来的目录）。
/// 名册、本机存储都是内存里的，不碰钥匙串。
@MainActor
final class RemoteMyDevicesSnapshotTests: XCTestCase {
    override func tearDown() {
        MobileProbeWindow.closeAll()
        super.tearDown()
    }

    /// 几台设备共用一份内存名册。
    @MainActor
    private final class Rig {
        let roster = RemoteGroupRoster(storage: RemoteMemorySyncedStorage())

        func device(_ name: String, model: String?, platform: RemoteDevicePlatform) throws -> RemoteDeviceGroup {
            let store = RemoteGroupLocalStore(storage: RemoteMemoryStorage())
            let key = try store.signingKey()
            let identity = Curve25519.KeyAgreement.PrivateKey()
            let local = RemoteGroupDevice(id: UUID(), name: name, model: model, platform: platform.rawValue,
                                          publicKey: identity.publicKey.rawRepresentation,
                                          signingKey: key.publicKey.rawRepresentation, updatedAt: Date())
            let group = RemoteDeviceGroup(local: local, signingKey: key, identityKey: identity, roster: roster, store: store)
            group.refresh()
            return group
        }

        func join(_ candidate: RemoteDeviceGroup, via member: RemoteDeviceGroup) throws {
            candidate.startJoin()
            member.refresh()
            guard case .showingCode(let code, _) = candidate.joinState else { return XCTFail("没显示核对码") }
            XCTAssertTrue(member.submitCode(code, for: candidate.local.id))
            candidate.refresh()
            member.refresh()
            candidate.refresh()
            XCTAssertEqual(candidate.joinState, .joined)
        }
    }

    func testRenderMyDevicesScreenStates() async throws {
        let dir = try outputDirectory()

        let solo = Rig()
        let phone = try solo.device("iPhone Duo", model: "iPhone 17 Pro", platform: .mobile)
        _ = try solo.device("我的 MacBook Pro", model: "MacBook Pro", platform: .mac)
        _ = try solo.device("工作室 iPad Pro", model: "iPad Pro", platform: .mobile)
        phone.refresh()
        XCTAssertFalse(phone.isInGroup)
        try await shootScreen("ios-my-devices-solo", phone, into: dir)

        phone.startJoin()
        guard case .showingCode = phone.joinState else { return XCTFail("没显示核对码") }
        try await shootScreen("ios-my-devices-code", phone, into: dir)

        let group = Rig()
        let mini = try group.device("Mac mini", model: "Mac mini", platform: .mac)
        let duo = try group.device("iPhone Duo", model: "iPhone 17 Pro", platform: .mobile)
        let laptop = try group.device("我的 MacBook Pro", model: "MacBook Pro", platform: .mac)
        let ipad = try group.device("工作室 iPad Pro", model: "iPad Pro", platform: .mobile)
        try group.join(duo, via: mini)
        try group.join(laptop, via: duo)
        mini.refresh()
        duo.refresh()
        XCTAssertEqual(duo.members.count, 3)
        try await shootScreen("ios-my-devices-group", duo, into: dir)

        // 在 mini 上移除 duo（连同它加进来的 laptop）：duo 读到后显示「已被移出」。
        let plan = RemoteGroupRemovalPlan(target: duo.local, cascade: mini.devicesAdmitted(by: duo.local.id))
        mini.remove(plan.ids)
        duo.refresh()
        XCTAssertTrue(duo.isSelfRemoved)
        try await shootScreen("ios-my-devices-removed", duo, into: dir)

        // 组员一侧的输码单子（iPad 想加入，另一台手机上弹）：等输入、正在核对、输错后换了新数。
        let host = Rig()
        let member = try host.device("iPhone Duo", model: "iPhone 17 Pro", platform: .mobile)
        let newcomer = try host.device("工作室 iPad Pro", model: "iPad Pro", platform: .mobile)
        _ = ipad
        let service = RemoteDeviceGroupService(makeModel: { _ in member }, makeFastChannel: { _, _ in nil })
        service.tick()
        newcomer.startJoin()
        service.tick()
        let request = try XCTUnwrap(service.pendingRequest)
        try await shootSheet("ios-join-sheet-waiting", service, into: dir)
        guard case .showingCode(let code, _) = newcomer.joinState else { return XCTFail("新设备没显示核对码") }
        let wrong = String(format: "%06d", ((Int(code) ?? 0) + 1) % 1_000_000)
        XCTAssertTrue(service.submit(wrong, for: request))
        try await shootSheet("ios-join-sheet-verifying", service, into: dir)
        newcomer.refresh()
        service.tick()
        try await shootSheet("ios-join-sheet-wrong", service, into: dir)

        print("RemoteMyDevicesSnapshotTests 的图在：\(dir.path)")
    }

    // MARK: - 画图

    private func shootScreen(_ name: String, _ model: RemoteDeviceGroup, into dir: URL) async throws {
        let service = RemoteDeviceGroupService(makeModel: { _ in model }, makeFastChannel: { _, _ in nil })
        service.tick()
        try await shoot(name, size: CGSize(width: 393, height: 760), into: dir) {
            NavigationStack { RemoteMyDevicesScreen() }
                .environment(service)
        }
    }

    private func shootSheet(_ name: String, _ service: RemoteDeviceGroupService, into dir: URL) async throws {
        try await shoot(name, size: CGSize(width: 393, height: 420), into: dir) {
            RemoteGroupJoinSheet()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(M.canvas)
                .environment(service)
        }
    }

    private func shoot<V: View>(_ name: String, size: CGSize, into dir: URL, @ViewBuilder _ content: () -> V) async throws {
        for dark in [false, true] {
            let (window, host) = MobileProbeWindow.make(size: size, placement: .visibleOnScreen, rootView: content())
            window.overrideUserInterfaceStyle = dark ? .dark : .light
            host.view.backgroundColor = .clear
            for _ in 0..<6 {
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                try await Task.sleep(for: .milliseconds(80))
            }
            let renderer = UIGraphicsImageRenderer(bounds: host.view.bounds)
            let image = renderer.image { _ in _ = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let data = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(data.count, 4_000, "\(name) 画出来几乎是空的")
            let file = "\(name)-\(dark ? "dark" : "light").png"
            try data.write(to: dir.appendingPathComponent(file))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = file
            attachment.lifetime = .keepAlways
            add(attachment)
            MobileProbeWindow.close(window)
        }
    }

    private func outputDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("uTermMobile-my-devices-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
