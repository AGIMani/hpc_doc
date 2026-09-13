# GPU 训练实战

本篇讲怎么把训练任务真正跑起来：单卡、单机多卡、多机多卡，
以及显存不够、速度不对、卡住了怎么办。

!!! danger "所有命令都必须通过 Slurm 提交"
    直接在登录终端跑 `python train.py` **拿不到 GPU**。
    下面的每个例子都写在 `srun` 或 `sbatch` 里。

## 任务里能看到什么

Slurm 会把分配给你的 GPU 通过 `CUDA_VISIBLE_DEVICES` 暴露出来，
**并且重新编号从 0 开始**：

```bash
srun --gres=gpu:2 --time=00:10:00 --pty bash

echo "$CUDA_VISIBLE_DEVICES"     # 例如 3,5
nvidia-smi -L                    # 显示 GPU 0 / GPU 1（重新编号后）
python -c "import torch; print(torch.cuda.device_count())"   # 2
```

!!! note "为什么编号变了"
    你拿到的是物理卡 3 和 5，但在任务内它们被映射成 `0` 和 `1`。
    这样代码里写 `cuda:0` 永远指「我拿到的第一张卡」，
    **不需要根据别人占用情况改代码**。

!!! warning "不要手工覆盖 `CUDA_VISIBLE_DEVICES`"
    它只控制「程序能看到哪些卡」。真正的隔离由 cgroup 完成 ——
    覆盖它不会让你多拿到卡，只会让编号混乱、排查困难。

## 单卡训练

```bash
#!/bin/bash
#SBATCH --job-name=train-single
#SBATCH --gres=gpu:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=08:00:00
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

mkdir -p logs

python -u train.py --epochs 50
```

```bash
sbatch train.sh
squeue -u "$USER"
tail -f logs/<JOBID>.out
```

!!! tip "`-u` 是关键"
    不加 `-u`，Python 会缓冲输出，日志可能几十分钟不更新，
    让你误以为任务卡住了。

## 单机多卡训练

单机 8 卡最常见。用 PyTorch 的 `torchrun` 启动 DDP。

### 推荐写法：`srun` + `torchrun`

```bash
#!/bin/bash
#SBATCH --job-name=ddp-8gpu
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=64
#SBATCH --mem=512G
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

mkdir -p logs

# --standalone 让 torchrun 自己处理 rendezvous，单机场景最简单
torchrun \
  --standalone \
  --nproc-per-node=8 \
  train_ddp.py
```

```bash
sbatch train.sh
```

!!! danger "8 卡任务需要等 8 张卡同时空闲"
    只要有 1 张卡被别人的任务占着，这个任务就会一直排队。
    提交前先看：

    ```bash
    scontrol show node TenseiNode1 | grep -i gres
    ```

    输出里的 `GresUsed=gpu:3(IDX:0,2,5)` 会告诉你具体哪几张卡被占用。

### 关于 `--nproc-per-node` 的取值

不要写死 `8`，从 Slurm 环境变量读更稳妥：

```bash
torchrun --standalone \
  --nproc-per-node="${SLURM_GPUS_ON_NODE:-1}" \
  train_ddp.py
```

!!! note "`SLURM_GPUS_ON_NODE` 不一定存在"
    它依赖 Slurm 的 GRES 配置。如果为空，回退值 `1` 会让程序退化成单卡。
    更可靠的写法是先自己数一下：

    ```bash
    n_gpu=$(python -c "import torch; print(torch.cuda.device_count())")
    torchrun --standalone --nproc-per-node="$n_gpu" train_ddp.py
    ```

### DDP 代码要点

```python
import os
import torch
import torch.distributed as dist

def main():
    # torchrun 会设置这些环境变量
    rank = int(os.environ["RANK"])
    world_size = int(os.environ["WORLD_SIZE"])
    local_rank = int(os.environ["LOCAL_RANK"])

    # 每个进程绑定到自己负责的那张卡
    torch.cuda.set_device(local_rank)

    dist.init_process_group(
        backend="nccl",
        rank=rank,
        world_size=world_size,
    )

    model = build_model().to(local_rank)
    # 关键：把模型包进 DDP
    model = torch.nn.parallel.DistributedDataParallel(
        model, device_ids=[local_rank]
    )

    # 数据也要按 rank 切分
    sampler = torch.utils.data.DistributedSampler(dataset)
    loader = torch.utils.data.DataLoader(
        dataset, sampler=sampler, batch_size=32, num_workers=4
    )

    for epoch in range(epochs):
        sampler.set_epoch(epoch)      # 每个 epoch 都要重设，保证打散
        for batch in loader:
            ...

    dist.destroy_process_group()

if __name__ == "__main__":
    main()
```

