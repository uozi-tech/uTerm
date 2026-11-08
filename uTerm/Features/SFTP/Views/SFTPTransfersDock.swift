import UDesignKit
import SwiftUI

enum SFTPTransfersDockLayout {
    static let statusChipHeight: CGFloat = 22
    static let statusIconFrame = CGSize(width: 12, height: statusChipHeight)
    static let statusIconSize: CGFloat = 11
    static let statusArrowYOffset: CGFloat = 1
}

/// 状态栏芯片一次 body 求值要的全部计数，**一遍扫完**。
///
/// 改前是六次独立的全表扫描：`active`（filter）在芯片分支、聚合芯片、浮层参数里各求
/// 一次，再加 `doneCount` / `failedCount` / `aggPct`（两次 reduce）/ `aggSpeed`（filter + reduce）。
/// 而**每一次进度回调都会写 `transfers[idx]`**（`@Observable` 数组元素），这个 body
/// 也就跟着重求一次 —— 队列里攒了上千条已完成的行时，那是每次进度几千次元素访问。
/// （`@MainActor` 而非 `nonisolated`：`TransferItem` 及其枚举都嵌在 `@MainActor` 的
/// `FileBrowserModel` 里，它们的 `Equatable` 一致性也带主 actor 隔离。）
@MainActor
struct SFTPTransfersDockSummary {
    /// 进行中（排队 + 活动）的条数。
    private(set) var activeCount = 0
    private(set) var doneCount = 0
    private(set) var failedCount = 0
    /// 进行中的全是上传（聚合芯片的文案在「上传」/「传输」之间切）。空集合视作 true。
    private(set) var allActiveAreUploads = true
    /// 仅活动态的速率之和（浮层底部的聚合速率）。排队中的不计。
    private(set) var aggregateSpeed: Double = 0
    /// 进行中条目的整体完成度 0…1。
    private(set) var aggregateFraction: Double = 0
    /// 恰好只有一条进行中时的那一条（状态栏内联进度那一档），否则 nil。
    private(set) var single: FileBrowserModel.TransferItem?

    init(_ transfers: [FileBrowserModel.TransferItem]) {
        var totalBytes: Int64 = 0
        var doneBytes: Int64 = 0
        for item in transfers {
            switch item.status {
            case .queued, .active:
                activeCount += 1
                if item.direction != .up { allActiveAreUploads = false }
                totalBytes += item.bytesTotal
                doneBytes += item.bytesDone
                if activeCount == 1 { single = item } else { single = nil }
                if item.status == .active { aggregateSpeed += item.speedBytesPerSec }
            case .done:
                doneCount += 1
            case .failed:
                failedCount += 1
            }
        }
        aggregateFraction = totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0
    }
}

/// SFTP 传输 Dock —— 状态栏自适应芯片 + 可展开的传输列表浮层。
/// 对齐设计稿 `pages/sftp.jsx` 的 TransfersDock / TransfersPanel / TransferRow：
///   · 仅 1 个进行中 → 状态栏内联进度 + 取消 ✕
///   · ≥2 个进行中  → 聚合芯片「传输 N 个文件 · % ⌄」，点击展开列表
///   · 仅有完成/失败 → 「传输完成」/「N 个传输失败」芯片
///   · 空闲         → 「无进行中的传输」
struct SFTPTransfersDock: View {
    let transfers: [FileBrowserModel.TransferItem]
    let onCancel: (UUID) -> Void
    let onCancelAll: () -> Void
    let onClearFinished: () -> Void
    let onRetry: (UUID) -> Void

    @State private var open = false

    /// 一次 body 求值只扫一遍（见 `SFTPTransfersDockSummary`）。
    private var summary: SFTPTransfersDockSummary { SFTPTransfersDockSummary(transfers) }

    var body: some View {
        let summary = self.summary
        return HStack(spacing: 4) {
            chip(summary)
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            SFTPTransfersPanel(
                transfers: transfers, aggSpeed: summary.aggregateSpeed,
                activeCount: summary.activeCount, doneCount: summary.doneCount,
                onCancel: onCancel, onCancelAll: onCancelAll,
                onClearFinished: onClearFinished, onRetry: onRetry)
        }
    }

    @ViewBuilder private func chip(_ summary: SFTPTransfersDockSummary) -> some View {
        if let s = summary.single {
            singleChip(s)
        } else if summary.activeCount >= 2 {
            aggregateChip(summary)
        } else if summary.doneCount > 0 || summary.failedCount > 0 {
            finishedChip(summary)
        } else {
            idleChip
        }
    }

