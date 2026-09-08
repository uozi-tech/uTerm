import CoreGraphics
import UIKit
import Vision

// 抄自 uTerm `uTermTests/Support/VisionTextProbe.swift`（uTerm commit `2791b0b5`），
// 那份又抄自 uTable `uTableTests/VisionTextProbe.swift`（uTable commit `aaea666`）。
//
// 移植到 iOS 时的改动（只做平台所需的最小改动）：
// 1. `import AppKit` → `import UIKit` / `CoreGraphics`；
// 2. `inkFraction(_ rep: NSBitmapImageRep)` → `inkFraction(_ image: CGImage)`
//    + `inkFraction(png:)` 便捷式。iOS 没有 `NSBitmapImageRep.colorAt(x:y:)`，
//    改成把图画进一个 8-bit RGBA `CGContext` 再按行采样。
//    **判据本身一字未改**：仍然是「非**众数**颜色的像素占比」，不是「非白像素占比」。
//    众数当背景色是有意的 —— 深色主题下「非白」会把整块背景算成墨迹，判据失效。
// 3. `perform` 上桌面已去掉的 `@concurrent` 同样没有（`uTermMobileTests` 也没开
//    `SWIFT_APPROACHABLE_CONCURRENCY`）。target 默认隔离是 `nonisolated`，
//    调用点在 `Task.detached` 里，「离开主线程再跑」这条约束仍然成立。
//
// 其余（CPU 计算设备、90s 预算、`OnceGate`）与桌面一字不差。
//
// `VNRecognizeTextRequest` 在 iOS 18 起标了 deprecated（新 API 是 Vision 的
// `RecognizeTextRequest`），但仍然可用。**刻意不换**：桌面那份用的就是它，
// 换了以后两端的识别结果不再可比，而这套夹具的全部价值就是两端口径一致。

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
///
/// **模拟器上更要守这条**：iOS 模拟器里的 Vision 走宿主 Mac 的 CPU，第一次请求
/// 常要 3~10s；`MobileProbeRig.snapshot(ocr:)` 默认**不开** OCR，只做墨迹判据，
/// 要认字的探针自己传 `ocr: true`。
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

    // MARK: - 墨迹判据

    /// 非**背景色**像素占比：识别器超时时的兜底判据，「空壳」依旧判红。
    ///
    /// 背景色取采样里的**众数**（与桌面版同一口径），不是写死的白 ——
    /// 深色主题下写死白会把整块背景算成墨迹，判据当场失效。
    ///
    /// 采样密度也与桌面版一致：长宽各取至多 200 个点（`stepX = max(1, w/200)`），
    /// 3x 屏上全扫要几百万次 `colorAt`，而这条判据只用来挡空壳。
    nonisolated static func inkFraction(_ image: CGImage) -> Double {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let stepX = max(1, width / 200), stepY = max(1, height / 200)
        var sampled: [UInt32] = []
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let i = (y * width + x) * 4
                let key = UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2])
                sampled.append(key)
                counts[key, default: 0] += 1
            }
        }
        guard !sampled.isEmpty,
              let background = counts.max(by: { $0.value < $1.value })?.key else { return 0 }
        return Double(sampled.filter { $0 != background }.count) / Double(sampled.count)
    }

    /// PNG 字节的便捷式。截图夹具（`MobileProbeRig.snapshot`）直接给的是 PNG。
    nonisolated static func inkFraction(png: Data) -> Double {
        guard let image = UIImage(data: png)?.cgImage else { return 0 }
        return inkFraction(image)
    }
}