!!! warning "两个最常被忘掉的地方"
    1. **忘记 `DistributedSampler`** —— 每个进程都跑全量数据，
       等于把 batch size 放大了 8 倍，收敛会出问题；
    2. **忘记 `sampler.set_epoch(epoch)`** —— 每个 epoch 的数据顺序完全一样。

### 关键：每个 epoch 存 checkpoint

!!! danger "任务随时可能被终止"
    超过 `--time` 会被强杀，节点也可能出故障。
    **不存 checkpoint 的长任务等于赌博。**

```python
import os
import torch

def save_checkpoint(path, model, optimizer, epoch, best_metric):
    # 只让 rank 0 写文件，避免 8 个进程同时写同一个文件
    if int(os.environ.get("RANK", 0)) != 0:
        return
    tmp = f"{path}.tmp"
    torch.save({
        "epoch": epoch,
        "model": model.module.state_dict(),   # DDP 要用 .module
        "optimizer": optimizer.state_dict(),
        "best_metric": best_metric,
    }, tmp)
    os.replace(tmp, path)      # 原子替换，避免写出半个文件

# 恢复
def load_checkpoint(path, model, optimizer):
    if not os.path.exists(path):
        return 0, float("inf")
    ckpt = torch.load(path, map_location="cpu")
    model.module.load_state_dict(ckpt["model"])
    optimizer.load_state_dict(ckpt["optimizer"])
    return ckpt["epoch"] + 1, ckpt["best_metric"]
```

!!! tip "先写临时文件再 `os.replace`"
    直接 `torch.save` 到目标路径，如果这时任务被杀，
    会留下一个**损坏的 checkpoint**，恢复时才发现，损失更大。
    原子替换保证「要么是旧的完整版，要么是新的完整版」。

## 多机多卡训练

!!! danger "多机训练的前提是机间网络已经验证过"
    Slurm 只负责把机器分配给你，**不会让单机程序自动变成分布式程序**。
    跨机通信依赖 InfiniBand / RoCE、RDMA 驱动与 NCCL 配置。

    扩展多节点后，**先做双机通信测试**，确认有效再上大规模训练。
    另外，多台 A100 的显存**不会自动合并**成一块大显存。

### 启动方式

```bash
#!/bin/bash
#SBATCH --job-name=ddp-multinode
#SBATCH --nodes=2
#SBATCH --ntasks-per-node=1
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=64
#SBATCH --mem=512G
#SBATCH --time=2-00:00:00
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err

mkdir -p logs

# 取节点列表的第一个作为 rendezvous 主机
nodes=$(scontrol show hostname "$SLURM_NODELIST" | head -n1)

torchrun \
  --nnodes="$SLURM_NNODES" \
  --node-rank="$SLURM_NODEID" \
  --master-addr="$nodes" \
  --master-port=29500 \
  --nproc-per-node=8 \
  train_ddp.py
```

```bash
sbatch train.sh
```

| 参数 | 含义 |
|---|---|
| `--nnodes` | 总节点数，来自 `SLURM_NNODES` |
| `--node-rank` | 本节点在集群中的序号，来自 `SLURM_NODEID` |
| `--master-addr` | rendezvous 主机，取节点列表第一个 |
| `--nproc-per-node` | 每台机器启动几个进程（= 每台卡数） |

!!! note "`--gres=gpu:8` 与 `--ntasks-per-node=1` 要配合"
    每台机器只启一个 `torchrun` 进程，由它再拉起 8 个训练进程。
    如果写成 `--ntasks-per-node=8`，就会启动 8 个 `torchrun`，
    每个又拉起 8 个进程，变成 64 个进程抢 8 张卡。

