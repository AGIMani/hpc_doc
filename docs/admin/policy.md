# 调度策略与配额

本篇说明集群当前的调度策略、它在 `slurm.conf` 中对应的配置，以及如何调整策略。
**这是集群管理中最需要谨慎对待的部分** —— 改错一个参数可能让所有人的任务无法启动。

!!! info "当前策略一览"
    本节描述的是写入 `/etc/slurm/slurm.conf` 的版本。
    如果有人在服务器上手工编辑过该文件，请以 `scontrol show partition gpu`
    与 `scontrol show config` 的实际输出为准。

## 当前生效的策略

| 项目 | 当前值 | 配置项 |
|---|---|---|
| 集群名 | `tensei` | `ClusterName` |
| 节点 | `TenseiNode1`（单节点） | `NodeName` |
| 队列 | `gpu`，默认队列 | `PartitionName ... Default=YES` |
| GPU | 8 张 A100，**整卡独占** | `Gres=gpu:a100:8` + `gres.conf` |
| 单任务 GPU 上限 | 8 张（未额外限制） | — |
| CPU | 128 个逻辑 CPU，按核分配 | `CPUs=128`、`CR_CPU_Memory` |
| 可调度内存 | `2,000,000 MiB`（系统预留约 62 GiB） | `RealMemory=2000000` |
| 默认内存 | 每个 CPU `4096 MiB` | `DefMemPerCPU=4096` |
| 默认时限 | **1 小时** | `DefaultTime=01:00:00` |
| 最长时限 | **7 天**，到时终止 | `MaxTime=7-00:00:00` |
| 调度算法 | **Backfill（回填）** | `SchedulerType=sched/backfill` |
| 资源选择 | 按 CPU + 内存跟踪 | `SelectType=select/cons_tres` |
| 超额分配 | 禁止 | `OverSubscribe=NO` |
| 任务隔离 | CPU / 内存 / 设备三重约束 | `cgroup.conf` |
| 自动恢复 | 节点故障后自动恢复服务 | `ReturnToService=2` |

### 设计取舍说明

**整卡独占。** 一个任务拿到一张 A100 的全部 80 GB 显存。
在只有一台八卡机的规模下，这是最简单也最不容易出错的模型。

**`RealMemory` 从实测值下调了约 62 GiB。** `slurmd -C` 实测 `RealMemory=2063878`，
配置里写成 `2000000`，把这 62 GiB 留给操作系统、`slurmd` 自身、文件系统缓存
和监控组件。**把内存全部划给任务会导致节点在压力下 OOM 甚至失联。**

**默认时限只有 1 小时，但最长允许 7 天。** 默认值偏小是为了让「忘记写 `--time`」
的任务不会长期占卡；真正需要长跑的用户会显式写 `--time`，这是有意为之的摩擦。

**调度算法启用 Backfill（回填）。** 它允许短任务插空档，能显著提高八卡机的利用率。
它对用户侧的直接要求是：**如实申报 `--time`**。虚报时长的任务会被排到最后。

## 关键配置解析

### `slurm.conf`

```bash
ClusterName=tensei
SlurmctldHost=TenseiNode1
SlurmUser=slurm
AuthType=auth/munge
CredType=cred/munge

StateSaveLocation=/var/spool/slurmctld
SlurmdSpoolDir=/var/spool/slurmd
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_CPU_Memory

ProctrackType=proctrack/cgroup
TaskPlugin=task/cgroup,task/affinity
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30
ReturnToService=2

GresTypes=gpu
NodeName=TenseiNode1 CPUs=128 Boards=1 SocketsPerBoard=2 CoresPerSocket=32 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:a100:8 State=UNKNOWN
PartitionName=gpu Nodes=TenseiNode1 Default=YES DefaultTime=01:00:00 MaxTime=7-00:00:00 DefMemPerCPU=4096 OverSubscribe=NO State=UP
```

| 配置项 | 为什么这样设 |
|---|---|
| `SchedulerType=sched/backfill` | 允许短任务利用资源空档，提高利用率 |
| `SelectType=select/cons_tres` | 消费型资源（GPU/CPU/内存）跟踪，GPU 调度的前提 |
| `SelectTypeParameters=CR_CPU_Memory` | 同时按 CPU 和内存计算可分配量，避免只按 CPU 分配导致内存超卖 |
| `ProctrackType=proctrack/cgroup` | 用 cgroup 追踪进程，任务结束能可靠清理所有子进程 |
| `TaskPlugin=task/cgroup,task/affinity` | 限制任务可见的设备与 CPU 亲和性 |
| `JobAcctGatherType=jobacct_gather/cgroup` | 从 cgroup 采集内存峰值等用量数据 |
| `ReturnToService=2` | 节点临时故障后，`slurmd` 一恢复就自动回到可用状态 |
| `OverSubscribe=NO` | 禁止 CPU 超额分配，保证任务拿到承诺的核数 |

!!! warning "`RealMemory` 不要照抄实测值"
    `slurmd -C` 报的是**物理内存**。直接写进去会让节点在高负载时 OOM。
    建议按「物理内存 − 8% ~ 10%」设置。

### `gres.conf`：GPU 资源定义

```bash
AutoDetect=nvidia
Name=gpu Type=a100 File=/dev/nvidia[0-7]
```

* `AutoDetect=nvidia`：由 `slurmd` 通过 NVML 自动发现 8 张卡。
* `Type=a100`：给资源加类型标签。当前用户统一用 `--gres=gpu:N`，
  也可以写 `--gres=gpu:a100:N`，两者等价。
* `File=/dev/nvidia[0-7]`：把 GRES 与具体设备节点绑定，
  这是 `task/cgroup` 能把任务限制到指定几张卡的基础。

