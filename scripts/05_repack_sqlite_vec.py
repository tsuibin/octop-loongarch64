#!/usr/bin/env python3
"""把别人架构的 wheel 换成我们编好的 .so，重打成 loongarch64 wheel。

套路对任何「只有平台 wheel、没有 sdist」的原生包都适用：
  换 .so -> 改 dist-info/WHEEL 的 Tag -> 重写 dist-info/RECORD -> pip install --no-index
"""
import base64
import hashlib
import os
import shutil
import zipfile

NL = chr(10)
VER = "0.1.9"
WORK = os.path.expanduser("~/octop-work/sv")
SRC = f"{WORK}/sqlite_vec-{VER}-py3-none-manylinux_2_17_x86_64.manylinux2014_x86_64.manylinux1_x86_64.whl"
SO = f"{WORK}/out/vec0.so"
UNPACK = f"{WORK}/repack"
OUT = f"{WORK}/dist/sqlite_vec-{VER}-py3-none-linux_loongarch64.whl"

if not os.path.exists(SRC):
    raise SystemExit(f"先下载原 wheel 到 {SRC}")

shutil.rmtree(UNPACK, ignore_errors=True)
os.makedirs(UNPACK, exist_ok=True)
zipfile.ZipFile(SRC).extractall(UNPACK)

blob = open(SO, "rb").read()
# __init__.py 里 loadable_path() 找的是 "vec0"（无后缀），两个名字都放
for name in ("sqlite_vec/vec0.so", "sqlite_vec/vec0"):
    open(os.path.join(UNPACK, name), "wb").write(blob)

wfile = os.path.join(UNPACK, f"sqlite_vec-{VER}.dist-info/WHEEL")
new = []
for line in open(wfile).read().splitlines():
    if line.startswith("Tag:"):
        line = "Tag: py3-none-linux_loongarch64"
    new.append(line)
open(wfile, "w").write(NL.join(new) + NL)

record = os.path.join(UNPACK, f"sqlite_vec-{VER}.dist-info/RECORD")
rows = []
for root, _, files in os.walk(UNPACK):
    for fn in files:
        full = os.path.join(root, fn)
        rel = os.path.relpath(full, UNPACK)
        if rel.endswith(".dist-info/RECORD"):
            rows.append(rel + ",,")
            continue
        data = open(full, "rb").read()
        h = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")
        rows.append(f"{rel},sha256={h},{len(data)}")
open(record, "w").write(NL.join(sorted(rows)) + NL)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(UNPACK):
        for fn in sorted(files):
            full = os.path.join(root, fn)
            z.write(full, os.path.relpath(full, UNPACK))
print("built:", OUT, os.path.getsize(OUT), "bytes")
