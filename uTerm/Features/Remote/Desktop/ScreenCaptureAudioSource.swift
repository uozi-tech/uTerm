import CoreMedia
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit 采集系统声音（调研 §16）。
///
/// 单开一个只采声音的 `SCStream`，不与视频共用：视频流会因分辨率、10-bit 切换重建，共用的话每重建一次声音就断一下。
/// 授权就是屏幕录制那一项（系统设置里叫「录屏与系统录音」），不另外要权限、不碰麦克风。
/// 输出统一成 48 kHz、立体声、交错的 Float32（SCK 给的是每声道一块）。
nonisolated final class ScreenCaptureAudioSource: NSObject, RemoteAudioSource, SCStreamOutput, SCStreamDelegate,
    @unchecked Sendable {
    private let displayID: UInt32
    private let queue = DispatchQueue(label: "com.uozi.uTerm.remote.audio.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var onSamples: (@Sendable ([Float], UInt64) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?

    init(displayID: UInt32) {
        self.displayID = displayID
    }

    func start(onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
               onStop: @escaping @Sendable (Error?) -> Void) async throws {
        var target: SCDisplay?
        for attempt in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first { $0.displayID == displayID } ?? content.displays.first
            if target != nil { break }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        guard let target else { throw RemoteDesktopCaptureError.displayNotFound }
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = Int(RemoteAudioPolicy.sampleRate)
        configuration.channelCount = Int(RemoteAudioPolicy.channels)
        // 这条流只要声音：画面压到最小、一秒一帧，交出来也直接丢。
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let stream = SCStream(filter: SCContentFilter(display: target, excludingWindows: []), configuration: configuration,
                              delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        // 不挂画面输出 SCK 会对每一帧打「找不到输出」的日志。
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        install(stream: stream, onSamples: onSamples, onStop: onStop)
        try await stream.startCapture()
    }

    private func install(stream: SCStream, onSamples: @escaping @Sendable ([Float], UInt64) -> Void,
                         onStop: @escaping @Sendable (Error?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.onSamples = onSamples
        self.onStop = onStop
        self.stream = stream
    }

    func stop() {
        lock.lock()
        let stream = self.stream
        self.stream = nil
        onSamples = nil
        onStop = nil
        lock.unlock()
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferIsValid(sampleBuffer),
              let samples = Self.interleaved(sampleBuffer), !samples.isEmpty else { return }
        // 第一个采样的时刻：交到这里的时刻往前推这一块的时长。与视频同一个钟（单调时钟纳秒）。
        let frames = samples.count / Int(RemoteAudioPolicy.channels)
        let duration = UInt64(Double(frames) / RemoteAudioPolicy.sampleRate * 1e9)
        let nanos = DispatchTime.now().uptimeNanoseconds &- duration
        lock.lock()
        let handler = onSamples
        lock.unlock()
        handler?(samples, nanos)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let handler = onStop
        lock.unlock()
        handler?(error)
    }

    /// SCK 的声音是 Float32，通常每声道一块（非交错）；也兼容交错与单声道。统一成立体声交错。
    static func interleaved(_ sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }
        let nonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(format.mChannelsPerFrame)
        var output = [Float](repeating: 0, count: frames * 2)
        do {
            try sampleBuffer.withAudioBufferList { list, _ in
                if nonInterleaved {
                    for (channel, buffer) in list.enumerated() where channel < 2 {
                        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for frame in 0..<frames { output[frame * 2 + channel] = data[frame] }
                    }
                    if list.count == 1 {
                        for frame in 0..<frames { output[frame * 2 + 1] = output[frame * 2] }
                    }
                } else if let buffer = list.first, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                    for frame in 0..<frames {
                        output[frame * 2] = data[frame * channels]
                        output[frame * 2 + 1] = data[frame * channels + min(1, channels - 1)]
                    }
                }
            }
        } catch {
            return nil
        }
        return output
    }
}
