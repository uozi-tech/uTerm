// 界面画廊对比用的像素比对：两张 PNG 逐像素比，输出变化像素数、占比与变化区域外框。
//
// 用法：swift scripts/ui-gallery-pixdiff.swift <pairs.json>
//   pairs.json = [{"key": "...", "before": "/abs/a.png", "after": "/abs/b.png"}, ...]
// 输出（stdout）：{"key": {"changed": N, "total": M, "bbox": [x, y, w, h] | null, "sizeChanged": bool}}
// bbox 用像素坐标、左上角为原点。由 scripts/ui-gallery.py diff 调用；只用系统框架。
import CoreGraphics
import Foundation
import ImageIO

struct Pair: Decodable { let key: String; let before: String; let after: String }

func rgba(_ path: String) -> (data: [UInt8], w: Int, h: Int)? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let ok = data.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return true
    }
    return ok ? (data, w, h) : nil
}

let pairs = try JSONDecoder().decode([Pair].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
var out: [String: Any] = [:]
for p in pairs {
    guard let a = rgba(p.before), let b = rgba(p.after) else { out[p.key] = ["error": "unreadable"]; continue }
    if a.w != b.w || a.h != b.h {
        out[p.key] = ["changed": b.w * b.h, "total": b.w * b.h, "bbox": [0, 0, b.w, b.h], "sizeChanged": true]
        continue
    }
    var changed = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    a.data.withUnsafeBufferPointer { pa in
        b.data.withUnsafeBufferPointer { pb in
            for y in 0..<a.h {
                let row = y * a.w * 4
                for x in 0..<a.w {
                    let i = row + x * 4
                    // 容差 6：抗锯齿 / 颜色管理的 ±1~2 抖动不算变化。
                    if abs(Int(pa[i]) - Int(pb[i])) > 6 || abs(Int(pa[i + 1]) - Int(pb[i + 1])) > 6
                        || abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 6 || abs(Int(pa[i + 3]) - Int(pb[i + 3])) > 6 {
                        changed += 1
                        if x < minX { minX = x }; if x > maxX { maxX = x }
                        if y < minY { minY = y }; if y > maxY { maxY = y }
                    }
                }
            }
        }
    }
    // 位图内存第 0 行就是图像顶行，坐标直接是左上角原点。
    let bbox: Any = changed == 0 ? NSNull() : [minX, minY, maxX - minX + 1, maxY - minY + 1]
    out[p.key] = ["changed": changed, "total": a.w * a.h, "bbox": bbox, "sizeChanged": false]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: out))
