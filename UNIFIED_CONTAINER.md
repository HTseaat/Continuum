# 单镜像单容器方案（continuum + AD-MPC）

这个方案不会改动你两个工程原代码，只是新增一个统一镜像构建入口：

- `Dockerfile.unified`
- `unified/*.sh` 运行脚本

## 1. 构建镜像

在目录 `/Users/yujianbin/Downloads/CCS_26_codes` 执行：

```bash
./unified/build_unified_image.sh
```

可以用这个命令：DOCKER_BUILDKIT=1 ./unified/build_unified_image.sh

如果要清除缓存重新build，可以用这个：DOCKER_BUILDKIT=1 docker build --no-cache -f Dockerfile.unified -t mpc-unified:latest .

这条命令会使用已验证参数构建：

- `APT_MIRROR=http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports`
- `GO_MIRROR=https://mirrors.aliyun.com/golang`
- `GO_VERSION=1.20.14`
- 默认 `--no-cache`，减少旧缓存导致的构建干扰

## 2. 启动一个容器

```bash
./unified/run_unified_container.sh
```

这条命令会自动把本地目录挂载到容器里（改动实时同步到本地）：

- `./dumbo-mpc` -> `/opt/dumbo-mpc`
- `./admpc` -> `/opt/admpc`
- `./unified` -> `/opt/unified`
- `./papers` -> `/opt/papers`（如果本地存在该目录）

可选参数：

```bash
./unified/run_unified_container.sh <image_tag> <container_name>
```

例如：

```bash
./unified/run_unified_container.sh mpc-unified:latest mpc-bench
```

容器内会有两个独立 Python 环境：

- continuum: `/opt/venv/continuum`
- AD-MPC: `/opt/venv/admpc`

两个工程目录分别是：

- continuum: `/opt/dumbo-mpc`
- AD-MPC: `/opt/admpc`

## 3. 在同一个容器里分别跑实验

### 3.1 只跑 AD-MPC

```bash
run-admpc-local admpc 4 1 8 300
```

每层全线性门：

```bash
run-admpc-local admpc-linear 4 1 8 300
```

每层全乘法门：

```bash
run-admpc-local admpc-nonlinear 4 1 8 300
```

说明：挂载本地 `AD-MPC` 目录时，若当前 Python 版本对应的本地扩展缺失，
`run-admpc-local` 会先自动执行一次 `python setup.py build_ext --inplace` 再运行。

### 3.2 只跑 continuum（ad-mpc2）

脚本会先做 keygen，再跑 `run_local_network_test.sh ad-mpc2*`：

```bash
run-continuum-local 4 1 8 300
```

每层全线性门：

```bash
run-continuum-local 4 1 8 300 linear
```

每层全乘法门：

```bash
run-continuum-local 4 1 8 300 nonlinear
```

参数含义：`n t layers total_cm [mixed|linear|nonlinear]`

### 3.3 只跑 continuum 的 Dumbo-MPC 三元组（仅 AsyRanTriGen 路径）

如果你的目标是只测试 AsyRanTriGen（不经过 OptRanTriGen 的 dualmode），在容器内执行：

```bash
enter-continuum
cd /opt/dumbo-mpc
./run_local_network_test.sh asy-triple 4 300 full 10
```

也可以用新增的便捷脚本（顶层）：

```bash
# 方式 A：命令形式（重建统一镜像后可用）
run-dumbo-mpc-local 4 1 300 full 10

# 方式 B：当前容器内直接调用顶层脚本
/opt/run-dumbo-mpc-local.sh 4 1 300 full 10
```

参数含义：

- `n t k [mode] [layers]`
- `n`：委员会规模（节点数）
- `t`：容错阈值（`run-dumbo-mpc-local` 会先用它做 keygen）
- `k`：`batch size`，在 `asy-triple` 路径中等价于总乘法门预算（代码里 `total_cm = k`）
- `layers`：计算层数（默认 `10`）
- `mode` 支持：
  - `full`：完整跑完电路（默认）
  - `drop-epoch4`：模拟第 4 层（epoch）两名诚实节点下线，预期会卡住

`layers` 口径说明（避免歧义）：

- 这里的 `layers` 是 `for L in range(layers)` 的“计算层数”。
- 输入生成（ACSS+ACS）在循环前单独执行，不计入 `layers`。
- 最后输出重构（final opening）在循环后单独执行，也不计入 `layers`。
- 每层分配的乘法门数：`cm = k // layers`（整除向下取整）。
- 因此建议让 `k` 能被 `layers` 整除；否则会按整除截断（例如 `k=301, layers=10` 时每层仍是 `30`，剩余预算不会均匀分层使用）。
- 运行时还要求 `k >= layers`，否则会报错。

