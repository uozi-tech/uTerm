#!/usr/bin/env python3
"""比对 SwiftData `@Model` 与已部署的 CloudKit schema，报告字段漂移。

背景：uTerm 的 macOS Debug 与 Release 构建共用一份 entitlements，`com.apple.developer
.icloud-container-environment` 钉死在 Production（见 uTerm/uTerm.entitlements 的注释）。
`NSPersistentCloudKitContainer` 的自动 schema 初始化**只对 Development 环境生效**，所以
本工程的任何构建都不会自动把新加的 `@Model` 属性推上 CloudKit——新字段在两个环境里都不
存在，同步静默失败。2026-08-30 发 1.10.1 时一次性发现累积漏掉 7 个字段。

本脚本把「schema 有没有跟上模型」变成一条可在发版流程里跑的硬检查：
  1. 从源码解析所有 `@Model` 类的**存储属性**，按 SwiftData→CloudKit 的映射算出期望字段；
  2. `xcrun cktool export-schema`（export 对 production 可用，import 不可用）取线上实际 schema；
  3. 逐类型逐字段比对，缺字段/类型不符就非零退出。

用法：
    scripts/check-cloudkit-schema.py                     # 比对 production（默认）
    scripts/check-cloudkit-schema.py --environment development
    scripts/check-cloudkit-schema.py --schema-file s.ckdb  # 离线比对已导出的 DDL
    scripts/check-cloudkit-schema.py --emit-schema out.ckdb  # 生成「补齐后」的 DDL

发现漂移后的修复路径（**不要**试图 import 到 production，cktool 对 production 只读）：
    scripts/check-cloudkit-schema.py --emit-schema /tmp/uTerm.ckdb
    xcrun cktool import-schema --team-id <TEAM> --container-id <CONTAINER> \\
        --environment development --file /tmp/uTerm.ckdb
    # 再去 CloudKit Console：Development → Schema → Deploy Schema Changes… → Production

需要 CloudKit Management Token：`xcrun cktool save-token --type management`（存 keychain）。
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_CONTAINER_ID = "iCloud.com.uozi.uTerm"

# 扫描根（相对仓库根）。vendor/ 下的第三方副本不参与。
DEFAULT_SOURCE_ROOTS = ["uTerm", "uTermMobile", "Packages"]

# 注册表：容器实际注册了哪些模型。两端（与测试夹具）共用 `ModelRegistry.types` 这一份，
# 它必须与源码里发现的 @Model 全集一致——漏注册的模型不会进 schema，也就不会同步。
REGISTRY_FILE = "uTerm/Core/Persistence/ModelRegistry.swift"
# 建容器的地方：必须引用 `ModelRegistry.types`，否则注册表核对核的就不是容器真正用的那份。
REGISTRY_CONSUMERS = [
    "uTerm/App/AppModelContainer.swift",
    "uTermMobile/App/MobileModelContainer.swift",
]
REGISTRY_TYPES_RE = re.compile(
    r"static\s+let\s+types\s*:\s*\[\s*any\s+PersistentModel\.Type\s*\]\s*=\s*\[(.*?)\]",
    re.DOTALL)

STRING_IDX = "STRING QUERYABLE SEARCHABLE SORTABLE"
INT_IDX = "INT64 QUERYABLE SORTABLE"
TIME_IDX = "TIMESTAMP QUERYABLE SORTABLE"
BYTES_IDX = "BYTES QUERYABLE SORTABLE"
DOUBLE_IDX = "DOUBLE QUERYABLE SORTABLE"

# Swift 类型 → CloudKit「字段类型 + 索引」。标 verified 的已对照真实已部署字段核过；
# 其余是按同类推断，第一次真正用到时请顺手核对 export 输出再把注释改掉。
TYPE_MAP = {
    "String": STRING_IDX,   # verified: CD_name / CD_host …
    "UUID": STRING_IDX,     # verified: CD_id / CD_serverID …
    "URL": STRING_IDX,      # inferred
    "Date": TIME_IDX,       # verified: CD_createdAt / CD_lastUsedAt …
    "Bool": INT_IDX,        # verified: CD_isPinned / CD_isError …
    "Int": INT_IDX,         # verified: CD_port / CD_orderIndex …
    "Int8": INT_IDX, "Int16": INT_IDX, "Int32": INT_IDX, "Int64": INT_IDX,
    "UInt": INT_IDX, "UInt8": INT_IDX, "UInt16": INT_IDX, "UInt32": INT_IDX, "UInt64": INT_IDX,
    "Data": BYTES_IDX,      # verified: CD_keyBlob
    "Double": DOUBLE_IDX,   # inferred
    "Float": DOUBLE_IDX,    # inferred
}
# 可选性不影响 CloudKit 的字段类型与索引（`Date?` 与 `Date` 都是 TIMESTAMP QUERYABLE SORTABLE）。

# 每个镜像出来的记录类型都带这个，SwiftData/Core Data 用它区分实体。
ENTITY_NAME_FIELD = ("CD_entityName", STRING_IDX)

SYSTEM_TAIL = [
    '        "___createTime" TIMESTAMP,',
    '        "___createdBy"  REFERENCE,',
    '        "___etag"       STRING,',
    '        "___modTime"    TIMESTAMP,',
    '        "___modifiedBy" REFERENCE,',
    '        "___recordID"   REFERENCE,',
    '        GRANT WRITE TO "_creator",',
    '        GRANT CREATE TO "_icloud",',
    '        GRANT READ TO "_world"',
]


class ModelError(Exception):
    pass


# ---------------------------------------------------------------- Swift 解析


def strip_comment(line: str) -> str:
    """去掉行尾 // 注释（不碰字符串字面量里的 //）。"""
    out, in_str, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_str:
            out.append(line[i:i + 2])
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str and c == "/" and line[i + 1:i + 2] == "/":
            break
        out.append(c)
        i += 1
    return "".join(out)


