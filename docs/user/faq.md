# 常见问题

按现象查找。每条都给出**原因**和**具体操作**。

## GPU 与设备

### `Failed to initialize NVML: Unknown Error`

**这是预期行为，不是故障。**

集群限制了普通登录会话的设备访问，所以在 SSH 终端里直接跑 `nvidia-smi`
拿不到 GPU。**所有需要显卡的命令都必须通过 Slurm 提交。**

```bash
# ❌ 在登录终端里直接跑
nvidia-smi

# ✅ 通过 Slurm
srun --gres=gpu:1 --time=00:05:00 nvidia-smi -L
```

!!! note "为什么不是「命令找不到」"
    有的集群把 `nvidia-smi` 从普通用户的 `PATH` 里去掉，报 `command not found`。
    本集群限制的是设备节点，二进制还在，所以报 NVML 初始化失败。效果一样。

### `torch.cuda.is_available()` 返回 `False`

| 原因 | 检查 |
|---|---|
| 在登录终端里跑 | 用 `srun --gres=gpu:1` 提交 |
| 任务没申请 GPU | 加 `--gres=gpu:1` |
| conda 与 pip 混装了 PyTorch | 重建环境，只用一种方式装 |

```bash
# 在 Slurm 任务里诊断
srun --gres=gpu:1 --time=00:05:00 bash -c '
  echo "CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"
  nvidia-smi -L
  python -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
'
```

### 任务里看到的卡数比申请的少

先确认 `#SBATCH` 行写法正确：

```bash
#SBATCH --gres=gpu:4
```

!!! danger "`#SBATCH` 行必须连续且在文件最前面"
    在所有 `#SBATCH` 行之前或之间插入普通命令（`echo`、变量赋值），
    后面的 `#SBATCH` 会被当成普通注释**静默忽略**，
    任务就用默认资源跑起来了 —— 默认不打 `--gres`，于是没有 GPU。

### 看到的卡编号不是 0、1、2…

**正常。** Slurm 把分配给你的卡重新编号成从 0 开始。
这样代码里写 `cuda:0` 永远指「我拿到的第一张卡」。

## 任务排队与调度

### 任务一直 `PENDING`

```bash
squeue -u "$USER"          # 看 ST 是不是 PD
scontrol show job <JOBID>  # 看 Reason 字段
```

| `Reason` | 处理 |
|---|---|
| `Resources` | 卡被占满，正常等待。看 `scontrol show node TenseiNode1 \| grep GresUsed` |
| `Priority` | 优先级不够，正常等待 |
| `QOSMaxJobsPerUserLimit` | 达到个人并发上限，等自己的任务结束 |
| `AssocGrpGRESMinutesLimit` | 达到账户卡时上限 |
| `ReqNodeNotAvail` | 节点维护中，联系管理员 |
| `BadConstraints` | 申请的配置不存在，检查 `--gres` / `--mem` |

!!! tip "缩短 `--time` 能显著减少排队"
    调度器启用了 **Backfill（回填）**：短任务可以被塞进大任务之间的空档。
    前提是你的 `--time` 声明得足够短。

    把 30 分钟的任务写成 10 小时，它就只能排在后面老实等。

### 8 卡任务永远排不上

只要有 1 张卡被别人的任务占着，8 卡任务就会一直等。

```bash
# 看具体哪几张卡被占了
scontrol show node TenseiNode1 | grep -i gres
# GresUsed=gpu:a100:3(IDX:0,2,5)  →  0、2、5 被占用
```

**建议**：先用 1～4 张卡完成调试与验证，最后阶段再申请整机 8 卡。
或者用 `--time` 精确申报，让调度器更容易安排。

### 任务还没跑完就被杀了

```bash
sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed,TimeLimit,MaxRSS
```

