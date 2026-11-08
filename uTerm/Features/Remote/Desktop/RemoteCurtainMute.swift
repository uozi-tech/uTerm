import CoreAudio
import Foundation

/// 帘幕期间让 Mac 本机静音（调研 §17.6）。屏幕已经黑了，声音却照样从 Mac 的扬声器放出来，就和帘幕的初衷相反。
///
/// - 开帘幕：记下默认输出设备原来的静音状态，然后静音；设备不支持静音的，记下音量、把音量调到 0。
///   帘幕期间换了输出设备（插耳机、连蓝牙）也照样处理新设备。
/// - 关帘幕：只恢复我们改过的设备，且只恢复到原值（原本就静音的保持静音）。
/// - 崩溃不会像 gamma 那样被系统自动恢复，所以改过什么写进 `DefaultsKey.remoteCurtainMutedOutputs`，
///   下次启动时 `restoreLeftovers` 恢复并清掉。
///
/// 系统声音由 ScreenCaptureKit 在各 app 混音前采集，输出设备静音不影响传到手机的声音（§17.2 待在真机上核实）。
@MainActor
final class RemoteCurtainMute {
    /// 改过的一台设备。按 UID 记：`AudioDeviceID` 重启后会变。
    struct Change: Codable, Equatable {
        var uid: String
        /// 原来的静音状态（这台设备支持静音时）。
        var wasMuted: Bool?
        /// 原来的音量（不支持静音、改的是音量时）。
        var volume: Float?
    }

    static let shared = RemoteCurtainMute(control: CoreAudioOutputControl(), defaults: RemoteLocalState.defaults)

    private let control: any RemoteOutputControl
    private let defaults: UserDefaults
    private(set) var changes: [Change] = []
    private(set) var isEngaged = false
    private var deviceObserver: (any RemoteOutputObservation)?

    init(control: any RemoteOutputControl, defaults: UserDefaults) {
        self.control = control
        self.defaults = defaults
    }

    func engage() {
        guard !isEngaged else { return }
        isEngaged = true
        muteCurrentOutput()
        deviceObserver = control.observeDefaultOutput { [weak self] in
            MainActor.assumeIsolated { self?.muteCurrentOutput() }
        }
    }

    func release() {
        guard isEngaged else { return }
        isEngaged = false
        deviceObserver = nil
        restore(changes)
        changes.removeAll()
        save()
    }

    /// 上次运行在帘幕期间退出（崩溃、强制退出）：把它改过的设备恢复回去。启动时调用一次。
    func restoreLeftovers() {
        guard !isEngaged, let data = defaults.data(forKey: DefaultsKey.remoteCurtainMutedOutputs),
              let leftovers = try? JSONDecoder().decode([Change].self, from: data), !leftovers.isEmpty else { return }
        AppLogger.info("远程桌面：恢复上次帘幕期间静音的 \(leftovers.count) 个输出设备", category: RemoteLog.category)
        restore(leftovers)
        defaults.removeObject(forKey: DefaultsKey.remoteCurtainMutedOutputs)
    }

    private func muteCurrentOutput() {
        guard isEngaged, let uid = control.defaultOutputUID(), !changes.contains(where: { $0.uid == uid }) else { return }
        if let muted = control.isMuted(uid) {
            // 原本就静音的不动，也就不用恢复。
            guard !muted else { return }
            guard control.setMuted(uid, true) else { return }
            changes.append(Change(uid: uid, wasMuted: false))
        } else if let volume = control.volume(uid) {
            guard volume > 0, control.setVolume(uid, 0) else { return }
            changes.append(Change(uid: uid, volume: volume))
        } else {
            AppLogger.info("远程桌面：输出设备不支持静音也不支持调音量，帘幕期间无法静音", category: RemoteLog.category)
            return
        }
        // 先落盘再算数：静音之后立刻崩溃也恢复得回来。
        save()
    }

    private func restore(_ changes: [Change]) {
        for change in changes {
            if let wasMuted = change.wasMuted {
                _ = control.setMuted(change.uid, wasMuted)
            } else if let volume = change.volume {
                _ = control.setVolume(change.uid, volume)
            }
        }
    }

    private func save() {
        if changes.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.remoteCurtainMutedOutputs)
        } else if let data = try? JSONEncoder().encode(changes) {
            defaults.set(data, forKey: DefaultsKey.remoteCurtainMutedOutputs)
        }
    }
}

/// 输出设备的静音 / 音量。生产是 CoreAudio，测试是内存里的假设备（测试不能动真实的扬声器）。
@MainActor
protocol RemoteOutputControl: AnyObject {
    func defaultOutputUID() -> String?
    /// nil = 这台设备不支持静音。
    func isMuted(_ uid: String) -> Bool?
    func setMuted(_ uid: String, _ muted: Bool) -> Bool
    /// nil = 这台设备不支持调音量。
    func volume(_ uid: String) -> Float?
    func setVolume(_ uid: String, _ volume: Float) -> Bool
    /// 默认输出设备变了就回调（在主线程）。返回的对象释放即停止监听。
    func observeDefaultOutput(_ changed: @escaping @Sendable () -> Void) -> any RemoteOutputObservation
}

@MainActor
protocol RemoteOutputObservation: AnyObject {}

@MainActor
final class CoreAudioOutputControl: RemoteOutputControl {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    func defaultOutputUID() -> String? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address = Self.address(kAudioDevicePropertyDeviceUID)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func device(_ uid: String) -> AudioObjectID? {
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }

    func isMuted(_ uid: String) -> Bool? {
        guard let id = device(uid) else { return nil }
        var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func setMuted(_ uid: String, _ muted: Bool) -> Bool {
        guard let id = device(uid) else { return false }
        var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    func volume(_ uid: String) -> Float? {
        guard let id = device(uid) else { return nil }
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    func setVolume(_ uid: String, _ volume: Float) -> Bool {
        guard let id = device(uid) else { return false }
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput)
        var value = Float32(volume)
        return AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }

    func observeDefaultOutput(_ changed: @escaping @Sendable () -> Void) -> any RemoteOutputObservation {
        CoreAudioDefaultOutputObservation(changed)
    }
}

@MainActor
private final class CoreAudioDefaultOutputObservation: RemoteOutputObservation {
    nonisolated(unsafe) private let block: AudioObjectPropertyListenerBlock
    private let address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)

    init(_ changed: @escaping @Sendable () -> Void) {
        block = { _, _ in changed() }
        var address = self.address
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    deinit {
        var address = self.address
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }
}