### 先验证多机连通性

在动真格训练之前，先跑最小验证：

```bash
srun --nodes=2 --ntasks-per-node=1 --gres=gpu:1 --time=00:10:00 \
  bash -c 'echo "节点: $(hostname), CUDA_VISIBLE_DEVICES=$CUDA_VISIBLE_DEVICES"; nvidia-smi -L'
```

再跑一个 NCCL all-reduce 基准，确认带宽符合预期：

```bash
srun --nodes=2 --ntasks-per-node=1 --gres=gpu:1 --time=00:10:00 \
  bash -c 'python -c "
import torch, torch.distributed as dist, os
dist.init_process_group(\"nccl\")
t = torch.ones(1<<28, device=\"cuda\")
import time; torch.cuda.synchronize(); s=time.time()
for _ in range(20): dist.all_reduce(t)
torch.cuda.synchronize()
print(f\"rank={dist.get_rank()} 耗时 {time.time()-s:.3f}s\")
dist.destroy_process_group()
"'
```

!!! warning "如果带宽远低于预期"
    检查 `nvidia-smi topo -m` 看 GPU 与网卡的连接关系，
    确认 NCCL 走的是 IB/RoCE 高速网络。
    这属于管理员侧的机间网络配置，需要联系管理员排查。

## 显存不够怎么办

A100 有 80 GB 显存，但大模型依然容易 OOM。按优先级尝试：

| 方法 | 显存收益 | 代价 |
|---|---|---|
| **减小 batch size** | 线性 | 需要调学习率 |
| **梯度累积** | 等效大 batch，显存不变 | 训练变慢 |
| **混合精度（bf16/fp16）** | 约 40% | 需要 loss scaling（bf16 通常不需要） |
| **梯度检查点** | 约 60% | 计算量增加约 30% |
| **ZeRO / FSDP 分片** | 随卡数线性 | 通信开销增加 |
| **CPU offload** | 很大 | 速度显著下降 |

```python
# 梯度累积：等效 batch = 32 × 8 = 256
accum_steps = 8
optimizer.zero_grad()
for i, batch in enumerate(loader):
    with torch.autocast("cuda", dtype=torch.bfloat16):
        loss = model(**batch).loss / accum_steps
    loss.backward()
    if (i + 1) % accum_steps == 0:
        optimizer.step()
        optimizer.zero_grad()
```

!!! danger "`--mem` 限制的是主机内存"
    `--mem=512G` 表示允许用 512 GiB **主机内存**。
    显存由任务自己管理，Slurm 不做显存配额。
    申请 8 张卡**不会**自动给你更多主机内存。

!!! warning "`CUDA out of memory` 与 `--mem` 报错是两回事"
    * `CUDA out of memory` → 显存不够，用上面的方法
    * `slurmstepd: error: Detected 1 oom-kill event` → **主机内存**超了，调大 `--mem`

## 数据加载

!!! danger "别把大数据集放在家目录"
    家目录写满会影响整个集群。大数据集放数据盘，
    并在任务脚本里用绝对路径引用。

```python
from torch.utils.data import DataLoader

loader = DataLoader(
    dataset,
    batch_size=32,
    num_workers=8,          # 建议 = 分配的 CPU 数 / 每卡进程数
    pin_memory=True,        # 加速 CPU→GPU 拷贝
    persistent_workers=True,  # 避免每个 epoch 重启 worker
    prefetch_factor=4,
)
```

!!! tip "`num_workers` 怎么定"
    你已经用 `--cpus-per-task` 申请了 CPU。
    8 卡任务申请 64 个 CPU，那每个进程用 `64/8 = 8` 个 worker 比较合适。
    **worker 数超过实际可用 CPU 数反而会变慢** —— 大家在抢核。

## 性能排查

### 卡到底在不在干活

```bash
# 在任务内
nvidia-smi dmon -s u          # 实时利用率
nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv -l 2
```

!!! note "利用率低不一定是程序的问题"
    数据加载慢、CPU 预处理瓶颈、进程间同步等待都会让利用率掉下来。
    先看是不是 GPU 在等数据：

    ```bash
    nvidia-smi   # 看 GPU-Util 和 Memory-Usage 是否同步变化
    ```

