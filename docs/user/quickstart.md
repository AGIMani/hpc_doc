# 快速开始

本篇用 5 分钟带你跑通第一个 GPU 任务。假定管理员已经给你开好账号。

!!! danger "记住一条规则"
    所有需要显卡的命令，都必须写在 `srun` / `sbatch` / `salloc` 后面。
    直接在登录终端里跑 `nvidia-smi` 会报 `Failed to initialize NVML: Unknown Error`。

## 第 1 步：登录服务器

```bash
ssh zhangsan@SERVER_IP
```

首次登录会要求修改初始密码。登录成功的提示符是 `zhangsan@TenseiNode1:~$`。

## 第 2 步：看集群现在有没有空卡

```bash
sinfo
```

输出示例：

```text
PARTITION AVAIL  TIMELIMIT  NODES  STATE NODELIST
gpu*         up   7-00:00:00      1   idle TenseiNode1
```

| 字段 | 含义 |
|---|---|
| `PARTITION` | 队列名，`gpu*` 中的 `*` 表示这是默认队列 |
| `TIMELIMIT` | 队列允许的最长运行时间，这里是 7 天 |
| `STATE` | `idle` 完全空闲；`mixed` 部分占用；`alloc` 全部占满 |
| `NODELIST` | 节点名 |

想看每张卡的分配情况：

```bash
sinfo -N -l
```

## 第 3 步：申请一张卡，进去试一下

```bash
srun --gres=gpu:1 --cpus-per-task=8 --mem=32G \
     --time=00:30:00 --pty bash
```

这条命令的意思是：**申请 1 张 GPU、8 个 CPU、32 GiB 内存，最多用 30 分钟，
给我一个交互式 shell**。

资源够的话你会立刻进入一个新 shell（提示符里通常能看到节点名）。
在这个 shell 里验证显卡：

```bash
nvidia-smi -L
```

应该只看到**一张** A100：

```text
GPU 0: NVIDIA A100-SXM4-80GB (UUID: GPU-a0276972-...)
```

再看一眼显卡状态：

```bash
nvidia-smi
```

!!! tip "显示 `GPU 0` 是正常的"
    Slurm 会把分配给你们的卡重新编号成从 0 开始，并用 `CUDA_VISIBLE_DEVICES` 限定可见范围。
    你在任务里**不可能看到别人正在用的卡**。

试一下 Python 能不能用上卡：

```bash
python -c "import torch; print(torch.cuda.device_count(), torch.cuda.get_device_name(0))"
```

用完退出，资源立刻释放：

```bash
exit
```

!!! warning "交互式任务的时间是「占用时间」"
    从 `srun --pty bash` 进入那一刻开始计时，**哪怕你只是在里面发呆**。
    调试完请及时 `exit`。

## 第 4 步：提交一个正式训练任务

先准备一个脚本 `train.py`（你自己的训练代码），再写提交脚本 `train.sh`：

```bash
#!/bin/bash
#SBATCH --job-name=train-demo          # 任务名，会显示在 squeue 里
#SBATCH --gres=gpu:1                   # 申请 1 张 GPU
#SBATCH --cpus-per-task=8              # 8 个 CPU
#SBATCH --mem=32G                      # 32 GiB 主机内存
#SBATCH --time=04:00:00                # 最长跑 4 小时
#SBATCH --output=logs/%j.out           # 标准输出 -> logs/任务号.out
#SBATCH --error=logs/%j.err            # 标准错误 -> logs/任务号.err

# 注意：所有 #SBATCH 行必须连续写在文件开头，中间不能插入其他命令

mkdir -p logs

# 进入虚拟环境（如果用了 conda）
source ~/miniconda3/etc/profile.d/conda.sh
conda activate myenv

# -u 让 Python 不缓冲输出，日志能实时看到
python -u train.py
```

提交：

```bash
mkdir -p logs
sbatch train.sh
```

输出 `Submitted batch job 123`，其中 `123` 就是任务号 `JOBID`。

## 第 5 步：查看任务状态

```bash
squeue -u "$USER"
```

| `ST` | 含义 |
|---|---|
| `PD` (PENDING) | 排队中，还没拿到资源 |
| `R` (RUNNING) | 正在运行 |
| `CG` (COMPLETING) | 正在收尾 |

看某个任务的详细信息和排队原因：

```bash
scontrol show job 123
```

实时跟踪日志：

```bash
tail -f logs/123.out
```

!!! tip "日志迟迟不更新？"
    多半是 Python 输出缓冲。用 `python -u train.py`，
    或者在脚本里加 `import sys; sys.stdout.reconfigure(line_buffering=True)`。

## 第 6 步：不需要了 / 提交错了

```bash
scancel 123          # 取消任务号 123
scancel -u zhangsan  # 取消自己的全部任务
```

!!! danger "`scancel` 不可撤销"
    任务被取消后，没存盘的进度就没了。执行前先用 `squeue` 确认任务号。

## 第 7 步：跑完了，看用量

```bash
# 已完成任务的资源与耗时
sacct -j 123 --format=JobID,JobName,Elapsed,AllocTRES,State,ExitCode

# 我最近的 GPU 用量
sacct -u "$USER" --starttime=today \
      --format=JobID,JobName,Elapsed,AllocTRES,State
```

网页看板（先建 SSH 隧道，见 [访问集群](access.md#通过-ssh-隧道访问监控页面)）：

* `http://localhost:3000` → Grafana，看每张卡的实时占用和按用户统计的卡时

## 完整流程速查

```bash
# 登录
ssh zhangsan@SERVER_IP

# 看有没有空卡
sinfo

# 交互调试（30 分钟，1 张卡）
srun --gres=gpu:1 --cpus-per-task=8 --mem=32G --time=00:30:00 --pty bash
nvidia-smi -L
exit

# 提交正式任务
sbatch train.sh

# 查看 / 跟踪 / 取消
squeue -u "$USER"
tail -f logs/123.out
scancel 123

# 查历史用量
sacct -u "$USER" --starttime=today
```

## 下一步

| 我想…… | 去看 |
|---|---|
| 搞懂 `srun` / `sbatch` / `salloc` 的全部参数 | [Slurm 任务调度](slurm.md) |
| 一次跑几十组实验 | [批量提交与任务组](slurm.md#后台批处理sbatch-与任务组) |
| 用满 8 张卡训一个模型 | [GPU 训练实战](gpu-training.md) |
| 任务一直排队，不知道为什么 | [用量查询与监控](monitor.md) |
| 遇到报错 | [常见问题](faq.md) |
