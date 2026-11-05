#!/usr/bin/env bash
# check-cloudkit-schema.py 的自测。全部离线：用 fixture 源码树 + fixture DDL，
# 不碰真实 CloudKit 容器（脚本只在没给 --schema-file 时才会调 cktool）。
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-cloudkit-schema.py"
fail=0
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/repo/uTerm/Core/Models" "$tmp/repo/vendor/Foo"

cat > "$tmp/repo/uTerm/Core/Models/Fixtures.swift" <<'SWIFT'
import Foundation
import SwiftData

@Model
final class Widget {
    var id: UUID = UUID()
    var name: String = ""
    var count: Int = 0
    var enabled: Bool = false
    var seenAt: Date?
    var blob: Data = Data()
    var tags: [UUID] = []
    private(set) public var secret: String = ""   // 修饰符不影响持久化
    @Transient var scratch: String = ""           // 不持久化
    static let palette: [String] = []             // 不持久化
    nonisolated static let other: Int = 0          // 不持久化

    @Relationship(deleteRule: .cascade, inverse: \Gadget.owner)
    var gadgets: [Gadget]? = nil                  // to-many：没有自己的字段

    init() {}

    // 计算属性：不持久化
    var label: String { "\(name)-\(count)" }
    var kind: String {
        get { name }
        set { name = newValue }
    }
}

@Model
final class Gadget {
    var id: UUID = UUID()
    var owner: Widget?                            // to-one：镜像成一个字符串引用字段

    init() {}
}
SWIFT

# vendor/ 下的同名模型必须被忽略
cat > "$tmp/repo/vendor/Foo/Vendored.swift" <<'SWIFT'
import SwiftData
@Model
final class ShouldBeIgnored {
    var x: String = ""
    init() {}
}
SWIFT

# 注册表（ModelRegistry）与两个建容器的文件：注册表核对现在找不到它们会报错退出，
# 所以前面几条用例也要先铺好。
mkdir -p "$tmp/repo/uTerm/Core/Persistence" "$tmp/repo/uTerm/App" "$tmp/repo/uTermMobile/App"
write_registry() { # $@ = 注册的类型名
	{
		printf 'import SwiftData\n// 注释里的 Ghost.self 不算注册\nenum ModelRegistry {\n'
		printf '    nonisolated static let types: [any PersistentModel.Type] = [\n'
		for t in "$@"; do printf '        %s.self,\n' "$t"; done
		printf '    ]\n}\n'
	} > "$tmp/repo/uTerm/Core/Persistence/ModelRegistry.swift"
}
write_registry Widget Gadget
for f in uTerm/App/AppModelContainer.swift uTermMobile/App/MobileModelContainer.swift; do
	cat > "$tmp/repo/$f" <<'SWIFT'
import SwiftData
enum Container {
    static func make() -> ModelContainer {
        try! ModelContainer(for: Schema(ModelRegistry.types))
    }
}
SWIFT
done

widget_fields='        CD_blob        BYTES QUERYABLE SORTABLE,
        CD_count       INT64 QUERYABLE SORTABLE,
        CD_enabled     INT64 QUERYABLE SORTABLE,
        CD_entityName  STRING QUERYABLE SEARCHABLE SORTABLE,
        CD_id          STRING QUERYABLE SEARCHABLE SORTABLE,
        CD_name        STRING QUERYABLE SEARCHABLE SORTABLE,
        CD_secret      STRING QUERYABLE SEARCHABLE SORTABLE,
        CD_seenAt      TIMESTAMP QUERYABLE SORTABLE,
        CD_tags        BYTES QUERYABLE SORTABLE,'

make_ddl() { # $1 = 额外/删减控制：full | no-gadget | missing-field
	{
		printf 'DEFINE SCHEMA\n\n'
		printf '    RECORD TYPE CD_Widget (\n'
		if [ "$1" = "missing-field" ]; then
			printf '%s\n' "$widget_fields" | grep -v CD_seenAt
		else
			printf '%s\n' "$widget_fields"
		fi
		printf '        "___recordID"  REFERENCE,\n        GRANT READ TO "_world"\n    );\n\n'
		if [ "$1" != "no-gadget" ]; then
			printf '    RECORD TYPE CD_Gadget (\n'
			printf '        CD_entityName STRING QUERYABLE SEARCHABLE SORTABLE,\n'
			printf '        CD_id         STRING QUERYABLE SEARCHABLE SORTABLE,\n'
			printf '        CD_owner      STRING QUERYABLE SEARCHABLE SORTABLE,\n'
			printf '        "___recordID" REFERENCE,\n        GRANT READ TO "_world"\n    );\n\n'
		fi
		printf '    RECORD TYPE Users (\n        "___recordID" REFERENCE,\n        roles LIST<INT64>\n    );\n'
	} > "$2"
}

run() { python3 "$CHECK" --repo-root "$tmp/repo" --source-root uTerm --schema-file "$1" "${@:2}"; }

expect() { # $1 期望退出码, $2 说明, 其余=命令
	local want="$1" what="$2"; shift 2
	local out rc
	out="$("$@" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" = "$want" ]; then
		echo "ok: $what"
	else
		echo "FAIL: $what（退出码 $rc，期望 $want）"; echo "$out" | sed 's/^/    /'; fail=1
	fi
	LAST_OUT="$out"
}

# 1) 完整 schema -> 通过；计算属性 / static / @Transient / to-many 都不该被要求
make_ddl full "$tmp/full.ckdb"
expect 0 "完整 schema 通过" run "$tmp/full.ckdb"
case "$LAST_OUT" in
	*ShouldBeIgnored*) echo "FAIL: vendor/ 下的 @Model 没有被忽略"; fail=1 ;;
	*) echo "ok: vendor/ 被忽略" ;;
