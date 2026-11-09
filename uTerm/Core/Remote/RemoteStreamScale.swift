import Foundation

/// 窄链路上主流按几分之一的尺寸编码。宽链路一直是 `full`。
///
/// 3G（约 0.75 Mbps）上满屏在变时，1856×1206 每帧哪怕 QP 用到最差也有 37–190 KB，发一帧要 0.4–2.2 s，大帧超过
/// 普通帧 1.5 s 的时限被成批放弃，最长卡顿 6.8 s（弱网矩阵 3G 直连，2026-11-09）。像素少一半多，同样的比特
/// 每像素分到的多一倍多，帧变小、发得完。画面静止后旁路精修仍按全尺寸出，看得清。
nonisolated enum RemoteStreamScale: Int, Comparable, CaseIterable, Sendable {
    case half = 0
    case twoThirds = 1
    case full = 2

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// 宽高各乘的比例。
    var factor: Double {
        switch self {
        case .half: 0.5
        case .twoThirds: 2.0 / 3.0
        case .full: 1
        }
    }

    /// 全尺寸 `width`×`height` 按这一档缩后的编码尺寸：宽高同比例缩、取偶数（4:2:0 的色度要成对）。
    func size(width: Int, height: Int) -> (width: Int, height: Int) {
        guard self != .full else { return (width, height) }
        func scaled(_ value: Int) -> Int { max(2, Int((Double(value) * factor / 2).rounded()) * 2) }
        return (scaled(width), scaled(height))
    }
}

/// 该用哪一档。纯函数，测试直接穷举。
nonisolated enum RemoteStreamScalePolicy {
    /// 按这个帧率算每帧的预算。桌面内容动起来大多在 30 fps 上下；按满帧率 60 算会在中等链路上过早降档。
    static let referenceFrameRate = 30.0
    /// 全尺寸下每像素每帧至少分到这么多比特才用全尺寸。1856×1206 时约 2.7 Mbps 的视频份额；
    /// 4608×2592（5K 虚拟屏）约 14 Mbps。
    static let fullFloor = 0.04
    /// 低于它再降到一半。1856×1206 时约 1 Mbps 的视频份额。
    static let twoThirdsFloor = 0.015
    /// 往上升要高出门槛这么多倍：在门槛附近晃时不来回换（每换一次就重建编码器、发一个关键帧）。
    static let upgradeMargin = 1.5
    /// 缩完短边不小于这么多像素：太小的画面缩了也省不了多少，字反倒糊得认不出。
    static let minimumShortSide = 360

    /// 全尺寸下每像素每帧分到的比特数。
    static func bitsPerPixelFrame(videoShare: Double, width: Int, height: Int) -> Double {
        videoShare / (Double(max(1, width * height)) * referenceFrameRate)
    }

    /// 眼下该用哪一档（不含升档的等待，见 `RemoteStreamScaleSelector`）。
    ///
    /// - Parameter limited: 链路估计撞到过上限（排队或大量丢包，见 `RemoteLinkState.limited`）。没撞到过时节奏只是
    ///   还没涨上去（开流时从 8 Mbps 起步、屏幕静止时也不涨），不代表链路窄，一律全尺寸。
    /// - Parameter current: 现在用的档。比它高的档要多给 `upgradeMargin` 的余量才算够格。
    static func wanted(videoShare: Double, limited: Bool, width: Int, height: Int,
                       current: RemoteStreamScale) -> RemoteStreamScale {
        guard limited else { return .full }
        let bits = bitsPerPixelFrame(videoShare: videoShare, width: width, height: height)
        func floor(_ value: Double, for scale: RemoteStreamScale) -> Double {
            scale > current ? value * upgradeMargin : value
        }
        let wanted: RemoteStreamScale
        if bits >= floor(fullFloor, for: .full) {
            wanted = .full
        } else if bits >= floor(twoThirdsFloor, for: .twoThirds) {
            wanted = .twoThirds
        } else {
            wanted = .half
        }
        // 缩得太小就停在还够大的那一档。
        return RemoteStreamScale.allCases.filter { $0 >= wanted }.first {
            let size = $0.size(width: width, height: height)
            return min(size.width, size.height) >= minimumShortSide
        } ?? .full
    }
}

/// 档位的升降：降档立刻（链路变窄时先保住帧率），升档要连续 `upgradeHoldNanos` 都够格、一次只升一档（换一次
/// 尺寸就要重建编码器、发一个关键帧，不能在两档之间来回切）。与声音档位同一个节奏。
nonisolated struct RemoteStreamScaleSelector: Equatable, Sendable {
    static let upgradeHoldNanos: UInt64 = 5_000_000_000

    private(set) var current: RemoteStreamScale = .full
    private var upgradeSince: UInt64?

    /// 喂一次眼下该用的档。返回 true = 档位变了（调用方按 `current` 重建编码器）。
    mutating func update(_ wanted: RemoteStreamScale, now: UInt64) -> Bool {
        if wanted < current {
            current = wanted
            upgradeSince = nil
            return true
        }
        guard wanted > current else {
            upgradeSince = nil
            return false
        }
        guard let since = upgradeSince else {
            upgradeSince = now
            return false
        }
        guard now &- since >= Self.upgradeHoldNanos,
              let next = RemoteStreamScale(rawValue: current.rawValue + 1) else { return false }
        current = next
        // 升了一档还想再升：重新计时。
        upgradeSince = next < wanted ? now : nil
        return true
    }
}
