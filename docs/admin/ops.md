# 备份、扩容与日常运维

## 备份

!!! danger "记账数据不可再生"
    Slurm 配置可以从文档重建，软件包可以重新编译，
    但**历史作业记录一旦丢失就无法恢复** —— 谁在什么时候用了多少卡，
    这些数据没有第二个来源。

### 需要备份什么

| 内容 | 位置 | 可再生 | 工具 |
|---|---|---|---|
| **记账数据库** | `slurm_acct_db` | ❌ | `mariadb-dump` |
| **MariaDB 账号** | `mysql` 系统库 | ⚠️ 可重建但麻烦 | `mariadb-dump` |
| **Slurm 配置** | `/etc/slurm/` | ⚠️ 可重建 | `tar` |
| **控制器状态** | `/var/spool/slurmctld/` | ❌ 排队作业会丢 | `tar` |
| **Grafana 看板** | Grafana 数据库 | ❌ 需手工导出 JSON | UI 导出 |
| **Grafana 数据源** | `/etc/grafana/provisioning/` | ✅ | `tar` |
| **安装包** | `/root/slurm-packages/25.11.8/` | ⚠️ 可重编译 | `tar` |

!!! warning "只备份 `slurm_acct_db` 会漏掉数据库账号"
    恢复到一个干净的 MariaDB 后，你会发现 `slurm_acct` 和 `grafana_slurm`
    这两个账号不存在，`slurmdbd` 连不上库。
    要么连 `mysql` 库一起备份，要么在恢复脚本里重建账号。

### 备份脚本

```bash
#!/bin/bash
# /usr/local/sbin/tensei-backup.sh
set -Eeuo pipefail

backup_root=/root/backup
stamp=$(date +%Y%m%d-%H%M%S)
target="$backup_root/$stamp"

mkdir -p "$target"
chmod 700 "$backup_root" "$target"

echo "==> 备份记账数据库"
mariadb-dump --single-transaction --routines --events \
  slurm_acct_db | gzip > "$target/slurm_acct_db.sql.gz"

echo "==> 备份 MariaDB 账号与权限"
mariadb-dump --single-transaction --system=users \
  mysql 2>/dev/null | gzip > "$target/mysql_users.sql.gz" || \
  echo "  (跳过系统库，改用恢复脚本重建账号)"

echo "==> 备份 Slurm 配置"
tar -czf "$target/slurm-etc.tar.gz" -C / etc/slurm

echo "==> 备份控制器状态"
systemctl stop slurmctld
tar -czf "$target/slurm-state.tar.gz" -C /var/spool slurmctld
systemctl start slurmctld

echo "==> 备份监控配置"
tar -czf "$target/monitoring.tar.gz" \
  -C / etc/prometheus etc/grafana/provisioning etc/dcgm-exporter \
  opt/slurm-gpu-exporter 2>/dev/null || true

echo "==> 备份安装包"
tar -czf "$target/slurm-packages.tar.gz" \
  -C /root slurm-packages 2>/dev/null || true

chmod 600 "$target"/*
du -sh "$target"
echo "备份完成：$target"
```

!!! danger "备份控制器状态需要短暂停服务"
    `/var/spool/slurmctld` 在服务运行时持续变化，
    直接打包可能得到不一致的快照。
    脚本会停 `slurmctld` 几秒钟 —— **正在运行的任务不受影响**，
    但期间无法提交新任务。建议在低峰期执行。

### 定时执行

```bash
cat > /etc/cron.d/tensei-backup <<'EOF'
# 每天凌晨 3 点备份集群
0 3 * * * root /usr/local/sbin/tensei-backup.sh >> /var/log/tensei-backup.log 2>&1
EOF
```

!!! tip "本地备份不算备份"
    同一块磁盘上的备份，在磁盘故障时一起消失。
    至少把 `$target` 同步到**另一台机器**或对象存储：

    ```bash
    rsync -az --delete /root/backup/ backup-host:/srv/tensei-backup/
    ```

### 恢复演练

!!! danger "没演练过的备份等于没有备份"
    建议每季度做一次恢复演练，在测试环境验证流程可用。

```bash
# 1. 恢复数据库
gunzip < /root/backup/<stamp>/slurm_acct_db.sql.gz | mariadb slurm_acct_db

# 2. 恢复账号（如果没有备份系统库，手工重建）
mariadb <<'SQL'
CREATE USER IF NOT EXISTS 'slurm_acct'@'localhost' IDENTIFIED BY '<原密码>';
GRANT ALL PRIVILEGES ON slurm_acct_db.* TO 'slurm_acct'@'localhost';
CREATE USER IF NOT EXISTS 'grafana_slurm'@'127.0.0.1' IDENTIFIED BY '<原密码>';
GRANT SELECT ON slurm_acct_db.* TO 'grafana_slurm'@'127.0.0.1';
SQL

# 3. 恢复配置
tar -xzf /root/backup/<stamp>/slurm-etc.tar.gz -C /

# 4. 恢复控制器状态（必须先停服务）
systemctl stop slurmctld
tar -xzf /root/backup/<stamp>/slurm-state.tar.gz -C /var/spool
chown -R slurm:slurm /var/spool/slurmctld
systemctl start slurmctld

# 5. 验证
systemctl is-active slurmctld slurmd slurmdbd mariadb
sinfo
sacct -a -S today -X --format=JobID,User,State,Elapsed
```

