#!/bin/bash
# 建用户级 venv，并打开 system-site-packages 复用发行版编好的原生模块
# 用法: bash 01_setup_venv.sh [venv路径]
set -euo pipefail

VENV="${1:-$HOME/octop-venv}"
PYCFG="$VENV/pyvenv.cfg"

[ -d "$VENV" ] || python3 -m venv "$VENV"

# 关键一步：让 venv 能 import 系统 /usr/lib/python3.14/site-packages 里的
# cryptography / PIL / numpy / lxml / psutil / cffi 等，省掉大量编译
if [ -f "$PYCFG" ]; then
  python3 - "$PYCFG" <<'EOF'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
flag = "include-system-site-packages"
NL = chr(10)
lines = [l for l in s.splitlines() if not l.startswith(flag)]
lines.insert(1, flag + " = true")
p.write_text(NL.join(lines) + NL)
EOF
fi

"$VENV/bin/python" - <<'EOF'
mods = ["cryptography", "PIL", "numpy", "lxml", "psutil", "cffi"]
for m in mods:
    try:
        mod = __import__(m)
        print(f"  {m:14s} ok    {mod.__file__}")
    except Exception as e:
        print(f"  {m:14s} miss  {type(e).__name__}")
EOF
echo "venv ready: $VENV"
