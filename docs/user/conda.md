# Python 环境管理

!!! danger "不要在系统 Python 里装包"
    集群的系统 Python 是操作系统的一部分。
    用 `pip install` 往里面装东西可能破坏系统工具，
    而且多个用户会互相覆盖依赖版本。

    **每个项目用自己的虚拟环境。**

## 为什么用 conda

| 方案 | 适合场景 |
|---|---|
| **conda** | 需要管理 CUDA 版本、非 Python 依赖（如 `ffmpeg`、`openmpi`），跨语言 |
| **venv + pip** | 纯 Python 依赖，且系统 CUDA 已满足需求 |

集群上推荐 **conda**：它能同时管理 Python 版本和 CUDA 运行时，
避免「PyTorch 要求的 CUDA 版本和系统驱动不匹配」这类问题。

## 安装 Miniconda

如果还没有：

```bash
# 在登录终端执行（这一步不需要 GPU）
cd ~
wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
bash Miniconda3-latest-Linux-x86_64.sh -b -p ~/miniconda3
~/miniconda3/bin/conda init bash
```

重新登录，或执行 `source ~/.bashrc` 让 `conda` 命令生效：

```bash
conda --version
```

!!! tip "装在家目录之外的路径"
    家目录空间有限时，可以把 miniconda 装到数据盘：

    ```bash
    bash Miniconda3-latest-Linux-x86_64.sh -b -p /data/$USER/miniconda3
    ```

    之后记得用该路径初始化。

## 换国内源加速

```bash
cat > ~/.condarc <<'EOF'
channels:
  - defaults
show_channel_urls: true
default_channels:
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r
custom_channels:
  conda-forge: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
  pytorch: https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud
EOF

conda clean -i     # 清掉旧的索引缓存
```

!!! note "服务器本身不能直连外网时"
    如果服务器访问外网受限，pip 也需要配镜像：

    ```bash
    pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
    ```

    或者临时指定：

    ```bash
    pip install -i https://pypi.tuna.tsinghua.edu.cn/simple <包名>
    ```

## 创建环境

```bash
# 指定 Python 版本
conda create -n myenv python=3.11 -y

# 激活
conda activate myenv
```

!!! warning "`conda activate` 之后要重新登录才生效？"
    如果提示 `CommandNotFoundError`，说明 shell 还没初始化。
    执行一次 `conda init bash` 然后重新登录即可。

## 安装 PyTorch

!!! danger "先确认驱动支持的 CUDA 版本"
    当前集群驱动是 `550.144.03`，支持 **CUDA 12.4 及更早版本**。
    装更新的 CUDA 版本可能无法运行。

    查看驱动版本：

    ```bash
    nvidia-smi        # 右上角 "CUDA Version: 12.4"
    ```

### 方式一：conda 安装（推荐）

```bash
conda activate myenv

# CUDA 12.1 版本（与驱动 550 兼容，稳定）
conda install pytorch torchvision torchaudio pytorch-cuda=12.1 \
  -c pytorch -c nvidia
```

### 方式二：pip 安装

```bash
conda activate myenv

pip install torch torchvision torchaudio \
  --index-url https://download.pytorch.org/whl/cu121
```

!!! tip "不要同时用 conda 和 pip 装 PyTorch"
    两者会往同一环境写不同的 CUDA 运行时，导致
    `libcudart.so` 版本冲突这种难查的问题。
    **选一种，装错了就重建环境。**

### 验证

```bash
python -c "
import torch
print('PyTorch:', torch.__version__)
print('CUDA 可用:', torch.cuda.is_available())
print('卡数:', torch.cuda.device_count())
print('设备:', torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')
"
```

!!! danger "在登录终端里验证会看到 `CUDA 可用: False`"
    这是**正常的** —— 登录会话没有 GPU 访问权限。
    验证必须通过 Slurm：

    ```bash
    srun --gres=gpu:1 --time=00:05:00 python -c "
    import torch
    print('CUDA 可用:', torch.cuda.is_available())
    print('卡数:', torch.cuda.device_count())
    "
    ```

