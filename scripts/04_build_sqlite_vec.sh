#!/bin/bash
# 给 loongarch64 编译 sqlite-vec，并重打成可 pip 安装的 wheel
#
# 为什么需要：sqlite-vec 在 PyPI 上只有 x86_64/aarch64/macos/win 的 wheel，
# 没有 sdist，无法从源码 pip 安装。langgraph-checkpoint-sqlite 依赖它。
set -euo pipefail

VER="0.1.9"
WORK="${HOME}/octop-work/sv"
VENV="${VENV:-$HOME/octop-venv}"
mkdir -p "$WORK/out" "$WORK/dist"
cd "$WORK"

# 1. 取源码（直连 github.com 在本机会超时，优先用 codeload）
if [ ! -f src.tgz ]; then
  curl -sL --retry 2 -o src.tgz \
    "https://codeload.github.com/asg017/sqlite-vec/tar.gz/refs/tags/v${VER}"
fi
tar xzf src.tgz
cd "sqlite-vec-${VER}"

# 2. sqlite-vec.h 是 Makefile 生成的，仓库里只有模板，手工填出来
sed -e "s/\${VERSION}/${VER}/g" \
    -e "s/\${VERSION_MAJOR}/0/g" -e "s/\${VERSION_MINOR}/1/g" -e "s/\${VERSION_PATCH}/9/g" \
    -e "s/\${DATE}/2026-03-31T00:00:00Z/g" -e "s/\${SOURCE}/local-build/g" \
    sqlite-vec.h.tmpl > sqlite-vec.h

# 3. 编译 LoongArch 扩展
gcc -O2 -fPIC -shared -I. -o "$WORK/out/vec0.so" sqlite-vec.c -lm
file "$WORK/out/vec0.so"

# 4. 重打 wheel + 安装
cd "$WORK"
"$VENV/bin/python" "$(dirname "$0")/05_repack_sqlite_vec.py"
"$VENV/bin/pip" install --no-index --force-reinstall \
  "$WORK/dist/sqlite_vec-${VER}-py3-none-linux_loongarch64.whl"

# 5. 自测
"$VENV/bin/python" - "$(dirname "$0")" <<'EOF'
import sqlite3, struct, sys
import sqlite_vec
con = sqlite3.connect(":memory:")
con.enable_load_extension(True)
sqlite_vec.load(con)
print("vec_version:", con.execute("select vec_version()").fetchone())
con.execute("create virtual table t using vec0(a float[4])")
v = struct.pack("4f", 1.0, 2.0, 3.0, 4.0)
con.execute("insert into t(rowid, a) values (1, ?)", (v,))
con.execute("insert into t(rowid, a) values (2, ?)", (struct.pack("4f", 4, 3, 2, 1),))
print("knn:", con.execute(
    "select rowid, distance from t where a match ? order by distance limit 2", (v,)).fetchall())
EOF
echo "sqlite-vec done"