示例（你常用这条）：

- `./run_local_network_test.sh asy-triple 4 300 full 10`
- 计算得到 `cm = 300 // 10 = 30`
- 即每层 `30` 个乘法门，共 `10` 层，总计 `300` 个乘法门（每层还会做 `30` 个加法）。

说明：

- 这条命令会走 `run_beaver_triple.py`，并根据 `mode` 选择：
  - `full` -> `beaver/dumbo_mpc_dyn.py`
  - `drop-epoch4` -> `beaver/dumbo_mpc_dyn_dropout.py`
- 不会走 `./run_local_network_test.sh dumbo-mpc ...` 那条 dualmode（OptRanTriGen -> AsyRanTriGen）路径。

输出位置：

- 主日志：`/opt/dumbo-mpc/dumbo-mpc/AsyRanTriGen/log/logs-<id>.log`（例如 `logs-0.log` 到 `logs-3.log`）

## 3.4 分布式实验编排（新增）

新增目录：`/opt/unified/distributed`

- `cluster.env.example`：集群配置模板
- `sync_cluster_config.sh`：一次同步 `admpc/continuum/remote` 的 `config.sh` 与 `ip.txt`
- `run_suite.sh`：统一入口（按协议串行）
- `run_admpc_dist.sh` / `run_continuum_dist.sh` / `run_dumbo_dist.sh`：协议快捷入口

先配置集群信息：

```bash
cd /opt/unified/distributed
cp cluster.env.example cluster.env
# 编辑 cluster.env，填 NODE_SSH_USERNAME 和 CLUSTER_IPS
```

按协议运行（符合“先跑完一个协议再跑另一个”的策略）：

```bash
# AD-MPC
./run_admpc_dist.sh exp1

# continuum
./run_continuum_dist.sh exp2

# dumbo (只支持 exp3/exp4)
./run_dumbo_dist.sh exp4 --dumbo-timeout 900
```

或者用统一入口：

```bash
./run_suite.sh <admpc|continuum|dumbo> <exp1|exp2|exp3|exp4>
```

常用参数：

```bash
--sleep-between-case <seconds>   # case 之间停顿，默认 30（设 0 可关闭）
--sync-code                      # 每个 case 前额外分发代码
--timeout <seconds>              # admpc/continuum control-node 超时
--dumbo-timeout <seconds>        # dumbo 启动超时
```

说明：
- 实验参数已内置：`(n,t)={(4,1),(8,2),(12,3),(16,5)}`，以及 `exp4` 的 dumbo `drop-epoch4`。
- 如果远端仓库放在 `~/Continuum/admpc`、`~/Continuum/dumbo-mpc` 这类父目录下，可在 `cluster.env` 里设置 `REMOTE_WORKSPACE_DIR="Continuum"`。
- 每个 case 会先同步对应 `N` 的 `config.sh/ip.txt`，并自动执行 `setup_ssh_keys.sh <N>`（同一轮里同一个 `N` 只做一次）。
- 每个 case 都是“单独生成配置 + 单独分发 + 单独归档”，不会覆盖前一个 case 的结果。
- 默认每个变量 case 跑完会等待 30 秒，方便你停下来记录数据（可用 `--sleep-between-case` 调整）。
- 当前版本先归档原始日志与元信息，指标提取留空（后续补）。

## 4. 一键顺序对比（同参数）

```bash
run-compare-local 4 1 8 300 admpc
```

输出会保存到：

- `/opt/benchmark-compare/<timestamp>_n4_t1_l8_cm300/`

说明：

- AD-MPC 会输出 `logs/` 和 `extracted_times.csv/summary_times.csv`（若生成）。
- continuum 会保存 `AsyRanTriGen/log/` 日志。
- continuum 的 `extract_trusted_time.py` 默认把 `COMMITTEE_SIZE` 写死为 4；如果你改了 `n`，请先改脚本中的该值再提取 CSV。

## 5. 手动进入某个工程环境（可选）

```bash
enter-admpc
enter-continuum
```

## 6. 关于“互不污染”

这个方案已经做了主要隔离：

- 两套源码目录隔离
- 两个 venv 隔离
- 运行入口和日志目录隔离

仍然共享的是系统层库（如 `/usr/lib`），这是 Docker 单镜像方案下的正常共享。

## 7. 在容器内安装与配置 cc-switch + Codex（CLI）

