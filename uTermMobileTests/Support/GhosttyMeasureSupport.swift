import Darwin
import Foundation
import QuartzCore
import ImageIO
import UIKit
import XCTest
@testable import uTermMobile

// 测量门（docs/ghostty-eval/measure-ios.md）的夹具：内存读数与构成、峰值采样、进程 CPU、测试用 PNG。

// MARK: - 内存

/// 进程内存读数。`phys_footprint` 是 jetsam 判死用的那个数；`os_proc_available_memory()` 是离上限还剩多少。
nonisolated enum MemoryProbe {
    struct Reading: CustomStringConvertible {
        let footprint: Double      // MB
        let available: Double      // MB（jetsam 余量）
        let graphics: Double       // MB（ledger_tag_graphics_footprint：Metal 纹理 / IOSurface 归这里）
        let peak: Double           // MB（进程生命周期峰值）

        var limit: Double { footprint + available }

        var description: String {
            String(format: "footprint=%.1fMB available=%.1fMB limit≈%.0fMB graphics=%.1fMB lifetime-peak=%.1fMB",
                   footprint, available, limit, graphics, peak)
        }
    }

    static func read() -> Reading {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let mb = 1024.0 * 1024.0
        guard kr == KERN_SUCCESS else { return Reading(footprint: 0, available: 0, graphics: 0, peak: 0) }
        return Reading(footprint: Double(info.phys_footprint) / mb,
                       available: Double(os_proc_available_memory()) / mb,
                       graphics: Double(info.ledger_tag_graphics_footprint) / mb,
                       peak: Double(info.ledger_phys_footprint_peak) / mb)
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// 按 VM 区域的 user tag 分账（脏页 + 换出页 ≈ 记进 footprint 的那部分）。
    /// 分类：malloc（tag 1–12）、IOSurface（88）、IOAccelerator（Metal 缓冲 / 纹理，100）、CoreAnimation（51）、
    /// 无 tag（0：Zig 的 page_allocator 直接 mmap，Ghostty 的回滚页在这里）、其余。
    /// 映射进来的 IOSurface 才能在这里看到；Metal 私有纹理只记在 graphics 账本里，所以两边都要看。
    static func breakdown() -> [String: Double] {
        var result: [String: Double] = [:]
        var address: vm_address_t = 0
        let page = Double(getpagesize())
        while true {
            var size: vm_size_t = 0
            var info = vm_region_extended_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<vm_region_extended_info_data_t>.size / MemoryLayout<natural_t>.size)
            var object: mach_port_t = 0
            let kr = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    vm_region_64(mach_task_self_, &address, &size, VM_REGION_EXTENDED_INFO, $0, &count, &object)
                }
            }
            guard kr == KERN_SUCCESS else { break }
            let bytes = Double(info.pages_dirtied + info.pages_swapped_out) * page
            if bytes > 0 {
                let tag = Int32(info.user_tag)
                let key: String
                switch tag {
                case 1...12: key = "malloc"
                case VM_MEMORY_IOSURFACE: key = "iosurface"
                case VM_MEMORY_IOACCELERATOR: key = "ioaccelerator"
                case 51: key = "coreanimation"   // VM_MEMORY_COREANIMATION（= LAYERKIT）
                case 0: key = "untagged"
                case VM_MEMORY_STACK: key = "stack"
                default: key = "other"
                }
                result[key, default: 0] += bytes / 1024 / 1024
            }
            address += size
        }
        return result
    }

    static func describe(_ parts: [String: Double]) -> String {
        parts.sorted { $0.key < $1.key }.map { String(format: "%@=%.1f", $0.key, $0.value) }.joined(separator: " ")
    }

    static func delta(_ after: [String: Double], _ before: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for key in Set(after.keys).union(before.keys) { out[key] = (after[key] ?? 0) - (before[key] ?? 0) }
        return out
    }
}

