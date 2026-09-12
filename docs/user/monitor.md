# 用量查询与监控

集群提供两种查看方式：**命令行**（精确、可脚本化）和 **Grafana 看板**（直观、看趋势）。

| 我想知道 | 用什么 |
|---|---|
| 现在有哪些任务在跑 / 排队 | `squeue` |
| 我的任务为什么排队 | `scontrol show job` |
| 还有几张卡空着 | `scontrol show node` |
| 我这个月用了多少卡时 | `sacct` 或 Grafana |
| 每张卡的实时利用率 | Grafana 实时监控看板 |
| 某张卡现在是谁在用 | Grafana 用户与任务看板 |

## 命令行查询

### 看队列：`squeue`

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

### 看我排第几：`scontrol show job`

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

### 看还有几张卡空着

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

### 查历史用量：`sacct`

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

### 用量统计

```bash
# 本月每天的任务数
sacct -u "$USER" -S 2026-09-01 -X --format=JobID,Elapsed,AllocTRES%40 \
  | grep -c 'gres/gpu'

# 今天用了几张卡、多久（人工看 AllocTRES 与 Elapsed）
sacct -u "$USER" -S today -X --format=JobID,JobName,Elapsed,AllocTRES%40
```

!!! note "命令行没有直接的「卡时汇总」"
    Slurm 的 `sreport` 可以做汇总报表，但**本集群的日常做法是看 Grafana 看板**，
    它按用户和时间范围直接给出 GPU 卡时。

## Grafana 看板

### 访问方式

Grafana 只监听服务器本机，需要通过 SSH 隧道访问：

```bash
ssh -N -L 3000:127.0.0.1:3000 zhangsan@SERVER_IP
```

然后浏览器打开 **<http://localhost:3000>**。

!!! warning "Grafana 账号和 Linux 账号是两套"
    SSH 能登录不代表能登录 Grafana。需要看板权限请联系管理员开通。

    Xshell 用户可以在 **属性 → 连接 → SSH → 隧道** 里配置，
    详见[访问集群](access.md#通过-ssh-隧道访问监控页面)。

### 三个看板

| 看板 | 看什么 | 刷新 |
|---|---|---|
| **Tensei GPU 使用统计** | 任务明细 + 按用户统计的 GPU 卡时 | 30 秒 |
| **Tensei GPU 实时监控** | 每张卡的利用率、显存、温度、功耗曲线 | 15 秒 |
| **Tensei GPU 用户与任务** | 当前每张卡分配给了谁、跑什么任务 | 15 秒 |

**Tensei GPU 使用统计**包含两张表：

* **任务明细**：所选时间范围内的任务，含任务号、用户、账户、任务名、
  状态（排队/运行中/完成/失败/超时…）、分配 GPU 数、提交/开始/结束时间、节点。
* **各用户 GPU 分配卡时**：横向柱状图，直接看谁用了多少卡时。

**Tensei GPU 用户与任务**是排查「卡被谁占着」最快的入口：

| GPU | 用户 | 任务号 | 任务名 | 分配状态 | 利用率 | 显存 |
|---|---|---|---|---|---|---|
| 0 | zhangsan | 123 | train | RUNNING | 87% | 42 GiB |
| 1 | — | — | — | UNALLOCATED | 0% | 0 GiB |
| 2 | lisi | 124 | sweep | RUNNING | 3% | 8 GiB |

!!! tip "这张表能回答「为什么我申请不到卡」"
    如果 8 行都显示某个用户的任务，说明卡确实被占满了。
    如果显示 `UNALLOCATED` 但你还是申请不到，
    那可能是 CPU 或内存不足，去看 `scontrol show job` 的 `Reason`。

## 正确理解这些数字

!!! danger "GPU 卡时 ≠ 计算量"
    **GPU 卡时 = 分配卡数 × 分配小时数。**

    「2 张卡跑了 3 小时」= 6 卡时。但这一小时里卡可能是闲着的。
    分配了 8 小时、利用率只有 5% 的任务，照样计 8 卡时。

    做资源规划或汇报时**不要把它当成算力消耗**。

!!! warning "利用率 0% 不代表卡没被分配"
    用户申请了卡但在读数据、调试、等 IO 时，利用率就是 0%。
    反过来，利用率高也不一定代表卡被 Slurm 分配了（可能有绕过调度器的进程）。

    判断「卡有没有被分配」要看**分配状态**，不是看利用率。

!!! warning "「Slurm 未分配」不代表一定没人用"
    当前监控显示的是 **Slurm 分配归属**，不是进程归属。
    如果有程序绕过调度器直接占卡，它的用户和任务不会显示出来
    （但它的利用率会计入整卡数值）。

    这也是为什么集群对普通用户禁用了直接访问 GPU —— 保证
    「看到的占用」等于「真实的占用」。

!!! note "时间范围与保留期"
    | 数据 | 保留 |
    |---|---|
    | 实时指标（Prometheus） | **30 天** |
    | 记账记录（Slurm 数据库） | 长期保留 |

    所以「图表上看不到上个月的数据」是正常的，
    但 `sacct` 和「GPU 使用统计」看板仍能查到更早的记录。

!!! note "采集失败时显示缺失值"
    如果监控组件故障，看板会显示**缺失**而不是「空闲」。
    这是刻意设计的 —— 避免把「采集挂了」误读成「卡没人用」。

## 定期自查建议

| 频率 | 做什么 |
|---|---|
| 提交任务前 | `scontrol show node TenseiNode1 \| grep GresUsed` 看空卡 |
| 任务运行中 | `squeue -u "$USER"` + 看板确认利用率是否正常 |
| 每周 | `sacct -u "$USER" -S now-7days -X` 回顾用量与失败任务 |
| 每月 | 看板的「GPU 分配卡时」确认用量趋势 |

!!! tip "发现自己的任务利用率异常低"
    先检查数据加载是否成为瓶颈，见
    [GPU 训练实战](gpu-training.md#性能排查)。
    低利用率的任务既浪费自己的配额，也占着别人需要的卡。

## 相关文档

* [Slurm 任务调度](slurm.md) —— 提交参数与排队规则
* [GPU 训练实战](gpu-training.md) —— 提高利用率的方法
* [常见问题](faq.md) —— 报错处理
* [访问集群](access.md#通过-ssh-隧道访问监控页面) —— SSH 隧道配置
