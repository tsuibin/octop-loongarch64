#!/bin/bash
# 逐条安装依赖并记账：一个失败不拖累后面的，跑完看 status.txt 就知道缺什么
#
# 用法: MIRROR=https://.../simple bash 03_install_deps.sh [req文件] [venv路径]
set -uo pipefail

VENV="${2:-$HOME/octop-venv}"
REQ="${1:-$HOME/octop-work/core_reqs.txt}"
MIRROR="${MIRROR:-https://pypi.tuna.tsinghua.edu.cn/simple}"   # pypi.org 在本机会被重置
LOG="${HOME}/octop-work/install.log"
ST="${HOME}/octop-work/status.txt"

: > "$ST"
: > "$LOG"

while IFS= read -r req; do
  [ -z "$req" ] && continue
  echo "########## $req" >> "$LOG"
  if timeout 1200 "$VENV/bin/pip" install --no-cache-dir -i "$MIRROR" \
        --retries 5 --timeout 60 "$req" >> "$LOG" 2>&1; then
    echo "OK   $req" | tee -a "$ST"
  else
    echo "FAIL $req" | tee -a "$ST"
  fi
done < "$REQ"

echo ALLDONE | tee -a "$ST"
echo "summary: $(grep -c '^OK' "$ST") ok / $(grep -c '^FAIL' "$ST") fail"
