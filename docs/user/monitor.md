# 用量查询

用 Slurm 命令查询集群的实时状态和历史用量。全部在登录终端里执行，不需要额外工具。

| 我想知道 | 用什么 |
|---|---|
| 现在有哪些任务在跑 / 排队 | `squeue` |
| 我的任务为什么排队 | `scontrol show job` |
| 还有几张卡空着 | `scontrol show node` |
| 我这个月用了多少卡时 | `sacct` |

## 看队列：`squeue`

```bash
squeue -u "$USER"
```

```text
JOBID PARTITION     NAME     USER ST       TIME  NODES NODELIST(REASON)
  123       gpu   train   zhangsan  R    1:23:45      1 TenseiNode1
  124       gpu  sweep   zhangsan PD       0:00      1 (Resources)
```

| 字段 | 含义 |
|---|---|
| `ST` | `R` 运行中，`PD` 排队中，`CG` 收尾中 |
| `TIME` | 已运行时长 |
| `NODES` | 使用节点数 |
| `NODELIST(REASON)` | 运行中显示节点；排队时显示**排队原因** |

!!! tip "看全部人的任务（不只是自己的）"
    ```bash
    # 所有任务，带申请的资源数量
    squeue -o "%.8i %.12u %.18j %.10T %.10M %.10l %.20b %R"

    # 只看排队中的
    squeue -t PENDING

    # 实时刷新，每 5 秒
    watch -n 5 'squeue -o "%.8i %.12u %.18j %.10T %.10M %.20b %R"'
    ```

    `%.20b` 这一列显示每节点申请的资源，例如 `gres/gpu:2`。

## 看我排第几：`scontrol show job`

```bash
scontrol show job 124
```

重点字段：

| 字段 | 含义 |
|---|---|
| `JobState` | 任务状态 |
| `Reason` | **排队原因**，最重要 |
| `Priority` | 优先级数值，越大越靠前 |
| `RunTime` / `TimeLimit` | 已运行 / 时限 |
| `ReqTRES` / `AllocTRES` | 申请 / 实际分配的资源 |
| `WorkDir` | 任务的工作目录 |
| `StdOut` / `StdErr` | 输出文件路径 |
| `Command` | 实际执行的命令 |

### 排队原因对照表

| `REASON` | 含义 | 能做什么 |
|---|---|---|
| `Resources` | 卡或 CPU、内存被占满 | 正常等待；或减少申请量、缩短 `--time` |
| `Priority` | 优先级不够，前面有更高优先级的任务 | 正常等待 |
| `QOSMaxJobsPerUserLimit` | 达到个人并发任务上限 | 等自己的任务结束 |
| `AssocGrpGRESMinutesLimit` | 达到账户 GPU 卡时上限 | 等配额恢复 |
| `AssocMaxJobsLimit` | 达到账户任务数上限 | 等或联系管理员 |
| `ReqNodeNotAvail` | 节点不可用或在维护 | 联系管理员 |
| `Dependency` | 在等依赖的任务 | 正常 |
| `JobHeldUser` | 任务被自己挂起 | `scontrol release <JOBID>` |
| `BadConstraints` | 申请的资源配置不存在 | 检查 `--gres` / `--mem` / `--cpus-per-task` |

!!! tip "`Resources` 排队时，先看是不是自己申请太多了"
    ```bash
    scontrol show node TenseiNode1 | grep -iE 'gres|cpu|mem'
    ```
    如果只申请 1 张卡的任务也要排很久，可能是内存或 CPU 申请超了节点剩余量。

## 看还有几张卡空着

```bash
scontrol show node TenseiNode1
```

重点看 `GresUsed` 字段：

```text
Gres=gpu:a100:8
GresUsed=gpu:a100:3(IDX:0,2,5)
```

这表示 8 张卡里，**0、2、5 号卡被占用**，其余 5 张空闲。

也可以用简表：

```bash
sinfo -o "%N %G %C %m %t"
```

| 字段 | 含义 |
|---|---|
| `%N` | 节点名 |
| `%G` | GPU 资源总量 |
| `%C` | CPU 已用/空闲/其他/总数 |
| `%m` | 内存（MiB） |
| `%t` | 节点状态 |

