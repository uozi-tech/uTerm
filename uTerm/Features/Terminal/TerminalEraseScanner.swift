import Foundation

/// 字节流里擦屏的动作，按对选区的影响分两档。
nonisolated enum TerminalErase: Int, Comparable, Sendable {
    /// 擦掉屏上的一部分（ED 0 / 1、EL、ECH、DCH、DL）：选中的内容可能被擦掉，也可能没碰到——由画面那一侧看选区里
    /// 是不是只剩空白再定。
    case inPlace = 0
    /// 整屏换掉：清屏（ED 2）、擦回滚（ED 3）、复位（RIS）、进出备用屏（DEC 47 / 1047 / 1049）。选区一律清掉。
    case screen = 1

    static func < (lhs: TerminalErase, rhs: TerminalErase) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 在后端输出里认出擦屏的转义序列，给「清屏后选区还留着」那件事用（`TerminalOutputPump.onSurfaceErase`）。
///
/// Ghostty 引擎自己只在复位（RIS）和切到另一个屏时清那个屏的选区；ED 2 / ED 3 不清，从备用屏切回主屏时主屏原来的
/// 选区还会冒出来（`src/terminal/Terminal.zig` 的 `eraseDisplay`、`switchScreen`）。换引擎前清屏会清选区，所以由宿主
/// 认出这些序列、让 surface 清掉。影子终端（libghostty-vt）不报这类事件，只能看字节。
///
/// 有状态：一条序列可能被切在两片之间。只认 7 位的 ESC / CSI（UTF-8 流里 0x9B 是续字节，不当 C1）；OSC / DCS /
/// APC / PM / SOS 串里的内容跳过，串以 BEL 或 ST（`ESC \`）结束。参数过长的 CSI 当作不认识。
nonisolated struct TerminalEraseScanner: Sendable {
    private enum State: Sendable {
        case ground
        case escape
        case csi
        /// OSC / DCS / APC / PM / SOS 的串体；`sawEscape`：上一个字节是 ESC（可能是 ST 的开头）。
        case string(sawEscape: Bool)
    }

    private var state = State.ground
    private var privateMarker = false
    private var params: [Int] = []
    private var current: Int?
    private var overflow = false
    private var hasIntermediate = false
    /// ESC 之后已经来过中间字节（`ESC ( B` 这类）：终止字节不是 RIS。
    private var escapeIntermediate = false

    private static let maxParams = 32

    init() {}

    /// 扫一片字节，返回这一片里最重的擦屏动作（没有就是 nil）。
    ///
    /// 在泵的热路径上（每片字节都过一遍）：平常的输出里 ESC 很稀，所以在「地面」状态下用 `memchr` 直接跳到下一个 ESC；
    /// 串体里（OSC 52 的剪贴板、Kitty 图片的 APC，可达几 MB）同样直接跳到下一个 BEL / ESC。只逐字节走转义序列。
    mutating func scan(_ bytes: Data) -> TerminalErase? {
        var found: TerminalErase?
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let count = raw.count
            let buffer = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < count {
                switch state {
                case .ground:
                    guard let hit = memchr(base + index, 0x1B, count - index) else { return }
                    index = base.distance(to: UnsafeRawPointer(hit))
                case .string(sawEscape: false):
                    // 下一个 ESC；BEL 只在它之前找。
                    let escape = memchr(base + index, 0x1B, count - index).map { base.distance(to: UnsafeRawPointer($0)) }
                    let end = escape ?? count
                    if let bell = memchr(base + index, 0x07, end - index) {
                        index = base.distance(to: UnsafeRawPointer(bell))
                    } else if let escape {
                        index = escape
                    } else {
                        return
                    }
                default:
                    break
                }
                if let erase = step(buffer[index]) { found = max(found ?? erase, erase) }
                index += 1
            }
        }
        return found
    }

    /// 一段完整字节用一个新的扫描器扫一遍（不接上一片的状态）。
    static func scanFresh(_ bytes: Data) -> TerminalErase? {
        var scanner = TerminalEraseScanner()
        return scanner.scan(bytes)
    }

    private mutating func step(_ byte: UInt8) -> TerminalErase? {
        switch state {
        case .ground:
            if byte == 0x1B { enterEscape() }
            return nil
        case .escape:
            return escape(byte)
        case .csi:
            return csi(byte)
        case .string(let sawEscape):
            if sawEscape {
                // ST 收尾；ESC 后面跟着别的，按 Ghostty 的解析器当成串被打断、开始一条新的转义序列。
                state = .ground
                if byte == 0x5C { return nil }
                enterEscape()
                return escape(byte)
            }
            if byte == 0x07 { state = .ground } else if byte == 0x1B { state = .string(sawEscape: true) }
            return nil
        }
    }

    private mutating func enterEscape() {
        state = .escape
        escapeIntermediate = false
    }

    private mutating func escape(_ byte: UInt8) -> TerminalErase? {
        if escapeIntermediate, !(0x20...0x2F).contains(byte), byte != 0x1B {
            state = .ground
            return nil
        }
        switch byte {
        case 0x5B: // [
            state = .csi
            privateMarker = false
            params.removeAll(keepingCapacity: true)
            current = nil
            overflow = false
            hasIntermediate = false
            return nil
        case 0x5D, 0x50, 0x5F, 0x5E, 0x58: // ] P _ ^ X
            state = .string(sawEscape: false)
            return nil
        case 0x63: // c：RIS
            state = .ground
            return .screen
        case 0x1B:
            enterEscape()
            return nil
        case 0x20...0x2F:
            // ESC 的中间字节（如 `ESC ( B`）：继续等终止字节。
            escapeIntermediate = true
            return nil
        default:
            state = .ground
            return nil
        }
    }

    private mutating func csi(_ byte: UInt8) -> TerminalErase? {
        switch byte {
        case 0x30...0x39:
            let digit = Int(byte - 0x30)
            let value = (current ?? 0) * 10 + digit
            current = min(value, 99_999)
            return nil
        case 0x3B, 0x3A: // ; :
            pushParam()
            return nil
        case 0x3C...0x3F: // < = > ?
            if byte == 0x3F { privateMarker = true }
            return nil
        case 0x20...0x2F:
            hasIntermediate = true
            return nil
        case 0x40...0x7E:
            pushParam()
            state = .ground
            return finalByte(byte)
        case 0x1B:
            // 序列被 ESC 打断：重新开始。
            enterEscape()
            return nil
        case 0x18, 0x1A: // CAN / SUB 取消序列
            state = .ground
            return nil
        default:
            // 夹在序列里的 C0 控制字符照常执行，序列继续。
            return nil
        }
    }

    private mutating func pushParam() {
        if params.count >= Self.maxParams {
            overflow = true
        } else {
            params.append(current ?? 0)
        }
        current = nil
    }

    private func finalByte(_ byte: UInt8) -> TerminalErase? {
        guard !overflow, !hasIntermediate else { return nil }
        switch byte {
        case 0x4A: // J：ED / DECSED
            return params.contains(where: { $0 == 2 || $0 == 3 }) ? .screen : .inPlace
        case 0x4B: // K：EL / DECSEL
            return .inPlace
        case 0x58, 0x50, 0x4D: // X ECH / P DCH / M DL
            return privateMarker ? nil : .inPlace
        case 0x68, 0x6C: // h / l：DEC 私有模式里的换屏
            guard privateMarker else { return nil }
            return params.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) ? .screen : nil
        default:
            return nil
        }
    }
}
