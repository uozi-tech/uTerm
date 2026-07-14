import UDesignKit
// uTerm/Views/ImageBody.swift
import SwiftUI
import AppKit

/// 图片预览。默认适应窗口，点击切 1:1。
struct ImageBody: View {
    let buffer: FileBuffer
    @State private var oneToOne = false
    /// 解码一次后缓存，避免每次 body 重算都重新 `NSImage(data:)`（大图开销可观）。
    @State private var phase: DecodePhase = .pending

    var body: some View {
        Group {
            switch phase {
            case .decoded(let img):
                ScrollView([.horizontal, .vertical]) {
                    image(img)
                        .onTapGesture { oneToOne.toggle() }
                        .accessibilityLabel("图片预览")
                        .accessibilityValue(oneToOne ? "原始尺寸" : "适应窗口")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("点击切换原始尺寸与适应窗口")
                        .help(oneToOne ? "点击适应窗口" : "点击查看原始尺寸")
                }
            case .pending:
                // 解码前不显示错误，避免有效图片出现一帧「无法解码」闪烁。
                Color.clear
            case .failed:
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(UD.text3)
                    Text("无法解码图片")
                        .foregroundStyle(UD.text2)
                    Text(buffer.remotePath)
                        .font(.caption)
                        .foregroundStyle(UD.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: EditorTheme.background))
        // 仅在 buffer 或其图片数据变化时解码一次，而非每次渲染。用
        // (id, 字节数, 数据版本) 作为轻量标识，避免对大 Data 做整段相等比较。
        // dataVersion 在 imageData 每次重新赋值时单调递增，覆盖「字节数相同但内容
        // 不同」的重载场景——否则 (id, byteCount) 不变会让旧图残留在屏幕上。
        .task(id: DecodeKey(id: buffer.id, byteCount: buffer.imageData?.count, dataVersion: buffer.dataVersion)) {
            if let img = buffer.imageData.flatMap(NSImage.init(data:)) {
                phase = .decoded(img)
            } else {
                phase = .failed
            }
        }
    }

    private enum DecodePhase {
        case pending
        case decoded(NSImage)
        case failed
    }

    /// 解码缓存的失效键：buffer 切换或图片数据出现/变更时触发重新解码。
    private struct DecodeKey: Equatable {
        let id: UUID
        let byteCount: Int?
        let dataVersion: Int
    }

    @ViewBuilder
    private func image(_ img: NSImage) -> some View {
        if oneToOne {
            Image(nsImage: img)
                .interpolation(.high)
                .frame(width: img.size.width, height: img.size.height)
        } else {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
