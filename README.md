# 在龙芯 3B6000M + AOSC OS（loongarch64）上移植安装 octop

把 PyPI 上的 [`octop`](https://pypi.org/project/octop/) 1.0.2（self-hosted AI assistant，FastAPI + Postgres 的 Web 服务）搬到我自己的龙芯机器上跑起来的完整记录。

**结论先说：能跑。** CLI 可用（`octop version` → `octop v1.0.2`，23 个子命令），全部关键模块 import 通过。唯一缺的依赖是 `playwright`（上游不支持 loongarch64，见第 7 节）。

---

## 0. 目标机器环境

```bash
$ dpkg --print-architecture
loongarch64
$ python3 -V
Python 3.14.8
$ gcc --version | head -1
gcc (GCC) 16.2.0 20260807 (AOSC OS)
$ cargo -V
cargo 1.99.1
```

其它：glibc 2.44、node v26.12.1、chromium 148。

> 这套流程的思路对所有 loongarch64 机器都适用，版本差异不大时注意第 2 节的镜像、第 4 节的系统模块复用。

## 1. 搞清楚要装的是什么

`octop` 本体是一个 18MB 的纯 Python wheel，真正的麻烦在它的 36 个核心依赖：

```bash
pip download octop==1.0.2 --no-deps -d ~/octop-work
unzip -l ~/octop-work/octop-1.0.2-py3-none-any.whl | head
```

依赖列表（boto3、langchain-core、langgraph-checkpoint-postgres、mcp、psycopg[binary]、playwright、pydantic……）写在 wheel 的 `METADATA` 里，用 `Requires-Dist:` 逐行列出。用随附脚本 `scripts/02_extract_reqs.py` 可以直接导出，避免手抄出错。

## 2. 先选镜像，别用 pypi.org

直连 `pypi.org` 在本机会不停被重置：

```
WARNING: Retrying ... after connection broken by 'ConnectionResetError(104, 连接被对方重置)'
ERROR: No matching distribution found for playwright>=1.40   # 连纯 Python 包 click 都会假失败
```

全程改用清华镜像，实测快且稳：

```bash
export MI=https://pypi.tuna.tsinghua.edu.cn/simple
pip install -i $MI --retries 5 --timeout 60 <pkg>
```

两个注意点：

- **别用 tuna 的 `/pypi/<pkg>/json` 接口查版本**，它返回陈旧数据（把 langgraph 报成 0.1.19）。查版本用 `pip index versions <pkg>`。
- Rust 系的包（orjson / tiktoken / jiter 之类）编译时需要 `RUSTC_BOOTSTRAP=1`，并且 cargo 要走镜像，`~/.cargo/config.toml` 里配：

```toml
[source.crates-io]
replace-with = "tuna"

[source.tuna]
registry = "sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/"
```

## 3. 建 venv：关键是把系统 site-packages 放进来

AOSC 已经用发行版自己的方式打包好了不少原生 Python 模块，装在 `/usr/lib/python3.14/site-packages`。**注意 apt 包名没有 `python3-` 前缀，就是模块本名**，所以 `apt-cache policy python3-cryptography` 是查不到的，得 `apt-cache search cryptography`。

本机现成可用的系统模块：

| 模块 | 版本 |
| --- | --- |
| cryptography | 50.0.1 |
| PIL (Pillow) | 12.3.0 |
| numpy | 2.5.2 |
| lxml | 6.1.0 |
| psutil | 7.2.2 |
| cffi | 2.1.0 |
| libpq | `libpq.so.5.18` + pkgconfig |

复用它们，就能绕开最恶心的那一类编译失败，比如自己编 cryptography 会挂在：

```
error: failed to run custom build command for `openssl-sys v0.9.117`
💥 maturin failed
```

（gcc/perl/pkg-config/libssl-dev 缺一样都会炸）

所以 venv 要这样建：

```bash
python3 -m venv ~/octop-venv
# 关键一步：让 venv 能看到系统 site-packages
sed -i 's/include-system-site-packages = false/include-system-site-packages = true/' ~/octop-venv/pyvenv.cfg
~/octop-venv/bin/python -c "import cryptography, PIL; print(cryptography.__version__, PIL.__version__)"
```

已经建好的 venv 事后改 `pyvenv.cfg` 也立刻生效，不用重建。见 `scripts/01_setup_venv.sh`。

## 4. 逐个安装 36 个依赖

不要一把梭 `pip install octop`：一个包炸了整个事务回滚，报错还会被放大，看不出到底是谁挂的。改成一条条装，成功失败都记账——用随附的循环脚本：

```bash
bash scripts/03_install_deps.sh
cat ~/octop-work/status.txt
```

第一轮结果：36 个里 **31 个成功**，失败 5 个：

| 依赖 | 失败原因 |
| --- | --- |
| `cryptography` | 源码编译 openssl-sys 失败 → 第 3 节的系统模块解决 |
| `acme` | 被 cryptography 连带 → 同上，自动好了 |
| `octop-harness[all]` | 根因是 sqlite-vec（第 5 节） |
| `psycopg[binary]` | psycopg-binary 没有 loongarch64 wheel → 第 6 节 |
| `playwright` | 上游没有 loongarch64 wheel，**也没有 sdist** → 第 7 节 |

## 5. 排错：别相信 pip 的最后一行 ERROR

装 `octop-harness` 时 pip 一直报：

```
langchain 1.4.7 depends on langgraph<1.3.0 and >=1.2.12
Additionally, some packages ... have no matching distributions available for your environment:
    langgraph
```

看起来是 langgraph 的问题，其实不是——单独 `pip install --dry-run langgraph` 完全装得上。真正的卡点在依赖链更深的地方。定位办法：**把失败依赖的 Requires-Dist 一层层往上看，逐个 `--dry-run` 二分**。

```bash
~/octop-venv/bin/python -c "
import zipfile
w = zipfile.ZipFile('/tmp/deps/langgraph_checkpoint_sqlite-3.1.2-py3-none-any.whl')
print(w.read([n for n in w.namelist() if n.endswith('METADATA')][0]).decode())" | grep Requires-Dist
```

真正的元凶浮出水面：

```
langgraph-checkpoint-sqlite 3.1.2
  ├── aiosqlite>=0.20
  ├── langgraph-checkpoint>=4.3.0,<5.0.0
  └── sqlite-vec>=0.1.6          # ← 只有 x86_64 / aarch64 / macos / win 的 wheel
```

## 6. 移植 sqlite-vec：自己编一个 LoongArch 扩展

`sqlite-vec` 在 PyPI 上**没有 sdist，只有平台 wheel**，`pip install --no-binary :all:` 也救不了（没有源码可编），只能手动重打包。

wheel 本身结构简单：一个 `sqlite_vec/__init__.py` + 一个 `sqlite_vec/vec0.so`。

### 6.1 编出 LoongArch 的 vec0.so

```bash
cd ~/octop-work/sv
# 源码优先走 codeload（直连 github.com 在本机会超时）
curl -sL -o src.tgz https://codeload.github.com/asg017/sqlite-vec/tar.gz/refs/tags/v0.1.9
tar xzf src.tgz && cd sqlite-vec-0.1.9

# sqlite-vec.h 是生成物，仓库里只有模板，手动 substitution
sed -e 's/${VERSION}/0.1.9/g' -e 's/${VERSION_MAJOR}/0/g' \
    -e 's/${VERSION_MINOR}/1/g' -e 's/${VERSION_PATCH}/9/g' \
    -e 's/${DATE}/2026-03-31T00:00:00Z/g' -e 's/${SOURCE}/local-build/g' \
    sqlite-vec.h.tmpl > sqlite-vec.h

gcc -O2 -fPIC -shared -I. -o ../out/vec0.so sqlite-vec.c -lm
```

验一下真的能用（不只是能编）：

```python
import sqlite3, struct
con = sqlite3.connect(":memory:"); con.enable_load_extension(True)
con.load_extension("out/vec0.so")
con.execute("select vec_version()").fetchone()          # ('v0.1.9',)
con.execute("create virtual table t using vec0(a float[4])")
con.execute("insert into t(rowid, a) values (1, ?)", (struct.pack("4f", 1,2,3,4),))
con.execute("select rowid, distance from t where a match ? order by distance limit 1",
            (struct.pack("4f", 1,2,3,4),)).fetchall()   # [(1, 0.0)]
```

### 6.2 重打成 loongarch64 wheel

套路通用，别的只有平台 wheel 的原生包也能这么搞：

1. 取一个别人的 wheel（这里是 `manylinux_2_17_x86_64`）
2. 替换里面的 `.so` 为我们编的
3. 改 `dist-info/WHEEL` 的 `Tag:` → `py3-none-linux_loongarch64`
4. 重写 `dist-info/RECORD`（每条的 sha256 和字节数）
5. `pip install --no-index` 本地装

重打包的完整逻辑见 `scripts/05_repack_sqlite_vec.py`（就是实际用过的那份），一句话跑完：

```bash
bash scripts/04_build_sqlite_vec.sh
```

> 注意点：wheel 里 `__init__.py` 的 `loadable_path()` 找的是 `vec0`（没有后缀），所以打包时 `vec0` 和 `vec0.so` 两个同名文件都放进去。

### 6.3 psycopg

`psycopg[binary]` 的 extra 装不了（psycopg-binary 没有本机 wheel），但系统已经有 `libpq.so`，装纯 Python 版就行，运行时用 ctypes 加载系统 libpq：

```bash
pip install -i $MI psycopg
```

## 7. 到此为止：octop-harness 装上了

sqlite-vec 一好，整条链就通了：

```bash
pip install -i $MI --retries 5 --timeout 60 "octop-harness>=1.0.4"
```

安装 `octop` 本体（此时已经不必再拉依赖）：

```bash
pip install --no-deps ~/octop-work/octop-1.0.2-py3-none-any.whl
```

冒烟测试，逐个 import 关键模块而不是只看 CLI 能不能起来：

```bash
~/octop-venv/bin/python scripts/06_smoke_test.py
```

全绿，然后：

```bash
$ ~/octop-venv/bin/octop version
octop v1.0.2
$ ~/octop-venv/bin/octop --help
Commands: acp, admin, agent, backup, bridge, captcha, channel, chats, clean,
completion, config, cron, init, memory, models, plugin, provider, run,
service, skills, update, user, version
```

## 8. 唯一的缺口：playwright

`playwright` 在 PyPI 上 **只有 x86_64 / aarch64 / macos / win 的 wheel，且没有 sdist**（`pip install --no-binary :all: playwright` 同样失败，因为压根没有 sdist 可编）：

```
ERROR: Could not find a version that satisfies the requirement playwright>=1.40 (from versions: none)
```

所以 `pip check` 会留一条：

```
octop 1.0.2 requires playwright, which is not installed.
```

三条处置路线：

1. **留着缺口（我现在的选择）**：浏览器类技能不可用，其它功能不受影响，最省事。
2. **源码打包 + 系统 chromium**：本机有 node v26 和 chromium 148（`apt-cache policy chromium` 可确认），可以从 GitHub 拉 playwright-python 源码自己打包，运行时用 `executable_path` 指向 `/usr/bin/chromium`。
3. **占位 stub**：造个空壳模块骗过 pip check —— **别这么做**，运行时才炸，比缺依赖更难查。

## 9. 跑起来（还没做的部分）

`octop init` 会创建 `~/.octop`、跑数据库迁移、建首个管理员账号：

```bash
~/octop-venv/bin/octop init --help
~/octop-venv/bin/octop run        # 前台跑服务
```

依赖 Postgres，本机二进制齐了（`/usr/bin/postgres`、`pg_ctl`、`psql`）但服务默认没起，跑 init 前先把库起来。

另外两个 extra 按「最小核心」原则没装，需要时再单独处理：

- `knowledge-ocr`：onnxruntime / pymupdf / rapidocr
- `local-embedding`：fastembed / huggingface-hub

## 10. 一句话总结本机经验

> 在 loongarch64 上装重型 Python 项目，第一件事不是「怎么编译它」，而是「系统上有没有现成的、能不能复用」；第二件事是「报错的那行是不是真凶」。

三条最有价值的：

1. venv 开 `include-system-site-packages`，吃掉发行版已经编好的原生模块。
2. 镜像用 tuna，pypi.org 在本机不可用。
3. 遇到依赖解析（ResolutionImpossible）死循环，用 `pip install --dry-run` 二分，真凶通常在依赖链最深处（这次是 sqlite-vec）。

---

## 附：产出物

- `~/octop-venv` —— 装好的环境（252 个包，473MB）
- `~/octop-work/` —— wheel、依赖清单、安装日志
- `~/octop-work/sv/dist/` —— 移植好的 sqlite-vec loongarch64 wheel

## 附：脚本

| 脚本 | 作用 |
| --- | --- |
| `scripts/01_setup_venv.sh` | 建 venv 并打开 system-site-packages |
| `scripts/02_extract_reqs.py` | 从 wheel 的 METADATA 导出核心依赖清单 |
| `scripts/03_install_deps.sh` | 逐条安装依赖并记账 |
| `scripts/04_build_sqlite_vec.sh` | 一键编译 + 重打包 sqlite-vec |
| `scripts/05_repack_sqlite_vec.py` | wheel 重打包脚本（换 .so + 改 tag + 重写 RECORD） |
| `scripts/06_smoke_test.py` | 关键模块 import 冒烟测试 |