!!! danger "恢复状态后注意集群 ID"
    如果恢复到的是一个**新建的**记账数据库，
    可能再次触发 [`CLUSTER ID MISMATCH`](accounting.md#故障处理cluster-id-mismatch)。
    按该节的流程处理。

### 导出 Grafana 看板

看板只存在 Grafana 的数据库里，`/etc/grafana` 里没有。

**方式一（UI）**：Dashboard → **Share** → **Export** → 保存 JSON。

**方式二（API）**：

```bash
# 列出所有看板
curl --noproxy '*' -u admin:<密码> \
  http://127.0.0.1:3000/api/search?type=dash-db

# 导出某个看板
curl --noproxy '*' -u admin:<密码> \
  http://127.0.0.1:3000/api/dashboards/uid/<uid> \
  > /root/backup/grafana-dashboard-<uid>.json
```

!!! tip "长期方案：改成 provisioning 管理"
    把导出的 JSON 放进 `/etc/grafana/provisioning/dashboards/`，
    看板就变成文件、可版本控制、随配置一起备份。
    代价是不能再在 UI 里直接改（改动会被覆盖）。

## 日常运维

### 每日检查

```bash
#!/bin/bash
# 快速健康检查
echo "== 服务 =="
systemctl is-active slurmctld slurmd slurmdbd mariadb \
  prometheus dcgm-exporter slurm-gpu-exporter grafana-server

echo "== 节点 =="
sinfo

echo "== 队列 =="
squeue -o "%.8i %.12u %.18j %.10T %.10M %.10l %.20b %R"

echo "== GPU 采集 =="
curl --noproxy '*' -fsSG http://127.0.0.1:9091/api/v1/query \
  --data-urlencode 'query=count(DCGM_FI_DEV_GPU_UTIL{job="dcgm"})' \
  | grep -o '"value":\[[^]]*\]'

echo "== 磁盘 =="
df -h / /home /var 2>/dev/null | grep -v tmpfs

echo "== 数据库大小 =="
mariadb -N -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB
  FROM information_schema.tables WHERE table_schema='slurm_acct_db' GROUP BY table_schema;"
```

!!! danger "最现实的故障是磁盘写满"
    `/var` 写满会让 MariaDB 无法写入、`slurmctld` 无法保存状态；
    `/home` 写满会影响用户。
    **每次检查都看 `df -h`，并为根分区配置告警阈值。**

### 日志位置

| 路径 | 内容 |
|---|---|
| `/var/log/slurm/slurmctld.log` | 控制器：调度决策、作业事件 |
| `/var/log/slurm/slurmd.log` | 计算节点：任务启动、cgroup |
| `/var/log/slurm/slurmdbd.log` | 记账：数据库写入、连接问题 |
| `/var/log/tensei-backup.log` | 备份脚本输出 |

```bash
journalctl -u slurmctld -u slurmd --since today -f
tail -F /var/log/slurm/slurmctld.log /var/log/slurm/slurmd.log
```

### 日志轮转

Slurm 自身不轮转日志，靠系统的 `logrotate`。确认配置存在：

```bash
cat > /etc/logrotate.d/slurm <<'EOF'
/var/log/slurm/*.log {
    weekly
    rotate 8
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    su slurm slurm
}
EOF
```

!!! note "`copytruncate` 避免重启服务"
    默认的轮转方式需要服务重新打开日志文件。
    `copytruncate` 直接截断原文件，配合 `su slurm slurm` 保证权限正确。

### 节点维护

```bash
# 1. 让节点不再接受新任务（已运行的继续跑）
scontrol update NodeName=TenseiNode1 State=DRAIN Reason="维护：更换网卡"

# 2. 等任务跑完
squeue -w TenseiNode1

# 3. 停服务、维护
systemctl stop slurmd

# 4. 维护完成，恢复
systemctl start slurmd
scontrol update NodeName=TenseiNode1 State=RESUME
sinfo
```

!!! tip "先 `DRAIN` 再停机"
    直接停 `slurmd` 会让正在运行的任务异常退出。
    `DRAIN` 让节点停止接收新任务，但已运行的任务正常跑完。

## 扩展到多节点

### 演进路径

| 阶段 | 规模 | 架构 |
|---|---|---|
| 现在 | 1 台 | 控制 + 计算 + 记账 + 监控 全在一台 |
| 阶段二 | 2～3 台 | 控制与记账仍在第一台，其余运行 `slurmd` |
| 阶段三 | 4～5 台 | 独立管理/登录节点；计算节点只跑 `slurmd` |

!!! note "控制服务与计算共机在单节点阶段完全可行"
    不必为了「架构正确」提前拆分。等到第二步再加节点时再考虑。

### 新节点接入清单

**1. 基础环境必须完全一致**

| 项目 | 要求 | 检查命令 |
|---|---|---|
| 操作系统版本 | 一致 | `cat /etc/os-release` |
| **NVIDIA 驱动 + Fabric Manager** | **版本完全一致** | `nvidia-smi`、`systemctl status nvidia-fabricmanager` |
| **MUNGE key** | **所有节点完全相同** | `munge -n \| unmunge` |
| **UID / GID** | 同一用户在所有节点 UID 相同 | `id <用户名>` |
| 主机名解析 | 所有节点能互相解析 | `getent hosts <节点名>` |
| 共享存储 | `/home` 通过 NFS 等共享 | `df -h /home` |
| cgroup 模式 | 一致 | `stat -fc %T /sys/fs/cgroup` |

!!! danger "UID 不一致是最隐蔽的问题"
    用户 `chao` 在 A 机器是 UID 1000、在 B 机器是 UID 1002，
    那么在共享 `/home` 上他会看到「自己的文件属于别人」，
    甚至无法读写自己的文件。**扩节点前先统一 UID/GID。**

**2. 在新节点安装 Slurm**（复用已构建的包）：

```bash
scp /root/slurm-packages/25.11.8/slurm-smd*.deb newnode:/root/

# 在新节点上
apt-get install /root/slurm-smd_25.11.8-1_amd64.deb \
                /root/slurm-smd-client_25.11.8-1_amd64.deb \
                /root/slurm-smd-slurmd_25.11.8-1_amd64.deb

# 拷贝 MUNGE key
scp /etc/munge/munge.key newnode:/etc/munge/munge.key
ssh newnode 'chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && systemctl restart munge'
```

**3. 在 `slurm.conf` 中登记**：

```bash
NodeName=TenseiNode1 CPUs=128 Boards=1 SocketsPerBoard=2 CoresPerSocket=32 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:a100:8 State=UNKNOWN
NodeName=TenseiNode2 CPUs=128 Boards=1 SocketsPerBoard=2 CoresPerSocket=32 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:a100:8 State=UNKNOWN

PartitionName=gpu Nodes=TenseiNode1,TenseiNode2 Default=YES DefaultTime=01:00:00 MaxTime=7-00:00:00 DefMemPerCPU=4096 OverSubscribe=NO State=UP
```

**4. 分发配置并重载**：

```bash
# 所有节点的 slurm.conf / gres.conf / cgroup.conf 必须一致
for n in TenseiNode2; do
  scp /etc/slurm/{slurm.conf,gres.conf,cgroup.conf} "$n":/etc/slurm/
  ssh "$n" 'systemctl restart slurmd'
done

systemctl reload slurmctld
sinfo
```

**5. 多机训练还要单独验证**：

!!! danger "Slurm 装好 ≠ 多机训练能跑"
    Slurm 只负责分配多机资源。跨机通信还依赖机间网络、RDMA 驱动与 NCCL。
    多台 A100 的显存**不会自动合并**成一块。

```bash
# GPU 拓扑与网卡对应关系（每台都跑）
nvidia-smi topo -m
ibstat

# 双机通信测试：申请两台各 1 张卡跑 all_reduce
srun -N 2 --ntasks-per-node=1 --gres=gpu:1 \
     --time=00:10:00 \
     bash -c 'hostname; nvidia-smi -L'
```

**先做双机测试，再扩到更多节点**，确认联合运行真的提升吞吐。

## 待办清单

| 优先级 | 事项 | 具体动作 |
|---|---|---|
| **高** | 备份与恢复 | 部署 `tensei-backup.sh` + 定时任务 + 异地同步；做一次恢复演练 |
| **高** | 主机监控与磁盘告警 | `apt-get install prometheus-node-exporter`，加磁盘阈值告警 |
| **中** | 每用户资源上限 | 用 QOS 设置 `MaxTRESPerUser=gres/gpu=4`、`MaxJobsPerUser` |
| **中** | 公平份额 | 启用 `priority/multifactor` + `PriorityDecayHalfLife` |
| **中** | 邮件通知 | 装 `msmtp-mta` 或指定 `MailProg` |
| **低** | 看板 provisioning | 导出 JSON 到 `/etc/grafana/provisioning/dashboards/` |
| **低** | 记账数据归档 | `tensei_job_table` 会持续增长，制定归档策略 |
| **低** | Ansible | 多节点后用于用户创建与配置分发 |
| **低** | 重新评估 OOD | 需要网页提交任务时再启用 |

!!! tip "优先做前三项"
    备份、磁盘告警、每用户配额 —— 这三项直接决定
    「集群能不能安全地开放给更多人用」。
    其余都是体验优化。

## 相关文档

* [记账与用量统计](accounting.md) —— 数据库备份细节与只读账号
* [调度策略与配额](policy.md) —— QOS 与公平份额的配置方法
* [访问入口与安全加固](access-security.md) —— 每月安全复查
* [监控与可视化](monitoring.md) —— 磁盘与主机指标