## 在 Slurm 任务中使用 conda

!!! danger "最容易踩的坑：任务里 `conda activate` 失败"
    `sbatch` 提交的脚本运行在非交互式 shell 中，
    **不会自动加载 `conda` 的 shell 函数**。

### 正确写法

```bash
#!/bin/bash
#SBATCH --job-name=conda-job
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=02:00:00
#SBATCH --output=logs/%j.out

# 关键：先加载 conda 的 shell 函数
source ~/miniconda3/etc/profile.d/conda.sh

# 然后再激活环境
conda activate myenv

# 确认真的激活了（排查时很有用）
echo "Python: $(which python)"
echo "环境: ${CONDA_DEFAULT_ENV}"

python -u train.py
```

!!! tip "用绝对路径更稳妥"
    如果不确定 conda 装在哪：

    ```bash
    conda info --base        # 输出 conda 的根目录
    ```

    然后用 `<base>/etc/profile.d/conda.sh`。

### 环境装在哪很重要

| 位置 | 多节点时是否可用 |
|---|---|
| `~/miniconda3`（家目录，NFS 共享） | ✅ 所有节点都能访问 |
| `/data/...`（共享数据盘） | ✅ |
| 本地磁盘的某个路径 | ❌ 其他节点看不到 |

!!! warning "多机任务必须用共享存储上的环境"
    如果把环境装在某台机器的本地盘上，
    多机任务在另一台机器上会找不到这个环境，
    报 `No such file or directory` 或 `ModuleNotFoundError`。

## 导出与复现环境

```bash
# 导出（推荐 yml，包含 pip 依赖与 channel 信息）
conda env export --no-builds > environment.yml

# 从文件重建
conda env create -f environment.yml

# 只导出显式安装的包（更干净，跨平台性更好）
conda env export --from-history > environment.yml
```

!!! tip "把 `environment.yml` 提交进 Git"
    这样别人（和未来的你）能精确复现环境。
    纯 pip 项目可以只维护 `requirements.txt`。

```bash
# 更新已有环境
conda env update -f environment.yml --prune
```

## 常用命令

```bash
conda env list                  # 列出所有环境
conda activate myenv            # 激活
conda deactivate                # 退出
conda list                      # 当前环境的包
conda install <pkg>             # 装包
conda update <pkg>              # 升级
conda remove -n myenv --all     # 删除整个环境
conda clean --all               # 清理缓存（省空间）
```

!!! warning "环境多了会占用大量家目录空间"
    每个 conda 环境可能几个 GB。不用的及时删：

    ```bash
    conda remove -n old_env --all
    conda clean --all

    # 看看家目录被谁占了
    du -sh ~/* | sort -h | tail -10
    ```

## 常见问题

| 现象 | 原因 | 解决 |
|---|---|---|
| `conda: command not found` | shell 未初始化 | `conda init bash` 后重新登录 |
| 任务里 `conda activate` 报错 | 非交互式 shell 未加载 conda | 脚本里先 `source .../conda.sh` |
| `torch.cuda.is_available()` 为 `False` | 在登录终端里跑，或没申请 GPU | 用 `srun --gres=gpu:1` |
| `libcudart.so.XX: cannot open shared object file` | conda 与 pip 混装 | 重建环境，只用一种方式装 PyTorch |
| `ModuleNotFoundError`（多机任务） | 环境在本地盘，其他节点看不到 | 把环境放到共享目录 |
| 装包极慢或超时 | 未配镜像源 | 配 `~/.condarc` 或 pip 镜像 |
| 家目录空间不足 | conda 缓存与环境占用 | `conda clean --all`，删旧环境 |
| `CondaHTTPError` | 源不可达 | 换镜像源，或检查代理设置 |

## 相关文档

* [GPU 训练实战](gpu-training.md) —— 用这个环境跑单卡/多卡训练
* [Slurm 任务调度](slurm.md) —— 任务的提交与管理
* [使用须知](basis.md) —— 磁盘与依赖管理的约定
