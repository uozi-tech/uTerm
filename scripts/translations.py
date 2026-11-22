#!/usr/bin/env python3
"""文案目录的翻译检查与合并（不依赖 Xcode）。

uTerm 的源语言是简体中文，目录 `uTerm/Localizable.xcstrings` 要带齐 TARGET_LANGS 里的每一种语言。
`make sync-strings` 只负责把代码里的键同步进目录（新键是没有翻译的空壳）；这个脚本负责翻译那一半：

  check   [--catalog …]                 每个要翻译的键都带齐目标语言、格式占位一致；有问题非零退出
  missing [--catalog …] [--out f.json]  列出缺翻译的键（JSON 数组，带源码位置，交给译者）
  merge   [--catalog …] result.json…    把译文并进目录（先校验，坏的跳过并报出来），之后跑一次
                                        `make sync-strings` 让格式回到 Xcode 的写法

译文文件格式：{"<键原文>": {"en": "…" 或 {"one": "…", "other": "…"}, "zh-Hant": "…", "ja": "…", "ko": "…"}}
（英文的复数对象只用在键里恰好一个 `%lld` 表示数量的句子。两个以上占位时译文写位置形式 `%1$@`。）

自测：bash scripts/translations.test.sh
"""
import argparse
import collections
import json
import os
import re
import sys

TARGET_LANGS = ["en", "zh-Hant", "ja", "ko"]
PLURAL_FORMS = {"zero", "one", "two", "few", "many", "other"}
SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|lf|f|u|llu|lu|s|c)")
DEFAULT_CATALOG = "uTerm/Localizable.xcstrings"
SOURCE_ROOTS = ["uTerm", "uTermMobile", "uTermFiles", "uTermSSH", "uTermRemoteHost", "uTermShellAgent", "uTermHolder"]


def specs(text):
    """格式占位的规范形：[(序号, 类型)]；混用位置与顺序写法返回 None。"""
    text = text.replace("%%", "")
    found = [(m.group(1), m.group(2)) for m in SPEC.finditer(text)]
    positional = [p for p, _ in found if p]
    if positional and len(positional) != len(found):
        return None
    if positional:
        return sorted((int(p), t) for p, t in found)
    return [(i + 1, t) for i, (_, t) in enumerate(found)]


def stray_percent(text):
    return "%" in SPEC.sub("", text.replace("%%", ""))


def needs_translation(entry):
    return entry.get("shouldTranslate") is not False and entry.get("extractionState") != "stale"


def validate(key, lang, value):
    """返回问题描述列表；空 = 合格。"""
    want = specs(key)
    if isinstance(value, dict):
        if lang != "en":
            return ["只有 en 用复数对象"]
        if set(value) - PLURAL_FORMS or "other" not in value:
            return [f"复数对象的键不对：{sorted(value)}"]
        problems = []
        for form, text in value.items():
            got = specs(text)
            if got != want and not (form == "one" and want and len(want) == 1 and got == []):
                problems.append(f"{form} 的占位 {got} ≠ 原文 {want}")
            if stray_percent(text):
                problems.append(f"{form} 里有多余的 %")
        return problems
    if not isinstance(value, str) or not value.strip():
        return ["空译文"]
    if specs(value) != want:
        return [f"占位 {specs(value)} ≠ 原文 {want}"]
    if stray_percent(value):
        return ["多余的 %（字面百分号写 %%）"]
    return []


def localization_value(loc):
    """目录里一条本地化 → 校验用的值（字符串或复数对象）。"""
    if "stringUnit" in loc:
        return loc["stringUnit"].get("value", "")
    plural = loc.get("variations", {}).get("plural")
    if plural:
        return {form: unit["stringUnit"]["value"] for form, unit in plural.items()}
    return None


