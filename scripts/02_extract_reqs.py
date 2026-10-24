#!/usr/bin/env python3
"""从 wheel 的 METADATA 里导出核心依赖清单（跳过 extra）。

用法: python3 02_extract_reqs.py <wheel> [输出文件]
"""
import sys
import zipfile

NL = chr(10)


def core_requires(wheel):
    with zipfile.ZipFile(wheel) as z:
        name = [n for n in z.namelist() if n.endswith("METADATA")][0]
        md = z.read(name).decode()
    reqs = []
    for line in md.splitlines():
        if line.startswith("Requires-Dist:"):
            v = line.split(":", 1)[1].strip()
            if "extra ==" in v:      # 跳过 [all] / [dev] 之类的可选依赖
                continue
            reqs.append(v)
        if line.startswith("Requires-Python:"):
            print("Requires-Python:", line.split(":", 1)[1].strip())
    return reqs


wheel = sys.argv[1]
reqs = core_requires(wheel)
print(f"{len(reqs)} core deps")
out = sys.argv[2] if len(sys.argv) > 2 else "core_reqs.txt"
with open(out, "w") as f:
    f.write(NL.join(reqs) + NL)
print("written to", out)
