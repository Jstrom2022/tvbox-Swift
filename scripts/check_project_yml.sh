#!/bin/sh
# 检查 XcodeGen 模板中同一层级的重复键。
# YAML 解析器遇到重复键时会静默合并或覆盖（例如同名 target 写两遍），修改 project.yml 后
# 请先运行本脚本，再执行 `xcodegen generate`。
#
# 用法：scripts/check_project_yml.sh [project.yml]
set -eu

file="${1:-project.yml}"

awk_program=$(cat <<'AWK'
function reset_scopes(from_level,    key, parts) {
    for (key in seen) {
        split(key, parts, SUBSEP)
        if (parts[1] + 0 >= from_level) delete seen[key]
    }
}
{
    line = $0
    sub(/\r$/, "", line)
    if (line ~ /^[[:space:]]*(#.*)?$/) next

    match(line, /^ */)
    indent = RLENGTH
    rest = substr(line, indent + 1)

    # 列表项开启新的映射作用域
    if (rest ~ /^- /) {
        indent += 2
        rest = substr(rest, 3)
        reset_scopes(indent)
    }

    if (match(rest, /^[A-Za-z0-9_.$(){}-][^:#]*:([[:space:]]|$)/)) {
        key = substr(rest, 1, RLENGTH)
        sub(/:[[:space:]]*$/, "", key)
        reset_scopes(indent + 1)
        id = indent SUBSEP key
        if (id in seen) {
            printf "%s:%d: 重复的键 \"%s\"（同一层级首次出现在第 %d 行）\n", FILENAME, NR, key, seen[id]
            duplicated = 1
        } else {
            seen[id] = NR
        }
    }
}
END { exit duplicated ? 1 : 0 }
AWK
)

if awk "$awk_program" "$file"; then
    echo "$file: 未发现重复键"
else
    exit 1
fi