def cmd_check(args):
    catalog = json.load(open(args.catalog, encoding="utf-8"))
    missing, bad = collections.Counter(), []
    for key, entry in catalog["strings"].items():
        if not needs_translation(entry):
            continue
        locs = entry.get("localizations", {})
        for lang in TARGET_LANGS:
            if lang not in locs:
                missing[lang] += 1
                continue
            value = localization_value(locs[lang])
            for problem in validate(key, lang, value) if value is not None else ["读不出译文"]:
                bad.append(f"[{lang}] {key!r}: {problem}")
    for line in bad:
        print(line)
    total = sum(missing.values())
    if total:
        print(f"缺翻译：{dict(missing)}。用 `python3 scripts/translations.py missing --out todo.json` 列出来交给译者。")
    if total or bad:
        print(f"check-translations: {total} 处缺翻译，{len(bad)} 处译文有问题", file=sys.stderr)
        return 1
    print(f"check-translations: {len(catalog['strings'])} 个键，{'、'.join(TARGET_LANGS)} 齐全")
    return 0


def unescape_literal(s):
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            if n == "(":
                depth, j = 1, i + 2
                while j < len(s) and depth:
                    depth += {"(": 1, ")": -1}.get(s[j], 0)
                    j += 1
                out.append("\x00")
                i = j
                continue
            out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def cmd_missing(args):
    catalog = json.load(open(args.catalog, encoding="utf-8"))
    keys = [k for k, e in catalog["strings"].items()
            if needs_translation(e) and any(l not in e.get("localizations", {}) for l in TARGET_LANGS)]
    literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
    index = {}
    for root in SOURCE_ROOTS:
        for dirpath, _, files in os.walk(root):
            for name in files:
                if not name.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, name)
                for no, line in enumerate(open(path, encoding="utf-8"), 1):
                    for m in literal.finditer(line):
                        index.setdefault(unescape_literal(m.group(1)), []).append(f"{path}:{no}")
    items = []
    for key in keys:
        norm = SPEC.sub("\x00", key).replace("%%", "%")
        items.append({"key": key, "comment": catalog["strings"][key].get("comment", ""),
                      "where": index.get(norm, [])[:3]})
    text = json.dumps(items, ensure_ascii=False, indent=1)
    if args.out:
        open(args.out, "w", encoding="utf-8").write(text + "\n")
        print(f"{len(items)} 个键缺翻译，已写到 {args.out}")
    else:
        print(text)
    return 0


def cmd_merge(args):
    catalog = json.load(open(args.catalog, encoding="utf-8"))
    applied, rejected = 0, 0
    for path in args.results:
        for key, translations in json.load(open(path, encoding="utf-8")).items():
            entry = catalog["strings"].get(key)
            if entry is None:
                print(f"[未知的键] {key!r}（{path}）")
                rejected += 1
                continue
            locs = entry.setdefault("localizations", {})
            for lang, value in translations.items():
                if lang not in TARGET_LANGS:
                    continue
                problems = validate(key, lang, value)
                if problems:
                    print(f"[{lang}] {key!r}: {'；'.join(problems)}")
                    rejected += 1
                    continue
                if isinstance(value, dict):
                    locs[lang] = {"variations": {"plural": {
                        form: {"stringUnit": {"state": "translated", "value": text}} for form, text in value.items()}}}
                else:
                    locs[lang] = {"stringUnit": {"state": "translated", "value": value}}
                applied += 1
    with open(args.catalog, "w", encoding="utf-8") as handle:
        json.dump(catalog, handle, ensure_ascii=False, indent=2)
    print(f"并入 {applied} 条，跳过 {rejected} 条。接着跑 `make sync-strings` 让目录回到 Xcode 的格式。")
    return 1 if rejected else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "missing", "merge"):
        p = sub.add_parser(name)
        p.add_argument("--catalog", default=DEFAULT_CATALOG)
        if name == "missing":
            p.add_argument("--out")
        if name == "merge":
            p.add_argument("results", nargs="+")
    args = parser.parse_args()
    return {"check": cmd_check, "missing": cmd_missing, "merge": cmd_merge}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