    // 单文件：内联进度 + 取消
    @ViewBuilder private func singleChip(_ s: FileBrowserModel.TransferItem) -> some View {
        let fraction = UTermFormat.progressFraction(done: s.bytesDone, total: s.bytesTotal)
        let pctText = UTermFormat.progress(fraction)
        let queued = s.status == .queued
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                arrow(s.direction)
                Text(s.fileName).font(UD.mono(11)).foregroundStyle(UD.text2)
                    .lineLimit(1).truncationMode(.middle).frame(maxWidth: 168, alignment: .leading)
                UDLinearBar(progress: queued ? 0 : fraction, height: 5).frame(width: 96)
                Text(queued ? "排队" : pctText).font(UD.mono(11)).foregroundStyle(UD.text3)
                    .frame(width: 32, alignment: .trailing)
                Text(UTermFormat.transferRate(s.speedBytesPerSec)).font(UD.mono(11)).foregroundStyle(UD.text3)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(s.direction == .up ? "上传" : "下载") \(s.fileName)")
        .accessibilityValue(queued ? "排队中" : pctText)
        DockCancelButton(title: "取消传输 \(s.fileName)") { onCancel(s.id) }
    }

    @ViewBuilder private func aggregateChip(_ summary: SFTPTransfersDockSummary) -> some View {
        let allUp = summary.allActiveAreUploads
        let aggPct = summary.aggregateFraction
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                statusIcon("arrow.up", color: UD.accent, weight: .medium,
                           yOffset: SFTPTransfersDockLayout.statusArrowYOffset)
                Text("正在\(allUp ? "上传" : "传输") \(summary.activeCount) 个文件")
                    .foregroundStyle(UD.text2)
                UDLinearBar(progress: aggPct, height: 5).frame(width: 72)
                Text(UTermFormat.progress(aggPct)).font(UD.mono(11)).foregroundStyle(UD.text3)
                    .frame(width: 32, alignment: .trailing)
                chevron
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).frame(height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在\(allUp ? "上传" : "传输") \(summary.activeCount) 个文件")
        .accessibilityValue(UTermFormat.progress(aggPct))
        .accessibilityHint("展开传输列表")
    }

    @ViewBuilder private func finishedChip(_ summary: SFTPTransfersDockSummary) -> some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                if summary.failedCount > 0 {
                    Circle().fill(UD.danger).frame(width: 7, height: 7)
                    Text("\(summary.failedCount) 个传输失败").foregroundStyle(UD.text2)
                } else {
                    statusIcon("checkmark", color: UD.success, size: 9, weight: .bold)
                    Text("传输完成").foregroundStyle(UD.text2)
                }
                chevron
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).frame(height: 22)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var idleChip: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                statusIcon("arrow.up", color: UD.text4,
                           yOffset: SFTPTransfersDockLayout.statusArrowYOffset)
                Text("无进行中的传输").foregroundStyle(UD.text4)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 8).frame(height: 22)
        }
        .buttonStyle(.plain)
    }

    private func arrow(_ d: FileBrowserModel.TransferDirection) -> some View {
        statusIcon(d == .up ? "arrow.up" : "arrow.down", color: UD.accent, weight: .medium,
                   yOffset: SFTPTransfersDockLayout.statusArrowYOffset)
    }
    private func statusIcon(_ systemName: String,
                            color: Color,
                            size: CGFloat = SFTPTransfersDockLayout.statusIconSize,
                            weight: Font.Weight = .regular,
                            yOffset: CGFloat = 0) -> some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(width: SFTPTransfersDockLayout.statusIconFrame.width,
                   height: SFTPTransfersDockLayout.statusIconFrame.height,
                   alignment: .center)
            .offset(y: yOffset)
    }
    private var chevron: some View {
        Image(systemName: open ? "chevron.up" : "chevron.down")
            .font(.system(size: 8, weight: .semibold)).foregroundStyle(UD.text3)
    }
}

/// 状态栏单文件传输旁的取消按钮（hover 变红）。
private struct DockCancelButton: View {
    let title: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                .foregroundStyle(hover ? UD.danger : UD.text3)
                .frame(width: 20, height: 20)
                .background(hover ? UD.danger.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title).onHover { hover = $0 }
    }
}

/// 传输列表浮层（设计稿 TransfersPanel）：头部（计数 + 全部取消/清除已完成）+ 列表 + 底部聚合速率。
struct SFTPTransfersPanel: View {
    let transfers: [FileBrowserModel.TransferItem]
    let aggSpeed: Double
    let activeCount: Int
    let doneCount: Int
    let onCancel: (UUID) -> Void
    let onCancelAll: () -> Void
    let onClearFinished: () -> Void
    let onRetry: (UUID) -> Void

    private var rows: [FileBrowserModel.TransferItem] {
        func rank(_ s: FileBrowserModel.TransferItem.Status) -> Int {
            switch s { case .active: 0; case .queued: 1; case .failed: 2; case .done: 3 }
        }
        return transfers.sorted { rank($0.status) < rank($1.status) }
    }