验证 GPU 资源是否被正确识别：

```bash
slurmd -G          # 应列出 8 条 Gres，Index=0..7
slurmd -C          # 节点 CPU / 内存 / GPU 汇总
sinfo -o "%N %G %C %m %t"
scontrol show node TenseiNode1 | grep -E 'Gres|RealMemory|AllocTRES'
```

### `cgroup.conf`：任务级隔离

```bash
CgroupPlugin=cgroup/v2
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes
```

| 配置项 | 作用 | 不配的后果 |
|---|---|---|
| `CgroupPlugin=cgroup/v2` | 使用 cgroup v2（Ubuntu 22.04 默认） | 老版本 Slurm 21.08 不支持，会退回到 cgroup v1 |
| `ConstrainCores=yes` | 限制任务只能用分配的 CPU 核 | 任务能用满 128 核，调度记录失真 |
| `ConstrainRAMSpace=yes` | 限制任务只能用申请的内存 | 一个任务吃掉 2 TiB，节点 OOM |
| `ConstrainDevices=yes` | 限制任务只能访问分配的 GPU 设备 | **任务能看到全部 8 张卡**，`--gres` 形同虚设 |

!!! danger "`ConstrainDevices=yes` 是 GPU 隔离的核心"
    没有这一行，`--gres=gpu:1` 只是「告诉调度器我用了 1 张卡」，
    程序实际上仍然能看到全部 8 张卡并直接占用。
    这一行让限制落到内核设备访问控制上，用户无法绕过。

## 当前**没有**启用的策略

以下功能在这个集群上**尚未配置**。做容量规划或向用户承诺时不要假设它们存在。

| 功能 | 现状 | 影响 |
|---|---|---|
| **每用户 GPU 上限** | 未设置 | 一个用户可以同时申请全部 8 张卡 |
| **公平份额（Fair-share）** | 未启用 | 优先级不随历史用量衰减，先到先得 |
| **抢占（Preemption）** | 未配置 | 大任务排队时不会被小任务插队挤掉 |
| **QoS 分级** | 未创建 | 所有任务都用内置 `normal`，无法区分优先级 |
| **显存配额** | 未配置 | 显存不受 `--mem` 限制 |
| **并发任务数上限** | 未设置 | 用户可以提交任意多任务 |
| `AccountingStorageEnforce` | 未启用 | **未注册用户仍可提交任务**，注册只影响记账归属 |

## 修改策略的标准流程

!!! danger "改配置前必须备份"
    ```bash
    cp -a /etc/slurm/slurm.conf \
      "/root/slurm.conf.bak-$(date +%Y%m%d-%H%M%S)"
    ```

### 能热加载的参数

`SchedulerType`、`PartitionName`、`DefMemPerCPU`、`MaxTime`、QOS 等
**可以不停服务生效**：

```bash
# 1. 校验语法（-C 只检查，不启动）
slurmctld -C

# 2. 让控制器重读配置
systemctl reload slurmctld
# 等价于：scontrol reconfigure

# 3. 确认生效
scontrol show partition gpu
scontrol show config | grep -E 'SchedulerType|PriorityType'
```

!!! tip "`systemctl reload slurmctld` 不影响正在运行的任务"
    它只让控制器重读配置。任务的资源分配保持不变，
    新的参数从下一次调度开始起作用。

### 必须重启的参数

改 `ClusterName`、`SlurmctldHost`、`StateSaveLocation`、`AuthType`
这类涉及身份和状态的参数时需要重启：

```bash
systemctl restart slurmctld
systemctl restart slurmd
systemctl is-active slurmctld slurmd
sinfo
```

!!! danger "改了 `ClusterName` 会导致状态不匹配"
    控制器状态文件里记录了集群 ID。改集群名后启动会报
    `CLUSTER ID MISMATCH`。处理方式见[记账与用量统计](accounting.md#故障处理cluster-id-mismatch)。

### 节点侧的配置同步

改了 `gres.conf` 或 `cgroup.conf` 后要重启 `slurmd`：

```bash
systemctl restart slurmd
scontrol show node TenseiNode1 | grep -E 'Gres|State'
```

如果节点状态卡在 `down` / `drain`，恢复方式：

```bash
scontrol update NodeName=TenseiNode1 State=RESUME
```

## 策略变更检查清单

修改任何调度策略前后，按这个清单逐项确认：

- [ ] 已备份 `/etc/slurm/slurm.conf`
- [ ] `slurmctld -C` 语法检查通过
- [ ] 变更内容记录到文档或变更日志
- [ ] `systemctl reload slurmctld` 后 `sinfo` 正常
- [ ] 用一个普通用户实测提交任务成功
- [ ] 验证资源限制真的生效（申请 1 张卡时看不到其余卡）
- [ ] 确认没有影响正在运行的任务

```bash
# 变更后的验收命令
sinfo
scontrol show partition gpu
scontrol show node TenseiNode1
systemctl is-active slurmctld slurmd slurmdbd

# 以普通用户身份验证（在服务器上以 root 执行）
runuser -l chao -c \
  'srun --immediate=10 -A research -p gpu -N1 -n1 --gres=gpu:1 \
        --cpus-per-task=1 --mem=1G --time=00:01:00 \
        bash -c "cat /proc/self/cgroup; nvidia-smi -L"'
```

预期：只列出一张 A100，且 cgroup 路径属于 Slurm 作业（不是 `user-1000.slice`）。

## 相关文档

* [部署 Slurm 集群](slurm-deploy.md) —— 上述配置从零搭建的完整过程
* [记账与用量统计](accounting.md) —— `sacctmgr` 账户、账户关联与历史查询
* [访问入口与安全加固](access-security.md) —— 如何让用户无法绕过调度器