| `State` | 原因 | 处理 |
|---|---|---|
| `TIMEOUT` | 超出 `--time` | 调大时限，并**在脚本里定期存 checkpoint** |
| `OUT_OF_MEMORY` | **主机内存**不足 | 调大 `--mem` |
| `NODE_FAIL` | 节点故障 | 联系管理员，重新提交 |
| `CANCELLED` | 被取消 | 检查是否自己 `scancel` 了 |
| `FAILED` | 程序自身出错 | 看 `.err` 日志 |

!!! danger "时限到点会直接终止，没有缓冲"
    长任务必须把 `--time` 写足**并且定期存 checkpoint**。
    参考 [长任务的正确姿势](gpu-training.md#长任务的正确姿势)。

## 显存与内存

### `CUDA out of memory`

**这是显存不够**，与 `--mem` 无关（`--mem` 限制的是主机内存）。

| 方法 | 收益 |
|---|---|
| 减小 batch size | 线性减少 |
| 梯度累积（等效大 batch） | 不省显存，但能保持等效 batch |
| 混合精度 `bf16` | 约 40% |
| 梯度检查点 | 约 60%，代价是算得慢 |
| ZeRO / FSDP 分片 | 随卡数线性 |

```python
# 梯度累积示例
accum = 8
for i, batch in enumerate(loader):
    loss = model(**batch).loss / accum
    loss.backward()
    if (i + 1) % accum == 0:
        optimizer.step()
        optimizer.zero_grad()
```

### `slurmstepd: error: Detected 1 oom-kill event`

**这是主机内存不够**，不是显存。

```bash
#SBATCH --mem=256G     # 调大
```

!!! warning "这两个 OOM 完全不同"
    * `CUDA out of memory`（Python 报）→ 显存
    * `oom-kill event`（Slurm 报）→ **主机内存**

    申请 8 张卡**不会**自动给你更多主机内存。

## 日志与输出

### 日志长时间不更新

Python 输出缓冲导致。用 `-u`：

```bash
python -u train.py
```

或在代码里：

```python
import sys
sys.stdout.reconfigure(line_buffering=True)
```

### 找不到任务输出文件

`sbatch` 默认写到**提交任务时所在目录**的 `slurm-<JOBID>.out`。

```bash
# 确认实际路径
scontrol show job <JOBID> | grep -E 'StdOut|StdErr|WorkDir'
```

建议显式指定：

```bash
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err
```

!!! danger "`logs/` 目录必须存在"
    重定向到不存在的目录会让任务在启动时失败。
    在脚本里先 `mkdir -p logs`，
    **但注意 `#SBATCH` 行必须在 `mkdir` 之前**。

## 环境与依赖

### `sbatch` 任务里 `conda activate` 失败

非交互式 shell 不会自动加载 conda 的函数定义。在脚本开头显式加载：

```bash
source ~/miniconda3/etc/profile.d/conda.sh
conda activate myenv
```

### 多机任务报 `ModuleNotFoundError`

环境装在了某台机器的**本地盘**上，其他节点看不到。
把 conda 环境放到**共享目录**（家目录或共享数据盘）。

### 装包很慢或超时

服务器访问外网受限。配置镜像源：

```bash
# conda
cat > ~/.condarc <<'EOF'
channels:
  - defaults
default_channels:
  - https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main
EOF

# pip
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
```

### `libcudart.so.XX: cannot open shared object file`

conda 和 pip 混装 PyTorch 导致 CUDA 运行时冲突。
**重建环境**，只用一种方式安装：

```bash
conda remove -n myenv --all
conda create -n myenv python=3.11 -y
conda activate myenv
conda install pytorch torchvision torchaudio pytorch-cuda=12.1 -c pytorch -c nvidia
```

## 多机与多卡

### 多卡比单卡还慢

| 原因 | 排查 |
|---|---|
| 通信占比过高 | 增大每卡 batch size |
| 没走高速网络 | 联系管理员确认 NCCL 用的网络 |
| 同步点太多 | 减少 `dist.barrier()` |
| 数据加载是瓶颈 | 增加 `num_workers` |

### `torchrun` 报 `Address already in use`

端口被占用或残留进程。换端口：

```bash
torchrun --master-port=29501 ...
```

或检查是否有重复提交的任务：

```bash
squeue -u "$USER"
```

### `NCCL error` / 通信超时

多机训练的网络问题，超出用户侧能解决的范围。

!!! tip "先跑最小验证再联系管理员"
    ```bash
    srun --nodes=2 --ntasks-per-node=1 --gres=gpu:1 --time=00:05:00 \
      bash -c 'hostname; nvidia-smi -L'
    ```
    如果这个都不通，说明是调度或节点问题；
    如果通但训练不通，大概率是 NCCL / 机间网络配置问题。

    把 `nvidia-smi topo -m` 和 `ibstat` 的输出一起发给管理员。

## 访问与页面

### SSH 能登录，但监控页面打不开

隧道没建好。检查：

1. Xshell 会话是否处于连接状态（隧道随会话建立）；
2. 或命令行隧道进程是否还在：

    ```bash
    ssh -N -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 zhangsan@SERVER_IP
    ```

3. 浏览器地址是否正确（`http://localhost:3000`）。

### 提示本地端口被占用

改本地端口，**目标端口保持不变**：

```bash
ssh -N -L 13000:127.0.0.1:3000 zhangsan@SERVER_IP
# 浏览器改用 http://localhost:13000
```

### Grafana 登录失败

Grafana 是**独立账号体系**，SSH 能登录不代表能登录 Grafana。
联系管理员开通。

### Cockpit 提示证书不受信任

正常的自签名证书提示。确认地址是 `https://localhost:9090`
且隧道目标正确后继续访问。

## 磁盘与文件

### 家目录空间不足

```bash
# 看谁占了空间
du -sh ~/* | sort -h | tail -10

# conda 缓存通常是大头
conda clean --all

# 删除不用的环境
conda remove -n old_env --all
```

!!! danger "家目录写满会影响整个集群"
    如果 `/home` 与系统盘同分区，写满会让数据库和调度服务无法写入。
    大数据集请放数据盘，并及时清理。

### `Permission denied` 写入某目录

确认你自己的目录权限：

```bash
id
ls -ld ~ ~/data
```

如果你在共享目录里遇到「自己的文件却无权限」，
可能是**多节点 UID 不一致**导致的（扩展节点后的常见问题），
联系管理员检查各节点的 UID/GID。

!!! warning "不要用 `chmod -R 777` 解决问题"
    这会让所有用户都能改你的代码和数据。
    正确做法是联系管理员排查权限根因。

## 还是解决不了

把以下信息一起发给管理员，能大幅加快定位速度：

```bash
# 1. 任务详情
scontrol show job <JOBID>

# 2. 任务状态与退出码（任务已结束时用）
sacct -j <JOBID> --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocTRES

# 3. 报错日志最后 50 行
tail -n 50 logs/<JOBID>.err

# 4. 集群与节点状态
sinfo -N -l
squeue -u "$USER"

# 5. 环境信息
python -c "import torch,sys; print(sys.version); print(torch.__version__, torch.version.cuda)"
```

!!! tip "描述现象而不是猜测原因"
    ✅ 「任务号 123 在 15:20 变成 `TIMEOUT`，日志最后一行是 saving checkpoint」
    ❌ 「集群坏了，我的任务跑不了」

    前者能直接定位，后者需要来回问好几轮。

## 相关文档

* [快速开始](quickstart.md) —— 第一个任务的完整流程
* [Slurm 任务调度](slurm.md) —— 参数含义与排队规则
* [GPU 训练实战](gpu-training.md) —— 多卡、显存与性能
* [用量查询与监控](monitor.md) —— 查看状态与用量
* [Python 环境管理](conda.md) —— 环境问题