> 下面命令默认在容器内执行（通常是 `root` 用户）。如果你不是 `root`，把 `mv` 等命令改成 `sudo mv`。

### 7.1 安装 cc-switch CLI

推荐使用官方安装脚本（Linux/macOS）：

```bash
curl -fsSL https://github.com/SaladDay/cc-switch-cli/releases/latest/download/install.sh | bash
export PATH="$HOME/.local/bin:$PATH"
cc-switch --version
```

如果你希望手动安装（Linux）：

```bash
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) PKG="cc-switch-cli-linux-x64-musl.tar.gz" ;;
  aarch64|arm64) PKG="cc-switch-cli-linux-arm64-musl.tar.gz" ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

curl -LO "https://github.com/SaladDay/cc-switch-cli/releases/latest/download/${PKG}"
tar -xzf "${PKG}"
chmod +x cc-switch
mv cc-switch /usr/local/bin/
cc-switch --version
```

### 7.2 安装 Codex CLI

当前统一镜像默认没有 Node.js/npm。先安装 Node.js（20.x），再安装 Codex：

```bash
apt-get update
apt-get install -y curl ca-certificates gnupg
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

node -v
npm -v

npm install -g @openai/codex
codex --version
```

### 7.3 配置 Codex 登录

二选一：

```bash
# 方式 A：浏览器登录（推荐）
codex --login

# 方式 B：使用 API Key
export OPENAI_API_KEY="<YOUR_OPENAI_API_KEY>"
```

### 7.4 用 cc-switch 配置 codex provider（避免默认 Claude）

`cc-switch` 默认应用是 `claude`。要配置 Codex，一定加 `--app codex`：

```bash
# 检查本地工具是否都已安装（可选）
cc-switch env tools

# 为 Codex 添加 provider（交互式）
cc-switch --app codex provider add

# 查看 / 切换当前 Codex provider
cc-switch --app codex provider list
cc-switch --app codex provider switch <id>
cc-switch --app codex provider current
```

如果你不加 `--app codex`，`provider add` 会落到默认的 Claude 配置里。

另外，首次建议先运行一次 `codex`（或 `codex --help`）初始化 `~/.codex/`，这样 `cc-switch` 同步实时配置时更稳定。

## 8. 容器内 Push 与服务器 Pull（傻瓜流程）

下面这套流程适用于当前目录结构（你在 `/opt` 开发，仓库在 GitHub）。

### 8.1 容器内 Push（把 `/opt` 改动同步到 GitHub）

每次 push 都执行下面这一段（已包含“首次自动 clone”）：

```bash
set -euo pipefail
SRC=/opt
SYNC=/root/continuum-sync
REPO=https://github.com/HTseaat/Continuum.git

# 如果目录不存在或不是 git 仓库，则自动初始化
if [ ! -d "$SYNC/.git" ]; then
  git clone "$REPO" "$SYNC"
fi

cd "$SYNC"
git fetch origin
git checkout main || git checkout -b main origin/main
git pull --ff-only origin main

# 清空同步目录中的工作区（保留 .git）
find "$SYNC" -mindepth 1 -maxdepth 1 ! -name '.git' -exec rm -rf {} +

# 从 /opt 拷贝代码（排除缓存/构建/日志/嵌套 git 元数据）
tar -C "$SRC" \
  --exclude='.git' \
  --exclude='*/.git' \
  --exclude='venv' \
  --exclude='__pycache__' \
  --exclude='*.pyc' \
  --exclude='build' \
  --exclude='*.egg-info' \
  --exclude='logs' \
  --exclude='*.log' \
  --exclude='.DS_Store' \
  -cf - . | tar -C "$SYNC" -xf -

cd "$SYNC"
git add -A
git commit -m "update from container: $(date +%F_%T)" || echo "No changes to commit."
git push origin main
```

说明：

- `SYNC` 建议放在 `/root`（不要放 `/tmp`，容器重启后可能被清空）。
- 如果仓库是私有仓库，`git push` 会让你输入 GitHub 用户名和 PAT（不是登录密码）。
- 如果网络不稳定导致 `RPC failed`，可先执行：

```bash
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
```

### 8.2 服务器 Pull（拉取你刚 push 的最新代码）

首次执行：

```bash
set -e
mkdir -p ~/work
cd ~/work
git clone https://github.com/HTseaat/Continuum.git
cd Continuum
git checkout main
```

以后每次更新：

```bash
cd ~/Continuum
git pull --ff-only origin main
git log -1 --oneline
```