### 常见瓶颈判断

| 现象 | 可能原因 | 排查 |
|---|---|---|
| GPU-Util 长期 < 30%，显存占用高 | 数据加载瓶颈 | 增加 `num_workers`、`prefetch_factor` |
| GPU-Util 波动剧烈 | 同步点太多，或 batch 太小 | 增大 batch、减少 `dist.barrier()` |
| 显存占用远低于 80 GB 但速度慢 | 计算量本身小，或 CPU 侧瓶颈 | 用 profiler 看时间分布 |
| 多卡不如单卡快 | 通信占比过高 | 检查 NCCL、增大每卡 batch |
| `nvidia-smi` 里进程数异常多 | `num_workers` 过多 | 降 worker 数 |

用 PyTorch profiler 定位：

```python
from torch.profiler import profile, ProfilerActivity

with profile(activities=[ProfilerActivity.CPU, ProfilerActivity.CUDA]) as prof:
    for _ in range(10):
        train_step()
print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=20))
```

## 长任务的正确姿势

```bash
#!/bin/bash
#SBATCH --job-name=long-train
#SBATCH --gres=gpu:8
#SBATCH --cpus-per-task=64
#SBATCH --mem=512G
#SBATCH --time=3-00:00:00          # 如实填写，别虚报
#SBATCH --output=logs/%j.out
#SBATCH --error=logs/%j.err
#SBATCH --requeue                  # 节点故障时自动重新排队

mkdir -p logs checkpoints

python -u train.py \
  --checkpoint-dir checkpoints \
  --save-every 500 \
  --resume          # 自动从最新 checkpoint 继续
```

```python
# train.py 里支持断点续训
start_epoch, best = load_checkpoint(
    os.path.join(args.checkpoint_dir, "last.pt"), model, optimizer
)
if start_epoch > 0:
    print(f"从 epoch {start_epoch} 继续训练")
```

!!! tip "`--requeue` 让节点故障不再毁掉整个任务"
    配合断点续训，节点重启后任务会自动重新排队并从 checkpoint 继续。

!!! danger "如实填写 `--time` 真的能减少排队"
    调度器启用了 Backfill（回填），短任务能插进大任务之间的空档。
    把 4 小时的任务写成 3 天，它就只能老实排在后面。

## 常见错误速查

| 报错 | 原因 | 解决 |
|---|---|---|
| `Failed to initialize NVML: Unknown Error` | 在**登录终端**直接跑，没有经过 Slurm | 用 `srun` / `sbatch` 提交 |
| `torch.cuda.is_available()` 返回 `False` | 任务里没有申请 GPU | 加 `--gres=gpu:N` |
| `CUDA out of memory` | 显存不足 | 减 batch / 混合精度 / 梯度检查点 |
| `slurmstepd: Detected 1 oom-kill event` | **主机内存**不足 | 调大 `--mem` |
| `torch.cuda.device_count()` 少于预期 | `--gres` 申请少了 | 确认 `#SBATCH` 行连续且在文件开头 |
| `Address already in use`（`torchrun`） | 端口冲突或残留进程 | 换 `--master-port`，或确认没重复提交 |
| `NCCL error` / 通信超时 | 多机网络或 NCCL 配置问题 | 联系管理员，先跑双机连通性测试 |
| 任务 `PENDING` 且 `REASON=Resources` | 资源不足 | `scontrol show node TenseiNode1` 看占用 |
| 任务 `PENDING` 且 `REASON=QOSMax...` | 达到个人配额 | 等自己的任务结束 |
| 日志不更新 | Python 输出缓冲 | 用 `python -u` |
| 任务被杀死，日志无报错 | 超出 `--time` | 查看 `sacct -j <ID>` 的 `State` |
| `BadConstraints` | 申请的资源配置不存在 | 检查 `--gres` / `--mem` / `--cpus-per-task` |

## 相关文档

* [Slurm 任务调度](slurm.md) —— 全部提交参数与批量任务组
* [用量查询与监控](monitor.md) —— 查看自己和他人的 GPU 占用
* [Python 环境管理](conda.md) —— 配置 PyTorch 环境
* [常见问题](faq.md) —— 更多报错处理