def brace_delta(line: str) -> int:
    """行内大括号净增量，忽略字符串字面量内的括号。"""
    depth, in_str, i = 0, False, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_str:
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str:
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
        i += 1
    return depth


MODEL_CLASS_RE = re.compile(r"^\s*(?:(?:public|internal|package|open)\s+)?final\s+class\s+(\w+)")
VAR_RE = re.compile(r"^\s*var\s+(\w+)\s*:\s*(.+)$")
ATTR_RE = re.compile(r"^\s*@\w+(\([^)]*\))?\s*")
# 访问级别 / 隔离修饰符：不影响是否持久化，先剥掉再判断。
MODIFIER_RE = re.compile(
    r"^\s*(public|private|fileprivate|internal|package|open|nonisolated|final|dynamic|weak|unowned)"
    r"(\([^)]*\))?\s+")
# 不参与持久化的声明前缀（SwiftData 只持久化实例存储 var）。
SKIP_PREFIX_RE = re.compile(r"^\s*(static|class|lazy|let|func|init|subscript|typealias|case|deinit)\b")


class ModelProperty:
    def __init__(self, name: str, swift_type: str, line_no: int, transient: bool):
        self.name = name
        self.swift_type = swift_type
        self.line_no = line_no
        self.transient = transient


class ModelClass:
    def __init__(self, name: str, path: Path, line_no: int):
        self.name = name
        self.path = path
        self.line_no = line_no
        self.properties: list[ModelProperty] = []


def parse_models(files: list[Path]) -> list[ModelClass]:
    models: list[ModelClass] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if "@Model" not in text:
            continue
        lines = text.splitlines()
        i = 0
        while i < len(lines):
            if strip_comment(lines[i]).strip() != "@Model":
                i += 1
                continue
            # 找紧随其后的 class 声明
            j = i + 1
            while j < len(lines) and not MODEL_CLASS_RE.match(strip_comment(lines[j])):
                if strip_comment(lines[j]).strip() and not strip_comment(lines[j]).lstrip().startswith("@"):
                    break
                j += 1
            m = MODEL_CLASS_RE.match(strip_comment(lines[j])) if j < len(lines) else None
            if not m:
                raise ModelError(f"{path}:{i + 1}: @Model 后面没有找到 final class 声明")
            model = ModelClass(m.group(1), path, j + 1)
            models.append(model)
            i = parse_class_body(lines, j, model, path)
        # end while
    return models


def parse_class_body(lines: list[str], decl_idx: int, model: ModelClass, path: Path) -> int:
    """解析类体，收集 depth==1 的存储属性；返回类体结束后的行号索引。"""
    depth = 0
    started = False
    pending_transient = False
    k = decl_idx
    while k < len(lines):
        raw = strip_comment(lines[k])
        if started and depth == 1:
            collect_property(raw, k, model, path, pending_transient)
            stripped = raw.strip()
            if stripped.startswith("@"):
                pending_transient = pending_transient or stripped.startswith("@Transient")
            elif stripped:
                pending_transient = False
        d = brace_delta(raw)
        if not started and d > 0:
            started = True
        depth += d
        k += 1
        if started and depth <= 0:
            break
    return k