esac
case "$LAST_OUT" in
	*"多出"*) echo "FAIL: 完整 schema 不该报多余字段"; fail=1 ;;
	*) echo "ok: 无多余字段警告" ;;
esac

# 2) 少一个字段 -> 报漂移
make_ddl missing-field "$tmp/missing.ckdb"
expect 1 "缺字段被检出" run "$tmp/missing.ckdb"
case "$LAST_OUT" in
	*CD_seenAt*) echo "ok: 报出了缺失的 CD_seenAt" ;;
	*) echo "FAIL: 没点名 CD_seenAt"; fail=1 ;;
esac

# 3) 少一整个记录类型 -> 报漂移，且 --emit-schema 能把它补齐（补齐后自比对干净）
make_ddl no-gadget "$tmp/nogadget.ckdb"
expect 1 "缺记录类型被检出" run "$tmp/nogadget.ckdb"
case "$LAST_OUT" in
	*CD_Gadget*) echo "ok: 报出了缺失的 CD_Gadget" ;;
	*) echo "FAIL: 没点名 CD_Gadget"; fail=1 ;;
esac
run "$tmp/nogadget.ckdb" --emit-schema "$tmp/merged.ckdb" >/dev/null 2>&1 || true
expect 0 "emit 出来的 schema 自比对干净" run "$tmp/merged.ckdb"
case "$(cat "$tmp/merged.ckdb")" in
	*"RECORD TYPE CD_Gadget"*"CD_owner"*) echo "ok: emit 补上了 CD_Gadget/CD_owner" ;;
	*) echo "FAIL: emit 没补上 CD_Gadget"; fail=1 ;;
esac

# 4) 字段类型不符 -> 报漂移
sed 's/CD_count       INT64 QUERYABLE SORTABLE/CD_count       STRING QUERYABLE SEARCHABLE SORTABLE/' \
	"$tmp/full.ckdb" > "$tmp/wrongtype.ckdb"
expect 1 "字段类型不符被检出" run "$tmp/wrongtype.ckdb"

# 5) 映射表里没有的 Swift 类型 -> 退出码 2（配置错误，不是漂移），并指名属性
cat >> "$tmp/repo/uTerm/Core/Models/Fixtures.swift" <<'SWIFT'

@Model
final class Exotic {
    var weird: CLLocationCoordinate2D = .init()
    init() {}
}
SWIFT
expect 2 "未知类型报配置错误" run "$tmp/full.ckdb"
case "$LAST_OUT" in
	*weird*TYPE_MAP*) echo "ok: 未知类型提示指向 TYPE_MAP" ;;
	*) echo "FAIL: 未知类型提示不明确"; fail=1 ;;
esac
python3 - "$tmp/repo/uTerm/Core/Models/Fixtures.swift" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(s.split("@Model\nfinal class Exotic")[0])
PY

# 6) 模型没进注册表 -> 报漂移
write_registry Widget
expect 1 "未注册的模型被检出" run "$tmp/full.ckdb"
case "$LAST_OUT" in
	*Gadget*没有注册*|*没有注册*Gadget*) echo "ok: 报出了未注册的 Gadget" ;;
	*) echo "FAIL: 没报未注册的 Gadget"; fail=1 ;;
esac
write_registry Widget Gadget
expect 0 "补齐注册后通过" run "$tmp/full.ckdb"

# 6b) 建容器的文件不走注册表 -> 报漂移（核对的那份不是容器真正用的）
cp "$tmp/repo/uTermMobile/App/MobileModelContainer.swift" "$tmp/mobile.bak"
sed -i '' 's/Schema(ModelRegistry.types)/Schema([Widget.self])/' "$tmp/repo/uTermMobile/App/MobileModelContainer.swift"
expect 1 "容器绕开注册表被检出" run "$tmp/full.ckdb"
case "$LAST_OUT" in
	*MobileModelContainer*ModelRegistry.types*) echo "ok: 点名了 MobileModelContainer" ;;
	*) echo "FAIL: 没点名绕开注册表的容器"; fail=1 ;;
esac
cp "$tmp/mobile.bak" "$tmp/repo/uTermMobile/App/MobileModelContainer.swift"

# 6c) 建容器的文件不存在 -> 退出码 2（不再静默跳过）
mv "$tmp/repo/uTerm/App/AppModelContainer.swift" "$tmp/app.bak"
expect 2 "缺建容器文件报错" run "$tmp/full.ckdb"
mv "$tmp/app.bak" "$tmp/repo/uTerm/App/AppModelContainer.swift"

# 6d) 注册表不存在 / 解析出 0 个类型 -> 退出码 2（不再静默跳过）
mv "$tmp/repo/uTerm/Core/Persistence/ModelRegistry.swift" "$tmp/registry.bak"
expect 2 "缺注册表报错" run "$tmp/full.ckdb"
case "$LAST_OUT" in
	*ModelRegistry.swift*) echo "ok: 报错点名了注册表文件" ;;
	*) echo "FAIL: 缺注册表的报错没点名文件"; fail=1 ;;
esac
mv "$tmp/registry.bak" "$tmp/repo/uTerm/Core/Persistence/ModelRegistry.swift"
write_registry
expect 2 "空注册表报错" run "$tmp/full.ckdb"
write_registry Widget Gadget
expect 0 "恢复注册表后通过" run "$tmp/full.ckdb"

# 7) 扫描根下没有 @Model -> 退出码 2（防止「什么都没扫到」被当成通过）
mkdir -p "$tmp/repo/Empty"
expect 2 "空扫描根报错" python3 "$CHECK" --repo-root "$tmp/repo" --source-root Empty --schema-file "$tmp/full.ckdb"

[ "$fail" = 0 ] && echo "全部通过" || echo "有失败用例"
exit "$fail"
