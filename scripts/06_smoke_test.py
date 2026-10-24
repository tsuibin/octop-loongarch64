#!/usr/bin/env python3
"""关键模块 import 冒烟测试。

比只跑一句 --help 更靠谱：很多 ImportError 是懒加载，等用到才炸。
"""
import importlib
import sys

MODS = [
    "octop", "octop.cli.main", "octop.config", "octop.launch",
    "octop.api.app", "octop.api.deps", "octop.api.openapi_meta",
    "octop_memory", "octop_gateway", "octop_browser", "octop_harness",
    "psycopg", "pydantic", "fastapi", "uvicorn",
    "langgraph", "langchain_core", "sqlite_vec",
]

bad = []
for m in MODS:
    try:
        importlib.import_module(m)
        print("OK  ", m)
    except Exception as e:
        print("FAIL", m, "->", type(e).__name__ + ":", str(e).splitlines()[0][:110])
        bad.append(m)

print()
print("failed:", len(bad), bad if bad else "none")
sys.exit(1 if bad else 0)