def collect_property(raw: str, idx: int, model: ModelClass, path: Path, transient: bool) -> None:
    # 逐层剥掉行首的属性包装（@Attribute(...) var x: T）与访问/隔离修饰符，
    # 剥完之后再判断是不是「不持久化」的声明。
    line = raw
    while True:
        m = ATTR_RE.match(line)
        if m:
            transient = transient or line.lstrip().startswith("@Transient")
            line = "    " + line[m.end():]
            continue
        m = MODIFIER_RE.match(line)
        if m:
            line = "    " + line[m.end():]
            continue
        break
    if SKIP_PREFIX_RE.match(line):
        return
    m = VAR_RE.match(line)
    if not m:
        if re.match(r"^\s*var\s+\w+\s*=", line):
            raise ModelError(
                f"{path}:{idx + 1}: `{line.strip()}` 缺少显式类型标注，无法推断 CloudKit 字段类型；"
                "请补上类型标注（SwiftData 存储属性都应显式标注）。")
        return
    name, rest = m.group(1), m.group(2)
    # 计算属性：类型之后先出现 `{`（而不是 `=`）
    brace = rest.find("{")
    eq = rest.find("=")
    if brace != -1 and (eq == -1 or brace < eq):
        return
    swift_type = rest.split("=")[0].strip() if eq != -1 else rest.strip()
    swift_type = swift_type.rstrip("{").strip()
    if not swift_type:
        return
    model.properties.append(ModelProperty(name, swift_type, idx + 1, transient))


# ------------------------------------------------------ 模型 → 期望 CloudKit 字段


def expected_fields(model: ModelClass, model_names: set[str]) -> dict[str, str]:
    fields: dict[str, str] = {ENTITY_NAME_FIELD[0]: ENTITY_NAME_FIELD[1]}
    for prop in model.properties:
        if prop.transient:
            continue
        spec = cloudkit_spec(prop, model_names, model)
        if spec is None:
            continue
        fields["CD_" + prop.name] = spec
    return fields


def cloudkit_spec(prop: ModelProperty, model_names: set[str], model: ModelClass) -> str | None:
    t = prop.swift_type.strip()
    while t.endswith("?") or t.endswith("!"):
        t = t[:-1].strip()
    if t.startswith("(") and t.endswith(")"):
        t = t[1:-1].strip()
    # to-many 关系：靠子表的反向键镜像，自己没有字段
    if t.startswith("[") and t.endswith("]"):
        inner = t[1:-1].strip()
        while inner.endswith("?"):
            inner = inner[:-1].strip()
        if inner in model_names:
            return None
        # 其余数组（[UUID]、[String] …）SwiftData 按 transformable 存二进制
        return BYTES_IDX  # verified: CD_serverIDs（[UUID]）
    # to-one 关系：镜像成一个字符串引用字段
    if t in model_names:
        return STRING_IDX  # verified: CD_session
    if t in TYPE_MAP:
        return TYPE_MAP[t]
    raise ModelError(
        f"{model.path}:{prop.line_no}: 属性 `{prop.name}: {prop.swift_type}` 的类型不在映射表里。\n"
        f"    请先用 `xcrun cktool export-schema` 看这个字段在 CloudKit 里的真实类型/索引，"
        f"再把 {t} 加进 {Path(__file__).name} 的 TYPE_MAP。")


# ---------------------------------------------------------------- DDL 解析


FIELD_RE = re.compile(r"^\s*(CD_\w+)\s+(.+?),?\s*$")
RECORD_RE = re.compile(r"^\s*RECORD TYPE\s+(\S+)\s*\(")


def parse_ddl(text: str) -> dict[str, dict[str, str]]:
    schema: dict[str, dict[str, str]] = {}
    current: str | None = None
    for line in text.splitlines():
        m = RECORD_RE.match(line)
        if m:
            current = m.group(1)
            schema[current] = {}
            continue
        if current is None:
            continue
        if line.strip().startswith(");"):
            current = None
            continue
        fm = FIELD_RE.match(line)
        if fm:
            schema[current][fm.group(1)] = " ".join(fm.group(2).split()).rstrip(",")
    return schema


