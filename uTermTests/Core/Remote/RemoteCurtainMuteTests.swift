import XCTest
@testable import uTerm

/// 帘幕静音（调研 §16.6）：只改我们改的、只恢复到原值，换输出设备照样处理，崩溃后下次启动恢复。
/// 用内存里的假设备：测试不能动这台 Mac 真实的扬声器。
@MainActor
final class RemoteCurtainMuteTests: XCTestCase {

    private final class FakeOutputs: RemoteOutputControl {
        struct Device { var muted: Bool?; var volume: Float? }
        var devices: [String: Device] = [:]
        var current: String?
        var onChange: (@Sendable () -> Void)?

        final class Observation: RemoteOutputObservation {}

        func defaultOutputUID() -> String? { current }
        func isMuted(_ uid: String) -> Bool? { devices[uid]?.muted }
        func setMuted(_ uid: String, _ muted: Bool) -> Bool {
            guard devices[uid]?.muted != nil else { return false }
            devices[uid]?.muted = muted
            return true
        }
        func volume(_ uid: String) -> Float? { devices[uid]?.volume }
        func setVolume(_ uid: String, _ volume: Float) -> Bool {
            guard devices[uid]?.volume != nil else { return false }
            devices[uid]?.volume = volume
            return true
        }
        func observeDefaultOutput(_ changed: @escaping @Sendable () -> Void) -> any RemoteOutputObservation {
            onChange = changed
            return Observation()
        }
        func switchTo(_ uid: String) {
            current = uid
            onChange?()
        }
    }

    private func defaults() -> UserDefaults {
        let name = "RemoteCurtainMuteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func test_mutes_on_engage_and_restores_original_on_release() {
        let outputs = FakeOutputs()
        outputs.devices = ["speakers": .init(muted: false, volume: 0.6)]
        outputs.current = "speakers"
        let store = defaults()
        let mute = RemoteCurtainMute(control: outputs, defaults: store)
        mute.engage()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, true)
        XCTAssertNotNil(store.data(forKey: DefaultsKey.remoteCurtainMutedOutputs), "静音前先落盘，崩溃也能恢复")
        mute.release()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, false)
        XCTAssertNil(store.data(forKey: DefaultsKey.remoteCurtainMutedOutputs))
    }

    func test_already_muted_device_is_left_alone() {
        let outputs = FakeOutputs()
        outputs.devices = ["speakers": .init(muted: true, volume: 0.6)]
        outputs.current = "speakers"
        let mute = RemoteCurtainMute(control: outputs, defaults: defaults())
        mute.engage()
        XCTAssertTrue(mute.changes.isEmpty)
        mute.release()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, true, "用户原本就静音的，关帘幕后也保持静音")
    }

    func test_device_without_mute_falls_back_to_volume_and_new_outputs_are_muted_too() {
        let outputs = FakeOutputs()
        outputs.devices = ["hdmi": .init(muted: nil, volume: 0.8), "headphones": .init(muted: false, volume: 0.3)]
        outputs.current = "hdmi"
        let mute = RemoteCurtainMute(control: outputs, defaults: defaults())
        mute.engage()
        XCTAssertEqual(outputs.devices["hdmi"]?.volume, 0)
        // 帘幕期间插了耳机：新设备也静音。
        outputs.switchTo("headphones")
        XCTAssertEqual(outputs.devices["headphones"]?.muted, true)
        mute.release()
        XCTAssertEqual(outputs.devices["hdmi"]?.volume, 0.8)
        XCTAssertEqual(outputs.devices["headphones"]?.muted, false)
    }

    /// 帘幕期间崩溃：下次启动从记录里恢复，然后清掉记录。
    func test_leftovers_from_a_crash_are_restored_on_next_launch() {
        let outputs = FakeOutputs()
        outputs.devices = ["speakers": .init(muted: false, volume: 0.5)]
        outputs.current = "speakers"
        let store = defaults()
        RemoteCurtainMute(control: outputs, defaults: store).engage()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, true)
        // 「重新启动」：新实例，没有经过 release。
        let relaunched = RemoteCurtainMute(control: outputs, defaults: store)
        relaunched.restoreLeftovers()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, false)
        XCTAssertNil(store.data(forKey: DefaultsKey.remoteCurtainMutedOutputs))
        relaunched.restoreLeftovers()
        XCTAssertEqual(outputs.devices["speakers"]?.muted, false, "只恢复一次")
    }

    /// 真实 CoreAudio，只读：默认输出设备的 UID 能换回设备、读得到静音或音量（沙盒测试宿主里）。不写任何属性。
    func test_core_audio_reads_default_output_without_changing_it() throws {
        let control = CoreAudioOutputControl()
        guard let uid = control.defaultOutputUID() else { throw XCTSkip("这台机器没有默认输出设备") }
        XCTAssertFalse(uid.isEmpty)
        let muted = control.isMuted(uid)
        let volume = control.volume(uid)
        print("默认输出 \(uid)：静音 \(muted.map(String.init) ?? "不支持")，音量 \(volume.map { String($0) } ?? "不支持")")
        XCTAssertTrue(muted != nil || volume != nil, "内建扬声器至少支持其一")
    }
}