!!! warning "节点状态 `mixed` 不代表有空卡"
    `mixed` 只说明「有部分资源被占用」，可能是 CPU 或内存被占，
    **GPU 可能已经全部分配出去了**。
    判断空卡要看 `GresUsed`。

## 查历史用量：`sacct`

!!! info "任务结束后 `squeue` 里就查不到了"
    想知道「上周跑了多久」必须用 `sacct`，它读的是记账数据库。

```bash
# 我今天的所有任务
sacct -u "$USER" -S today -X \
  --format=JobID,JobName,State,Start,Elapsed,AllocTRES%50

# 最近 7 天
sacct -u "$USER" -S now-7days -X \
  --format=JobID,JobName,State,Elapsed,AllocTRES%50

# 某个任务详情
sacct -j 123 --format=JobID,JobName,State,ExitCode,Elapsed,MaxRSS,AllocTRES

# 指定日期范围
sacct -u "$USER" -S 2026-09-01 -E 2026-09-30 -X \
  --format=JobID,JobName,State,Elapsed,AllocTRES%50
```

| 字段 | 含义 |
|---|---|
| `State` | `COMPLETED` 成功，`FAILED` 失败，`CANCELLED` 取消，`TIMEOUT` 超时 |
| `ExitCode` | 退出码，`0:0` 表示正常 |
| `Elapsed` | 实际占用时长 |
| `AllocTRES` | 分配的资源，`gres/gpu=2` 表示 2 张卡 |
| `MaxRSS` | 峰值主机内存 |

!!! tip "`-X` 是干什么的"
    不加 `-X` 会看到 `123`、`123.batch`、`123.extern` 等多行 ——
    它们是同一任务的内部步骤。`-X` 只显示主记录，列表干净很多。

!!! warning "任务被杀了，日志里没报错？"
    先看 `sacct` 的 `State`：

    ```bash
    sacct -j 123 --format=JobID,JobName,State,ExitCode,Elapsed,TimeLimit
    ```

    * `TIMEOUT` → 超出 `--time`
    * `OUT_OF_MEMORY` → 主机内存不足，调大 `--mem`
    * `NODE_FAIL` → 节点故障，联系管理员
    * `CANCELLED` → 被取消（自己或管理员）

## 用量统计

```bash
# 本月提交了多少个用卡任务
sacct -u "$USER" -S 2026-09-01 -X --format=JobID,Elapsed,AllocTRES%40 \
  | grep -c 'gres/gpu'

# 今天用了几张卡、多久（人工看 AllocTRES 与 Elapsed）
sacct -u "$USER" -S today -X --format=JobID,JobName,Elapsed,AllocTRES%40
```

!!! note "命令行没有直接的「卡时汇总」"
    把每行的「分配卡数 × 已运行时长」加起来就是卡时，需要自己算。
    需要成规模的用量统计请联系管理员。

## 正确理解这些数字

!!! danger "GPU 卡时 ≠ 计算量"
    **GPU 卡时 = 分配卡数 × 分配小时数。**

    「2 张卡跑了 3 小时」= 6 卡时。但这一小时里卡可能是闲着的。
    分配了 8 小时、利用率只有 5% 的任务，照样计 8 卡时。

    做资源规划或汇报时**不要把它当成算力消耗**。

!!! warning "`AllocTRES` 显示的是分配量"
    它记录「分配了几张卡、用了多久」，不反映这段时间里卡忙不忙。
    想知道利用率要看实际训练日志或联系管理员。

## 定期自查建议

| 频率 | 做什么 |
|---|---|
| 提交任务前 | `scontrol show node TenseiNode1 \| grep GresUsed` 看空卡 |
| 任务运行中 | `squeue -u "$USER"` 确认状态 |
| 每周 | `sacct -u "$USER" -S now-7days -X` 回顾用量与失败任务 |
| 每月 | 汇总卡时，确认用量趋势 |

!!! tip "失败的比成功的多？"
    用 `sacct` 看 `State` 分布，对失败任务逐个查 `.err` 日志。
    常见原因是超时、内存不足和环境没激活，见[常见问题](faq.md)。

## 相关文档

* [Slurm 任务调度](slurm.md) —— 提交参数与排队规则
* [GPU 训练实战](gpu-training.md) —— 提高利用率的方法
* [常见问题](faq.md) —— 报错处理