def export_schema(team_id: str, container_id: str, environment: str) -> str:
    if not team_id:
        raise ModelError("要导出线上 schema 得知道容器所属团队：传 --team-id <TEAM> 或设 TEAM_ID")
    cmd = ["xcrun", "cktool", "export-schema", "--team-id", team_id,
           "--container-id", container_id, "--environment", environment]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError as exc:  # pragma: no cover - 没有 Xcode 工具链
        raise ModelError(f"无法执行 xcrun cktool：{exc}")
    if proc.returncode != 0 or "RECORD TYPE" not in proc.stdout:
        raise ModelError(
            "cktool export-schema 失败：\n"
            + (proc.stderr.strip() or proc.stdout.strip() or f"exit={proc.returncode}")
            + "\n提示：需要 CloudKit Management Token —— 先跑 `xcrun cktool save-token --type management`。")
    return proc.stdout


# ---------------------------------------------------------------- 注册表核对


def parse_registrations(repo_root: Path) -> set[str]:
    """解析 `ModelRegistry.types` 的字面量，返回注册的模型名。

    找不到文件 / 找不到数组 / 解析出 0 个类型都抛 ModelError（退出码 2）——**不**静默跳过：
    跳过就等于注册表核对整个失效，漏注册的模型照样能「通过」。
    """
    path = repo_root / REGISTRY_FILE
    if not path.exists():
        raise ModelError(f"找不到注册表 {REGISTRY_FILE}——挪了位置就同步改脚本里的 REGISTRY_FILE")
    text = strip_line_comments(path.read_text(encoding="utf-8", errors="replace"))
    m = REGISTRY_TYPES_RE.search(text)
    if not m:
        raise ModelError(f"{REGISTRY_FILE} 里没找到 `static let types: [any PersistentModel.Type] = [...]`")
    names = set(re.findall(r"(\w+)\.self", m.group(1)))
    if not names:
        raise ModelError(f"{REGISTRY_FILE} 的 types 里一个模型都没解析出来")
    return names


def check_registry_consumers(repo_root: Path) -> list[str]:
    """建容器的文件必须引用 `ModelRegistry.types`；文件不存在同样报错（不静默跳过）。"""
    problems: list[str] = []
    for rel in REGISTRY_CONSUMERS:
        path = repo_root / rel
        if not path.exists():
            raise ModelError(f"找不到建容器的文件 {rel}——挪了位置就同步改脚本里的 REGISTRY_CONSUMERS")
        text = strip_line_comments(path.read_text(encoding="utf-8", errors="replace"))
        if "ModelRegistry.types" not in text:
            problems.append(f"{rel} 没有用 ModelRegistry.types 建容器（注册表核对核不到它真正注册的模型）")
    return problems


def strip_line_comments(text: str) -> str:
    return re.sub(r"//[^\n]*", "", text)


# ---------------------------------------------------------------- emit


def emit_schema(base_ddl: str, missing: dict[str, dict[str, str]], new_types: dict[str, dict[str, str]]) -> str:
    lines = base_ddl.splitlines()
    out: list[str] = []
    for line in lines:
        out.append(line)
        m = RECORD_RE.match(line)
        if m and m.group(1) in missing:
            for name, spec in sorted(missing[m.group(1)].items()):
                out.append(f"        {name} {spec},")
    text = "\n".join(out)
    blocks = []
    for rtype, fields in sorted(new_types.items()):
        body = [f"    RECORD TYPE {rtype} ("]
        for name, spec in sorted(fields.items()):
            body.append(f"        {name} {spec},")
        body.extend(SYSTEM_TAIL)
        body.append("    );")
        blocks.append("\n".join(body))
    if blocks:
        marker = "DEFINE SCHEMA\n"
        idx = text.find(marker)
        insert_at = idx + len(marker) if idx != -1 else 0
        text = text[:insert_at] + "\n" + "\n\n".join(blocks) + "\n" + text[insert_at:]
    if not text.endswith("\n"):
        text += "\n"
    return text


# ---------------------------------------------------------------- main


