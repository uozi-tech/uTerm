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
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.Palette.textMuted)
                    Text("无法解码图片")
                        .foregroundStyle(AppTheme.Palette.textSecondary)
                    Text(buffer.remotePath)
                        .font(.caption)
                        .foregroundStyle(AppTheme.Palette.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