    var body: some View {
        let orderedRows = rows
        VStack(spacing: 0) {
            header
            Divider().overlay(UD.border)
            if orderedRows.isEmpty {
                Text("没有传输任务").font(.system(size: 12.5)).foregroundStyle(UD.text4)
                    .frame(maxWidth: .infinity).padding(.vertical, 34)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(orderedRows) { t in
                            SFTPTransferRow(item: t, onCancel: { onCancel(t.id) }, onRetry: { onRetry(t.id) })
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Divider().overlay(UD.border)
            footer
        }
        .frame(width: 372)
        .background(UD.overlay)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("传输").font(.system(size: 13, weight: .semibold)).foregroundStyle(UD.text)
                .accessibilityAddTraits(.isHeader)
            Text(activeCount > 0 ? "\(activeCount) 个进行中" : "\(doneCount) 个已完成")
                .font(UD.mono(10.5)).foregroundStyle(UD.text2)
                .padding(.horizontal, 7).padding(.vertical, 1)
                .background(UD.fillSoft, in: Capsule())
            Spacer()
            if activeCount > 0 {
                PanelLinkButton(title: "全部取消", danger: true, action: onCancelAll)
            } else if doneCount > 0 {
                PanelLinkButton(title: "清除已完成", danger: false, action: onClearFinished)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            if aggSpeed > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up").font(.system(size: 10)).foregroundStyle(UD.accent)
                    Text(UTermFormat.transferRate(aggSpeed)).font(UD.mono(11)).foregroundStyle(UD.text3)
                }
            }
        }
        .frame(height: 18)
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

private struct PanelLinkButton: View {
    let title: String
    let danger: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 12))
                .foregroundStyle(hover ? (danger ? UD.danger : UD.text2) : UD.text3)
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

/// 传输列表中的一行（设计稿 TransferRow）。
struct SFTPTransferRow: View {
    let item: FileBrowserModel.TransferItem
    let onCancel: () -> Void
    let onRetry: () -> Void
    @State private var hover = false

    private var fraction: Double { UTermFormat.progressFraction(done: item.bytesDone, total: item.bytesTotal) }
    private var kind: BrowserFileKind { BrowserFileKind.from(name: item.fileName, isDirectory: false) }

    private var subtitle: (String, Color) {
        switch item.status {
        case .active:
            let bytesText = item.bytesTotal > 0
                ? "\(UFormat.bytes(item.bytesDone)) / \(UFormat.bytes(item.bytesTotal))"
                : UFormat.bytes(item.bytesDone)
            let speedText = UTermFormat.transferRate(item.speedBytesPerSec)
            let etaText = UTermFormat.eta(remainingBytes: item.bytesTotal - item.bytesDone,
                                          bytesPerSecond: item.speedBytesPerSec)
            return ("\(bytesText) · \(speedText) · \(etaText)", UD.text4)
        case .queued:
            return ("排队中 · \(UFormat.bytes(item.bytesTotal))", UD.text4)
        case .done:
            return ("已完成 · \(UFormat.bytes(item.bytesTotal))", UD.text4)
        case .failed:
            return (item.direction == .up ? "上传失败 · 点击重试" : "下载失败", UD.danger.opacity(0.8))
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            RemoteFileIcon(kind: kind, size: 15).frame(width: 26).opacity(item.status == .done ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(item.fileName).font(.system(size: 12.5))
                        .foregroundStyle(item.status == .done ? UD.text2 : UD.text)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                    if item.status == .active {
                        Text(UTermFormat.progress(fraction)).font(UD.mono(11)).foregroundStyle(UD.accent)
                    }
                }
                if item.status == .active || item.status == .queued {
                    UDLinearBar(progress: item.status == .active ? fraction : 0,
                                color: item.status == .queued ? UD.text4 : UD.accent, height: 4)
                }
                Text(subtitle.0).font(UD.mono(10.5)).foregroundStyle(subtitle.1)
                    .lineLimit(1).truncationMode(.tail)
            }
            control
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 10)
        .background(hover ? UD.rowHover : .clear)
        .onHover { hover = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.direction == .up ? "上传" : "下载") \(item.fileName)")
        .accessibilityValue(item.status == .active ? "\(UTermFormat.progress(fraction))，\(subtitle.0)" : subtitle.0)
    }

    @ViewBuilder private var control: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                .foregroundStyle(UD.success)
                .frame(width: 18, height: 18).background(UD.success.opacity(0.16), in: Circle())
        case .failed:
            HStack(spacing: 2) {
                if item.direction == .up {
                    RowControlButton(system: "arrow.clockwise", title: "重试", action: onRetry)
                }
                RowControlButton(system: "xmark", title: "移除", action: onCancel)
            }
        case .active, .queued:
            RowControlButton(system: "xmark", title: "取消传输", redOnHover: true, action: onCancel)
        }
    }
}

private struct RowControlButton: View {
    let system: String
    let title: String
    var redOnHover: Bool = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hover && redOnHover ? UD.danger : UD.text3)
                .frame(width: 24, height: 24)
                .background(hover ? (redOnHover ? UD.danger.opacity(0.12) : UD.fillSoft) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title).onHover { hover = $0 }
    }
}