def swift_files(repo_root: Path, roots: list[str]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        base = repo_root / root
        if not base.exists():
            continue
        for path in sorted(base.rglob("*.swift")):
            if "vendor" in path.parts or ".build" in path.parts:
                continue
            files.append(path)
    return files


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="比对 SwiftData @Model 与已部署的 CloudKit schema")
    # 容器所属团队；维护者的值来自 internal/config.mk（make check-cloudkit-schema 传进来），别处用 --team-id / TEAM_ID。
    parser.add_argument("--team-id", default=os.environ.get("TEAM_ID", ""))
    parser.add_argument("--container-id", default=os.environ.get("CLOUDKIT_CONTAINER_ID", DEFAULT_CONTAINER_ID))
    parser.add_argument("--environment", default="production", choices=["production", "development"])
    parser.add_argument("--schema-file", help="离线：直接读一份已导出的 DDL，不调用 cktool")
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parent.parent))
    parser.add_argument("--source-root", action="append", dest="source_roots", default=None,
                        help=f"扫描根，可重复（默认 {' '.join(DEFAULT_SOURCE_ROOTS)}）")
    parser.add_argument("--emit-schema", metavar="PATH",
                        help="把「补齐缺失字段后」的 DDL 写到 PATH（- 为 stdout），供 cktool import-schema 用")
    parser.add_argument("--skip-registration-check", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()
    roots = args.source_roots or DEFAULT_SOURCE_ROOTS

    try:
        models = parse_models(swift_files(repo_root, roots))
        model_names = {m.name for m in models}
        if not models:
            raise ModelError(f"在 {roots} 下没有找到任何 @Model 类——扫描根是不是配错了？")
        expected = {f"CD_{m.name}": expected_fields(m, model_names) for m in models}
        registered = None if args.skip_registration_check else parse_registrations(repo_root)
        consumer_problems = [] if args.skip_registration_check else check_registry_consumers(repo_root)
        base_ddl = (Path(args.schema_file).read_text(encoding="utf-8") if args.schema_file
                    else export_schema(args.team_id, args.container_id, args.environment))
    except ModelError as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2
    actual = parse_ddl(base_ddl)

    problems: list[str] = []
    warnings: list[str] = []

    # 1) 注册表核对
    if registered is not None:
        unregistered = sorted(model_names - registered)
        if unregistered:
            problems.append(f"{REGISTRY_FILE} 没有注册这些 @Model：{', '.join(unregistered)}"
                            "（未注册的模型不进 schema，也就不会同步）")
        problems.extend(consumer_problems)

    # 2) 字段比对
    missing_fields: dict[str, dict[str, str]] = {}
    new_types: dict[str, dict[str, str]] = {}
    for rtype in sorted(expected):
        want = expected[rtype]
        have = actual.get(rtype)
        if have is None:
            new_types[rtype] = want
            problems.append(f"{rtype}：整个记录类型在 {args.environment} 里不存在（{len(want)} 个字段）")
            continue
        miss = {n: s for n, s in want.items() if n not in have}
        if miss:
            missing_fields[rtype] = miss
            for name, spec in sorted(miss.items()):
                problems.append(f"{rtype}.{name} 缺失（期望 {spec}）")
        for name, spec in sorted(want.items()):
            if name in have and have[name] != spec:
                problems.append(f"{rtype}.{name} 类型/索引不符：线上 {have[name]}，模型期望 {spec}")
        extra = sorted(n for n in have if n not in want)
        if extra:
            warnings.append(f"{rtype}：线上多出 {', '.join(extra)}"
                            "（属性被删/改名后的遗留字段，CloudKit 不能删，通常无害）")
    for rtype in sorted(actual):
        if rtype.startswith("CD_") and rtype not in expected:
            warnings.append(f"{rtype}：线上有、模型里没有（被删掉的模型？）")

    # 3) 报告
    print(f"模型：{len(models)} 个 @Model（{', '.join(sorted(model_names))}）")
    print(f"schema 来源：{args.schema_file or f'cktool export-schema --environment {args.environment}'}")
    for w in warnings:
        print(f"警告：{w}")

    if args.emit_schema:
        merged = emit_schema(base_ddl, missing_fields, new_types)
        if args.emit_schema == "-":
            sys.stdout.write(merged)
        else:
            Path(args.emit_schema).write_text(merged, encoding="utf-8")
            print(f"已写出补齐后的 schema：{args.emit_schema}")

    if problems:
        sys.stdout.flush()  # 让 stdout 的概览排在 stderr 的漂移清单之前
        print(f"\n发现 {len(problems)} 处 schema 漂移：", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        print(
            "\n修复（cktool 对 production 只读，只能先补 development 再去 Console 部署）：\n"
            f"  scripts/{Path(__file__).name} --emit-schema /tmp/uTerm.ckdb\n"
            f"  xcrun cktool import-schema --team-id {args.team_id} --container-id {args.container_id} \\\n"
            "      --environment development --file /tmp/uTerm.ckdb\n"
            "  # 然后 CloudKit Console → Development → Schema → Deploy Schema Changes… → Production\n"
            f"  scripts/{Path(__file__).name}   # 部署后重跑，必须干净",
            file=sys.stderr)
        return 1

    print(f"\nOK：{args.environment} schema 与全部 @Model 一致。")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
