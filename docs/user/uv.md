# Python 环境管理

!!! danger "不要在系统 Python 里装包"
    集群的系统 Python 属于操作系统。往里 `pip install` 可能破坏系统工具，
    多个用户之间也会互相覆盖依赖版本。

    **每个项目用自己独立的虚拟环境。**

## 为什么用 uv

[uv](https://docs.astral.sh/uv/) 是用 Rust 写的 Python 包与项目管理器，
可以替代 `pip`、`virtualenv`、`conda` 的日常用途。

| 能力 | uv | conda |
|---|---|---|
| 装包速度 | 快一个数量级（有全局缓存，同版本包只下载一次） | 慢 |
| 管理 Python 版本 | ✅ `uv python install 3.12` | ✅ |
| 依赖锁定 | ✅ `uv.lock`，跨机器可复现 | 需手工导出 `environment.yml` |
| 装 CUDA 运行时 | 由 PyTorch wheel 自带 | conda 单独装 `pytorch-cuda` |
| 装非 Python 依赖（`ffmpeg`、`openmpi` 等） | ❌ 用系统包或镜像 | ✅ |

!!! tip "选 uv 的场景"
    PyTorch 的官方 wheel 已经把 CUDA 运行时打包在里面了，
    所以「用 conda 管理 CUDA 版本」这个最主要的理由在深度学习场景下并不成立。
    uv 更快、锁定更可靠，是当前推荐方案。

    确实需要 conda 管非 Python 依赖时，自己装 Miniconda 也可以，两者不冲突。

## 安装 uv

```bash
# 官方安装脚本，装到 ~/.local/bin
curl -LsSf https://astral.sh/uv/install.sh | sh

# 让当前 shell 生效
source ~/.local/bin/env
```

确认：

```bash
uv --version
```

!!! note "服务器不能直连外网时"
    `astral.sh` 可能访问不了。两个替代方案：

    ```bash
    # 方案一：用 pip 从镜像装（走 PyPI）
    pip install -i https://pypi.tuna.tsinghua.edu.cn/simple uv

    # 方案二：在能上网的机器下载 uv 二进制，上传到 ~/.local/bin/
    ```

    uv 本体是单个静态二进制，拷贝过去加执行权限即可用。

!!! warning "装在家目录之外的地方"
    服务器上的 `~/.local/bin` 通常已经在 `PATH` 里。
    如果装到别处（例如数据盘），把该路径加进 `~/.bashrc`：

    ```bash
    echo 'export PATH=/data/$USER/bin:$PATH' >> ~/.bashrc
    ```

## 管理 Python 版本

uv 可以自己下载和管理 Python，不依赖系统的 Python 版本。

```bash
uv python install 3.12        # 下载并安装
uv python list                # 查看已装和可用的版本
uv python find                # 查看当前生效的解释器路径
```

!!! tip "用哪个 Python 版本"
    选 PyTorch 官方 wheel 覆盖到的版本。当前 `3.11` 与 `3.12` 都比较稳，
    **不要用太新的版本**（例如刚发布的 3.14），PyTorch 和部分科学计算包的
    wheel 往往还没跟上，会被迫从源码编译。

## 创建虚拟环境

```bash
cd ~/myproject

# 创建 .venv，让 uv 自己准备 Python 3.12
uv venv --python 3.12
```

激活（与传统 venv 完全一样）：

```bash
source .venv/bin/activate
```

!!! note "也可以不激活"
    `uv run` 会自动使用当前目录的 `.venv`，不需要先激活：

    ```bash
    uv run python train.py
    ```

    交互式调试时激活更方便，脚本里用 `uv run` 更省事。

## 安装 PyTorch

!!! danger "先确认驱动支持的 CUDA 版本"
    当前集群驱动是 `550.144.03`，对应 **CUDA 12.4**。
    PyTorch wheel 自带 CUDA 运行时，选 **不高于** 驱动支持版本的 wheel：

    ```bash
    nvidia-smi        # 右上角看 "CUDA Version"
    ```

    选 `cu124` 或更低的 `cu121` 都可以。装了比驱动更新的 CUDA 版本会报
    `CUDA driver version is insufficient`。

### 临时安装（快速试用）

```bash
uv venv --python 3.12
source .venv/bin/activate

uv pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu124
```

!!! warning "`--index-url` 会替换默认源"
    这条命令只用 PyTorch 官方源，其他包（如 `numpy`）也走那里。
    装非 PyTorch 的包时去掉 `--index-url`，或者用下面的项目方式配置。

### 项目方式（推荐）

在项目里用 `pyproject.toml` 声明依赖，一次配置长期有效：

```bash
uv init --python 3.12
```

编辑 `pyproject.toml`：

```toml
[project]
name = "mytrain"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "torch>=2.4",
    "torchvision",
]

[tool.uv.sources]
torch = { index = "pytorch" }
torchvision = { index = "pytorch" }

[[tool.uv.index]]
name = "pytorch"
url = "https://download.pytorch.org/whl/cu124"
explicit = true
```

```bash
uv sync          # 按 pyproject.toml 建环境并装依赖
```

| 配置 | 作用 |
|---|---|
| `[[tool.uv.index]]` | 增加 PyTorch 官方源 |
| `explicit = true` | **该源只用于被显式指定的包**，`numpy` 之类仍走 PyPI |
| `[tool.uv.sources]` | 把 `torch`、`torchvision` 钉到这个源上 |

!!! tip "`explicit = true` 别省"
    不加的话，uv 会在所有源里查找每个包。
    加上它，只有 `torch` 系列走 PyTorch 源，其余走默认源，行为清晰。

### 验证

!!! danger "在登录终端里验证一定是 `False`"
    登录会话没有 GPU 访问权限。必须通过 Slurm 提交：

    ```bash
    srun --gres=gpu:1 --time=00:05:00 \
      uv run python -c "
    import torch
    print('PyTorch:', torch.__version__)
    print('CUDA 可用:', torch.cuda.is_available())
    print('卡数:', torch.cuda.device_count())
    print('设备:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')
    "
    ```

## 在 Slurm 任务里使用

虚拟环境就是一个普通目录，`sbatch` 脚本里激活即可：

```bash
#!/bin/bash
#SBATCH --job-name=uv-job
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=logs/%j.out

mkdir -p logs

# 激活项目的虚拟环境
source ~/myproject/.venv/bin/activate

echo "Python: $(which python)"

python -u train.py
```

用 `uv run` 的写法（不需要激活）：

```bash
#SBATCH --output=logs/%j.out

cd ~/myproject
uv run python -u train.py
```

!!! danger "非交互式 shell 不会自动加载任何环境"
    `sbatch` 跑在非交互式 shell 里。不管是 uv 还是别的工具，
    **都要在脚本里显式指定环境**，否则会用到系统 Python。
    用 `echo "Python: $(which python)"` 打一行出来，出问题时一眼能看出用了哪个解释器。

!!! warning "环境必须放在共享目录"
    当前是单节点，家目录和本地盘都能用。
    **扩展多节点后**，环境要放在 NFS 共享的目录（家目录或共享数据盘）下，
    否则其他节点上找不到这个 `.venv`，会报 `No such file or directory`。

## 换国内镜像加速

默认从 PyPI 拉包，国内较慢。设置默认源：

```bash
# 写进 ~/.bashrc 长期生效
echo 'export UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple' >> ~/.bashrc
source ~/.bashrc
```

或者临时用：

```bash
UV_DEFAULT_INDEX=https://pypi.tuna.tsinghua.edu.cn/simple uv sync
```

!!! note "PyTorch 官方源没有国内镜像"
    `download.pytorch.org` 是 PyTorch 官方专用源，**清华、阿里等镜像里没有**。
    国内拉取慢时只能：

    * 挂代理后重试；
    * 或在能上网的机器上 `uv pip download` 下载 wheel，再传到服务器本地安装：

      ```bash
      uv pip install /path/to/torch-2.4.0+cu124-cp312-linux_x86_64.whl
      ```

## 依赖锁定与复现

`pyproject.toml` 记录「要什么」，`uv.lock` 记录「实际装了哪个版本」。

```bash
uv lock          # 生成/更新 uv.lock
uv sync          # 按 uv.lock 精确安装
uv sync --frozen # 严格按锁文件装，不更新锁文件（CI 用）
```

!!! tip "把 `uv.lock` 提交进 Git"
    这样别人（和未来的你）能装出完全一样的环境，
    不会遇到「我这能跑你那报错」的版本漂移问题。

    只想导出传统依赖清单给别人用：

    ```bash
    uv export --format requirements-txt > requirements.txt
    ```

## 常用命令

```bash
uv venv --python 3.12        # 建虚拟环境
uv sync                      # 按 pyproject.toml / uv.lock 同步环境
uv add pandas                # 加依赖并写进 pyproject.toml
uv remove pandas             # 移除依赖
uv run python train.py       # 在项目环境里跑命令
uv pip list                  # 列出已装的包
uv pip install <包名>         # 临时装包（改环境不改 pyproject.toml）
uv tree                      # 查看依赖树
uv cache clean               # 清缓存
uv self update               # 升级 uv 本体
```

!!! warning "不要混用 `uv pip install` 和 `uv add`"
    `uv pip install` 只改当前环境，`uv add` 会同时更新 `pyproject.toml` 和 `uv.lock`。
    项目里请统一用 `uv add`，否则别人 `uv sync` 时装不到你临时装的包。

## 缓存与磁盘

uv 的下载缓存默认在 `~/.cache/uv`，同一个包只下载一次，多个环境共享。

```bash
du -sh ~/.cache/uv       # 看缓存占用
uv cache clean           # 清理
```

!!! tip "缓存搬家"
    家目录空间紧张时，把缓存指到数据盘：

    ```bash
    echo 'export UV_CACHE_DIR=/data/$USER/.cache/uv' >> ~/.bashrc
    ```

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `uv: command not found` | 安装后没重新加载 shell | `source ~/.local/bin/env` 或重新登录 |
| `CUDA driver version is insufficient` | wheel 的 CUDA 版本高于驱动 | 换更低的 `cuXXX` 源，见 [安装 PyTorch](#安装-pytorch) |
| 登录终端里 `torch.cuda.is_available()` 为 `False` | 登录会话没有 GPU 权限 | 用 `srun --gres=gpu:1` 提交 |
| 任务里用了系统 Python | 脚本没指定环境 | 脚本里 `source .venv/bin/activate` 或 `cd` 后 `uv run` |
| `ModuleNotFoundError`（多机任务） | 环境在本地盘，其他节点看不到 | 把项目放到共享目录 |
| 装包极慢或超时 | 未配镜像 | 设 `UV_DEFAULT_INDEX` |
| 从源码编译某个包，很慢 | 没有对应的 wheel | 换 Python 版本或换包版本，找有 wheel 的组合 |
| `uv sync` 装出了不同的版本 | 没提交/没更新 `uv.lock` | 提交锁文件，CI 用 `--frozen` |

## 相关文档

* [GPU 训练实战](gpu-training.md) —— 用这个环境跑单卡/多卡训练
* [Slurm 任务调度](slurm.md) —— 任务的提交与管理
* [使用须知](basis.md) —— 磁盘与依赖管理的约定
