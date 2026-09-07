import AppKit
import CoreML
import Vision

// 抄自 uTable commit aaea666（`git -C <workspace>/uTable log -1 --format=%h -- uTableTests/VisionTextProbe.swift`）。
//
// 移植到 uTerm 时的改动（只做编译所需的最小改动）：
// `perform` 上的 `@concurrent` 去掉了 —— `uTermTests` target 没开
// `SWIFT_APPROACHABLE_CONCURRENCY`，那个属性不可用。它在这里也不必要：
// target 的默认隔离本来就是 `nonisolated`，而调用点在 `Task.detached` 里，
// 「离开主线程再跑」这条约束仍然成立（这正是 `@concurrent` 在 uTable 要保证的事）。
// 其余（CPU 计算设备、90s 预算、`OnceGate`、`inkFraction`）与 uTable 一字不差。

/// 截图判读的公共件：给「夹具是不是真的渲染出了内容」这类断言用。
///
/// 为什么不能直接在测试里同步 `perform`（uTable 2026-09-05 全量跑的教训）：
/// 本进程第一次 `VNRecognizeTextRequest` 在满载机器上拉起 ANE 服务时会整个卡死
/// （日志停在 `numANECores` 之后再无输出）。测试类都是 `@MainActor`，同步 perform
/// 顺手把主 runloop 一起摁住，最后被 XCTest 的 600s execution-time allowance 连宿主
/// 一起打掉——报告里只剩一条没有断言消息的失败。单跑必绿正是因为那时机器空着。
///
/// 所以这里三件事一起做：钉到 CPU 绕开 ANE 冷启动、不在主 actor 上跑、给预算超时就放手。
/// 超时不是「测试通过」，调用方必须退回像素判据（`inkFraction`）继续守住空壳这条线。
enum VisionTextProbe {
    /// 识别到的一行：`box` 是 Vision 的归一化坐标（原点左下），坐标换算留给调用方，
    /// 因为翻转与否取决于被截的那个 view。
    struct Line: Sendable {
        let text: String
        let box: CGRect
    }

    /// 只保证「一次识别最多占用一次」的一次性闸门，超时分支和识别分支抢同一个 continuation。
    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func claim() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }

    /// Vision 的同步 `perform` 必须离开主线程再跑，并钉到 CPU 计算设备绕开 ANE 冷启动。
    private nonisolated static func perform(_ png: Data, languageCorrection: Bool) async throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = languageCorrection
        if let cpu = (try? request.supportedComputeStageDevices)?[.main]?
            .first(where: { if case .cpu = $0 { return true } else { return false } }) {
            request.setComputeDevice(cpu, for: .main)
        }
        try VNImageRequestHandler(data: png, options: [:]).perform([request])
        return (request.results ?? []).compactMap { item in
            guard let text = item.topCandidates(1).first?.string else { return nil }
            return Line(text: text, box: item.boundingBox)
        }
    }

    /// 识别整张图，带预算（默认 90s，正常一张裁剪图 1s 内）。超时就把那个任务丢在后台
    /// 自生自灭并返回 nil，绝不把测试挂在它身上——识别器罢工不是被测视图的问题。
    static func lines(_ png: Data, languageCorrection: Bool = true,
                      budget: Duration = .seconds(90)) async -> [Line]? {
        let gate = OnceGate()
        return await withCheckedContinuation { (cont: CheckedContinuation<[Line]?, Never>) in
            Task.detached {
                let lines = try? await perform(png, languageCorrection: languageCorrection)
                if gate.claim() { cont.resume(returning: lines) }
            }
            Task.detached {
                try? await Task.sleep(for: budget)
                if gate.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// `lines` 的整段文本形式，行序即 Vision 的返回序。
    static func text(_ png: Data, languageCorrection: Bool = true,
                     budget: Duration = .seconds(90)) async -> String? {
        await lines(png, languageCorrection: languageCorrection, budget: budget)?
            .map(\.text).joined(separator: "\n")
    }

    /// 非背景色像素占比：识别器超时时的兜底判据，"空壳"依旧判红。
    nonisolated static func inkFraction(_ rep: NSBitmapImageRep) -> Double {
        let stepX = max(1, rep.pixelsWide / 200), stepY = max(1, rep.pixelsHigh / 200)
        var pixels: [UInt32] = []
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let key = UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255)
                pixels.append(key)
                counts[key, default: 0] += 1
            }
        }
        guard !pixels.isEmpty, let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        return Double(pixels.filter { $0 != background }.count) / Double(pixels.count)
    }
}
