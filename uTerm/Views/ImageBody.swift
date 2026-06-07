// uTerm/Views/ImageBody.swift
import SwiftUI
import AppKit

/// 图片预览。默认适应窗口，点击切 1:1。
struct ImageBody: View {
    let buffer: FileBuffer
    @State private var oneToOne = false

    var body: some View {
        Group {
            if let data = buffer.imageData, let img = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    image(img)
                        .onTapGesture { oneToOne.toggle() }
                        .accessibilityLabel("图片预览")
                        .accessibilityValue(oneToOne ? "原始尺寸" : "适应窗口")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("点击切换原始尺寸与适应窗口")
                        .help(oneToOne ? "点击适应窗口" : "点击查看原始尺寸")
                }
            } else {
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
