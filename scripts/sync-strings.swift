// sync-strings：把编译器吐出的 .stringsdata 合进 .xcstrings，照 Xcode 的写法落盘。
//
// Xcode 抽文案分两步：① 编译器按 `SWIFT_EMIT_LOC_STRINGS = YES` 给每个源文件产出一份
// `.stringsdata`（文件里所有进了 LocalizedStringKey 的字面量）；② 构建结束后 IDE 把它们合进
// String Catalog。第 ② 步只有 Xcode 的界面会做，`xcodebuild` 不做，Apple 的 `xcstringstool sync`
// 又只保留带翻译的条目（会把几百个未翻译的空壳键全删掉）。这个工具就是第 ② 步的可脚本化版本：
//
//   - 代码里新出现的键 → 加成空壳 `"键" : { }`（带注释时写 `comment`）；
//   - 代码里消失、但已有翻译的键 → `extractionState = stale`（和 Xcode 一样，不丢翻译）；
//   - 代码里消失、没有翻译的键 → 删除（Xcode 的行为；`--no-prune` 改成只标 stale）；
//   - 重新出现的 stale 键 → 去掉 stale；`extractionState = manual` 的键永不动。
//
// 输出格式逐字节对齐 Xcode：2 空格缩进、` : ` 分隔、空对象写成 `{` 空行 `}`、键按
// `compare(options: .caseInsensitive, locale: en)` 排序、非 ASCII 原样、不转义 `/`、文件末尾无换行。
// `scripts/sync-strings.test.sh` 用真实目录做 round-trip 校验这一点。
//
// 用法：
//   sync-strings --catalog uTerm/Localizable.xcstrings \
//       --stringsdata-dir <mac 的 Objects-normal> --stringsdata-dir <iOS 的 Objects-normal> \
//       [--check] [--dry-run] [--no-prune]
//
// 两端的 .stringsdata 都要给：只给一端会把另一端独有的键判成「代码里没了」。
// 任一目录下找不到 .stringsdata 直接报错退出（多半是没构建或路径写错）。

import Foundation

// MARK: - 参数

struct Options {
    var catalogPath = ""
    var stringsdataDirs: [String] = []
    var check = false
    var dryRun = false
    var prune = true
}

func usage() -> Never {
    FileHandle.standardError.write("""
    usage: sync-strings --catalog <file.xcstrings> --stringsdata-dir <dir> [--stringsdata-dir <dir>…] [--check] [--dry-run] [--no-prune]

    """.data(using: .utf8)!)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("sync-strings: \(message)\n".data(using: .utf8)!)
    exit(1)
}

var options = Options()
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--catalog":
        guard !args.isEmpty else { usage() }
        options.catalogPath = args.removeFirst()
    case "--stringsdata-dir":
        guard !args.isEmpty else { usage() }
        options.stringsdataDirs.append(args.removeFirst())
    case "--check": options.check = true
    case "--dry-run": options.dryRun = true
    case "--no-prune": options.prune = false
    case "-h", "--help": usage()
    default: usage()
    }
}
guard !options.catalogPath.isEmpty, !options.stringsdataDirs.isEmpty else { usage() }

// MARK: - 读目录

let catalogURL = URL(fileURLWithPath: options.catalogPath)
guard let catalogData = FileManager.default.contents(atPath: catalogURL.path) else {
    fail("读不到 \(options.catalogPath)")
}
guard let catalogAny = try? JSONSerialization.jsonObject(with: catalogData),
      var catalog = catalogAny as? [String: Any],
      var strings = catalog["strings"] as? [String: Any] else {
    fail("\(options.catalogPath) 不是 String Catalog")
}
// `.stringsdata` 里的 table 名 = 目录文件名去掉扩展名（Localizable.xcstrings → "Localizable"）。
let tableName = catalogURL.deletingPathExtension().lastPathComponent

// MARK: - 读 .stringsdata

struct Extracted {
    var keys = Set<String>()
    /// 键 → 代码里的注释（取第一个非空的）。
    var comments: [String: String] = [:]
    var fileCount = 0
}

var extracted = Extracted()
for dir in options.stringsdataDirs {
    var filesInDir = 0
    guard let enumerator = FileManager.default.enumerator(atPath: dir) else {
        fail("打不开目录 \(dir)")
    }
    while let rel = enumerator.nextObject() as? String {
        guard rel.hasSuffix(".stringsdata") else { continue }
        filesInDir += 1
        let path = (dir as NSString).appendingPathComponent(rel)
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = object["tables"] as? [String: Any] else {
            fail("解析失败：\(path)")
        }
        guard let entries = tables[tableName] as? [[String: Any]] else { continue }
        for entry in entries {
            guard let key = entry["key"] as? String else { continue }
            extracted.keys.insert(key)
            if let comment = entry["comment"] as? String, !comment.isEmpty, extracted.comments[key] == nil {
                extracted.comments[key] = comment
            }
        }
    }
    if filesInDir == 0 {
        fail("\(dir) 下没有 .stringsdata——先构建对应的 target（SWIFT_EMIT_LOC_STRINGS 开着才会产出）")
    }
    extracted.fileCount += filesInDir
}