/// 后台线程每 `interval` 读一次 footprint，记最大值（量「峰值」，生命周期峰值不能清零）。
nonisolated final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var samples = 0
    private var running = true
    private let thread: Thread

    init(interval: TimeInterval = 0.005) {
        let box = SamplerBox()
        thread = Thread {
            while let sampler = box.sampler, sampler.tick() {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        box.sampler = self
        thread.name = "footprint-sampler"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private func tick() -> Bool {
        let now = MemoryProbe.footprintBytes()
        lock.lock(); defer { lock.unlock() }
        peak = max(peak, now)
        samples += 1
        return running
    }

    /// 停下并返回峰值（MB）与采样次数。
    func stop() -> (peakMB: Double, samples: Int) {
        lock.lock(); running = false; let result = (Double(peak) / 1024 / 1024, samples); lock.unlock()
        return result
    }
}

private nonisolated final class SamplerBox: @unchecked Sendable {
    weak var sampler: FootprintSampler?
}

// MARK: - 进程 CPU

nonisolated enum ProcessCPU {
    /// 进程累计 CPU 秒（用户 + 系统，含已退出线程）。
    static func seconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(usage.ru_utime) + s(usage.ru_stime)
    }
}

// MARK: - 测试用图片

nonisolated enum KittyCorpus {
    /// 一张 `width`×`height` 的 PNG：纯色（`rgb`）；`noise` 为真时铺随机像素（压不小，量解码后内存用）。
    static func png(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8), noise: Bool = false) -> Data {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<(width * height) {
            if noise {
                let v = rng.next()
                pixels[i * 4] = UInt8(truncatingIfNeeded: v)
                pixels[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 8)
                pixels[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 16)
            } else {
                pixels[i * 4] = rgb.0; pixels[i * 4 + 1] = rgb.1; pixels[i * 4 + 2] = rgb.2
            }
        }
        let data = NSMutableData()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// 一次发完（`t=d` 直传，`f=100` PNG，`a=T` 传完即显示）。
    static func direct(_ png: Data, id: Int, columns: Int? = nil, rows: Int? = nil) -> String {
        var keys = "a=T,f=100,t=d,i=\(id),q=0"
        if let columns { keys += ",c=\(columns)" }
        if let rows { keys += ",r=\(rows)" }
        return "\u{1B}_G\(keys);\(png.base64EncodedString())\u{1B}\\"
    }

    /// 分块发（每块 4096 个 base64 字符，`m=1` 表示后面还有，最后一块 `m=0`）。
    static func chunked(_ png: Data, id: Int, columns: Int? = nil, rows: Int? = nil) -> String {
        let encoded = Array(png.base64EncodedString())
        var out = ""
        var first = true
        var index = 0
        while index < encoded.count {
            let end = min(encoded.count, index + 4096)
            let more = end < encoded.count ? 1 : 0
            var keys: String
            if first {
                keys = "a=T,f=100,t=d,i=\(id),q=0,m=\(more)"
                if let columns { keys += ",c=\(columns)" }
                if let rows { keys += ",r=\(rows)" }
                first = false
            } else {
                keys = "m=\(more)"
            }
            out += "\u{1B}_G\(keys);\(String(encoded[index..<end]))\u{1B}\\"
            index = end
        }
        return out
    }

    /// 删掉所有图片并释放数据（`d=A`：大写 = 连数据一起删）。
    static let deleteAll = "\u{1B}_Ga=d,d=A\u{1B}\\"
}

// MARK: - 截图像素

nonisolated enum PixelProbe {
    /// 图里有多少比例的像素接近 `target`（每通道差 ≤ 40）。
    static func fraction(of image: CGImage, near target: (r: UInt8, g: UInt8, b: UInt8), in rect: CGRect? = nil) -> Double {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let area = rect.map { $0.intersection(CGRect(x: 0, y: 0, width: width, height: height)) }
            ?? CGRect(x: 0, y: 0, width: width, height: height)
        var hit = 0, total = 0
        for y in Int(area.minY)..<Int(area.maxY) {
            for x in Int(area.minX)..<Int(area.maxX) {
                let i = (y * width + x) * 4
                total += 1
                if abs(Int(pixels[i]) - Int(target.r)) <= 40, abs(Int(pixels[i + 1]) - Int(target.g)) <= 40,
                   abs(Int(pixels[i + 2]) - Int(target.b)) <= 40 { hit += 1 }
            }
        }
        return total > 0 ? Double(hit) / Double(total) : 0
    }
}