// MARK: - 合并

var added: [String] = []
var pruned: [String] = []
var staled: [String] = []
var revived: [String] = []
var commented: [String] = []

for key in extracted.keys where strings[key] == nil {
    var entry: [String: Any] = [:]
    if let comment = extracted.comments[key] { entry["comment"] = comment }
    strings[key] = entry
    added.append(key)
}

for (key, value) in strings {
    guard var entry = value as? [String: Any] else { continue }
    let state = entry["extractionState"] as? String
    if state == "manual" { continue }
    if extracted.keys.contains(key) {
        if state == "stale" {
            entry.removeValue(forKey: "extractionState")
            revived.append(key)
        }
        if entry["comment"] == nil, let comment = extracted.comments[key] {
            entry["comment"] = comment
            commented.append(key)
        }
        strings[key] = entry
    } else {
        let hasTranslations = (entry["localizations"] as? [String: Any]).map { !$0.isEmpty } ?? false
        if hasTranslations || !options.prune {
            if state != "stale" {
                entry["extractionState"] = "stale"
                staled.append(key)
                strings[key] = entry
            }
        } else {
            strings.removeValue(forKey: key)
            pruned.append(key)
        }
    }
}

catalog["strings"] = strings

// MARK: - 照 Xcode 的格式序列化

// 对照真实目录钉出来的排序：`compare(options: .caseInsensitive, locale: en)`（821 个键 0 处顺序不符）；
// 它判成相等的键（全角 / 半角冒号那种）再按码点排，Xcode 也是半角在前。
let sortLocale = Locale(identifier: "en")
func xcodeSorted(_ keys: [String]) -> [String] {
    keys.sorted { a, b in
        switch a.compare(b, options: .caseInsensitive, range: nil, locale: sortLocale) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return a < b
        }
    }
}

func escape(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        default:
            if scalar.value < 0x20 {
                out += String(format: "\\u%04x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}

func serialize(_ value: Any, indent: Int) -> String {
    let pad = String(repeating: " ", count: indent)
    let inner = String(repeating: " ", count: indent + 2)
    if let dict = value as? [String: Any] {
        if dict.isEmpty { return "{\n\n\(pad)}" }
        let body = xcodeSorted(Array(dict.keys)).map { key in
            "\(inner)\(escape(key)) : \(serialize(dict[key]!, indent: indent + 2))"
        }.joined(separator: ",\n")
        return "{\n\(body)\n\(pad)}"
    }
    if let array = value as? [Any] {
        if array.isEmpty { return "[\n\n\(pad)]" }
        let body = array.map { "\(inner)\(serialize($0, indent: indent + 2))" }.joined(separator: ",\n")
        return "[\n\(body)\n\(pad)]"
    }
    if let string = value as? String { return escape(string) }
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
        return number.stringValue
    }
    if value is NSNull { return "null" }
    fail("不认识的 JSON 值：\(type(of: value))")
}

let output = serialize(catalog, indent: 0)
let outputData = output.data(using: .utf8)!
let changed = outputData != catalogData

// MARK: - 汇报与写回

func report(_ label: String, _ keys: [String]) {
    guard !keys.isEmpty else { return }
    print("\(label) \(keys.count)：")
    for key in xcodeSorted(keys) { print("  \(key.replacingOccurrences(of: "\n", with: "\\n"))") }
}

print("sync-strings: \(extracted.fileCount) 份 .stringsdata，\(extracted.keys.count) 个键在代码里，目录里 \(strings.count) 个键")
report("新增", added)
report("补注释", commented)
report("恢复（不再 stale）", revived)
report("标 stale", staled)
report("删除（代码里没了且没翻译）", pruned)

if !changed {
    print("目录已是最新，无改动")
    exit(0)
}
if options.check {
    print("目录落后于代码：在 Xcode 里构建两端，或跑 make sync-strings")
    exit(1)
}
if options.dryRun {
    print("（dry-run，未写回）")
    exit(0)
}
do {
    try outputData.write(to: catalogURL, options: .atomic)
    print("已写回 \(options.catalogPath)")
} catch {
    fail("写回失败：\(error)")
}
