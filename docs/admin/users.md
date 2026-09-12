# 用户与账号管理

开一个账号需要做四件事，**漏掉任何一件都会留下隐患**：

| 步骤 | 漏掉的后果 |
|---|---|
| 1. 创建 Linux 账号 | — |
| 2. 加入 Slurm 记账账户 | 用量统计不到这个人 |
| 3. **下发 GPU 设备限制** | **新账号可以直接占卡，绕过调度器** |
| 4. 设置初始密码并强制首登修改 | 密码长期不变 |

手工执行四次容易漏，所以做成了一条命令。

## 开户：`tensei-add-user`

### 安装脚本（只做一次）

!!! tip "统一初始密码只需要录入一次"
    脚本第一次运行时会提示你输入统一初始密码，
    并**只保存 SHA-512 哈希**到 `/etc/tensei-users/initial-password.hash`（权限 `600`）。
    之后创建用户不再询问。密码本身不会出现在脚本、日志或聊天记录里。

在 root 的终端里整段执行：

```bash
cat > /usr/local/sbin/tensei-add-user <<'BASH'
#!/bin/bash
set -Eeuo pipefail
umask 077
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

[[ $EUID -eq 0 ]] || { echo "请使用 root 执行"; exit 1; }
[[ $# -eq 1 ]] || { echo "用法：tensei-add-user 用户名"; exit 1; }

username=$1
[[ "$username" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || {
    echo "用户名须以小写字母开头，仅包含小写字母、数字、下划线和短横线"
    exit 1
}

# 防止同时创建用户时发生冲突
exec 9>/run/lock/tensei-add-user.lock
flock -n 9 || { echo "另一个创建操作正在进行"; exit 1; }

if getent passwd "$username" >/dev/null; then
    echo "用户已存在，未修改账号或密码：$username"
    exit 1
fi
if getent group "$username" >/dev/null; then
    echo "同名用户组已存在，请先检查：$username"
    exit 1
fi
if [[ -e "/home/$username" ]]; then
    echo "家目录已存在，请先检查：/home/$username"
    exit 1
fi

# 首次运行时录入统一初始密码，只保存哈希
config_dir=/etc/tensei-users
hash_file=$config_dir/initial-password.hash
install -d -o root -g root -m 0700 "$config_dir"

if [[ ! -s "$hash_file" ]]; then
    read -r -s -p "输入统一初始密码：" initial_password
    echo
    read -r -s -p "再次输入：" password_confirm
    echo
    [[ -n "$initial_password" && "$initial_password" == "$password_confirm" ]] || {
        echo "密码为空或两次输入不一致"
        exit 1
    }

    password_hash=$(printf '%s\n' "$initial_password" | openssl passwd -6 -stdin)
    printf '%s\n' "$password_hash" > "$hash_file"
    chmod 600 "$hash_file"
    unset initial_password password_confirm password_hash
fi

created=0
on_error() {
    trap - ERR
    if [[ "$created" == 1 ]]; then
        usermod -L -e 1 "$username" || true
        echo "配置未完成，账号已锁定。保留已创建内容供检查，不自动删除。"
    fi
    exit 1
}
trap on_error ERR

# 配置完成前保持账号过期且密码锁定
useradd -m -U -s /bin/bash -K UMASK=077 -e 1 "$username"
created=1
user_uid=$(id -u "$username")

# 普通登录会话禁用GPU；Slurm作业不受此用户slice限制
systemctl set-property "user-${user_uid}.slice" \
    DevicePolicy=closed DeviceAllow=

[[ "$(systemctl show "user-${user_uid}.slice" \
    -p DevicePolicy --value)" == "closed" ]]

# 注册Slurm账户，并设置默认账户
sacctmgr -i add user \
    Name="$username" \
    Cluster=tensei \
    Account=research \
    DefaultAccount=research

# 确认关联已创建
association=$(sacctmgr -nP show assoc \
    where Cluster=tensei Account=research User="$username" \
    format=User)
printf '%s\n' "$association" | grep -Fxq "$username"

# 设置密码，强制首次登录修改，最后启用账号
password_hash=$(cat "$hash_file")
printf '%s:%s\n' "$username" "$password_hash" | chpasswd -e
unset password_hash
chage -d 0 "$username"
chage -E -1 "$username"

trap - ERR
echo
echo "用户创建成功：$username"
echo "UID：$user_uid"
echo "家目录：/home/$username"
echo "Slurm：tensei / research"
echo "GPU：仅通过Slurm使用"
echo "首次SSH登录必须修改密码"
BASH

chown root:root /usr/local/sbin/tensei-add-user
chmod 700 /usr/local/sbin/tensei-add-user
bash -n /usr/local/sbin/tensei-add-user
```

### 使用

```bash
tensei-add-user zhangsan
```

第一次会询问统一初始密码，之后只输入用户名即可。

### 脚本做了什么

| 动作 | 实现 | 为什么 |
|---|---|---|
| 校验用户名 | 正则 `^[a-z][a-z0-9_-]{0,30}$` | 避免生成非法或危险的用户名 |
| 防并发 | `flock` 锁 `/run/lock/tensei-add-user.lock` | 两人同时开户不会互相干扰 |
| 拒绝重复创建 | 检查 passwd、group、家目录 | **不会重置已有用户的密码** |
| 初始密码只存哈希 | `openssl passwd -6 -stdin` | 明文密码不落盘 |
| 先锁后配 | `useradd -e 1` | 配置完成前账号不可用 |
| **下发设备限制** | `systemctl set-property user-<UID>.slice DevicePolicy=closed` | **新用户无法绕过 Slurm 占卡** |
| 注册 Slurm 账户 | `sacctmgr add user ... Account=research` | 用量能统计到人 |
| 校验关联成功 | `sacctmgr show assoc` + `grep -Fxq` | 记账没配上就不算成功 |
| 强制首登改密 | `chage -d 0` | 统一密码不能长期使用 |
| 失败即锁定 | `trap on_error ERR` → `usermod -L -e 1` | 半成品账号不会流出去 |

!!! danger "脚本失败时不要手动 `userdel` 重来"
    它会锁定账号并**保留已创建的内容**供检查。
    先看输出定位问题（通常是 `sacctmgr` 连不上记账库），
    修好之后手工把这几步补完，或者先销户再重建。

### 用户首次登录的体验

用 Xshell **密码登录**时会依次被要求输入：

1. 当前的统一初始密码；
2. 自己的新密码；
3. 再次输入新密码。

改密后连接会断开，用新密码重连即可。

!!! warning "需要允许 SSH 密码认证"
    这个脚本**不会修改 SSH 登录策略**。
    如果服务器禁用了密码认证（`PasswordAuthentication no`），
    用户必须先配置密钥，首登改密流程就走不通。

### 适用范围

!!! note "当前仅覆盖单台服务器"
    * **Grafana 是独立账号体系**，脚本不会创建 Grafana 账号，需要单独开通
    * 扩展多节点时，需要保证**各节点的 UID/GID 一致、家目录共享**，
      否则用户在不同节点上会看到不同的文件归属

## 销户：彻底删除一个用户

!!! danger "销户会永久删除家目录"
    下面的流程会终止该用户的**所有任务和进程**，并 `userdel -r` 删除 `/home/<user>`。
    **Slurm 历史记账记录会保留**，便于追溯，这是有意设计的。

### 第一步：确认要删的是谁

```bash
getent passwd clear
id clear
squeue -u clear
```

确认家目录路径、UID，以及有没有正在跑的任务。

### 第二步：执行删除

```bash
(
set -e

username=clear
user_uid=$(id -u "$username")
user_home=$(getent passwd "$username" | cut -d: -f6)

# 防止误删异常路径或系统账号
[[ "$user_uid" -ge 1000 && "$user_home" == "/home/clear" ]] || {
    echo "UID或家目录不符合预期，停止删除，请先检查"
    exit 1
}

# 先禁止账号登录
usermod -L -e 1 "$username"

# 取消Slurm任务；等待资源释放
scancel -u "$username"
for attempt in $(seq 1 30); do
    remaining=$(squeue -h -u "$username" -o '%i')
    [[ -z "$remaining" ]] && break
    sleep 2
done
[[ -z "$remaining" ]] || {
    echo "仍有Slurm任务未清理完，账号已锁定；请检查 squeue -u clear"
    exit 1
}

# 清除定时任务
crontab -u "$username" -r 2>/dev/null || true
if command -v atq >/dev/null; then
    while read -r job_id; do
        atrm "$job_id"
    done < <(atq | awk '$NF == "clear" {print $1}')
fi

# 结束登录会话、用户服务和残余进程
loginctl disable-linger "$username" || true
loginctl terminate-user "$username" || true
pkill -KILL -u "$user_uid" || true

# 删除Slurm用户关联，保留历史记账
sacctmgr -i delete user where Name="$username"

# 删除账号、家目录和邮件目录
userdel -r "$username"

# 清除本次配置的用户slice属性，避免影响未来复用此UID的账号
systemctl revert "user-${user_uid}.slice"
systemctl daemon-reload

# 同名组如果还存在且不再被使用，尝试删除
if getent group "$username" >/dev/null; then
    groupdel "$username"
fi

echo "clear 已删除；原 UID 为 $user_uid"
echo "请继续检查家目录之外属于该UID的文件。"
)
```

### 第三步：清理家目录外的残留

`userdel -r` **只删 `/home/<user>`**。用户在 `/tmp`、`/data` 等位置留下的文件
会变成「无主文件」（只剩 UID 数字）。

```bash
find /home /tmp /var/tmp /opt /data /mnt /srv \
  -uid 1002 -ls 2>/dev/null
```

!!! warning "把 `1002` 换成实际 UID"
    UID 就在上一步的输出里。**先确认文件用途再删**，
    避免误删共享项目数据。

### 第四步：清理外部系统

| 系统 | 是否需要单独删除 |
|---|---|
| Slurm 记账 | ❌ 已由脚本处理（且历史记录有意保留） |
| Grafana | ✅ **需要**在 Grafana 用户管理里单独删除 |
| Cockpit | ❌ 跟 Linux 账号联动，自动失效 |
| 对象存储 / 网盘 | ✅ 如为该用户开过，需单独回收 |

## 批量管理

用户多起来之后，逐个执行会出错。两个方向：

### 方向一：脚本化（当前）

```bash
# 从名单批量开户
for u in zhangsan lisi wangwu; do
  tensei-add-user "$u" || echo "失败：$u"
done
```

!!! warning "批量执行要检查每一项的返回值"
    某个用户因重名失败时，循环应该继续但必须记录下来。

### 方向二：Ansible（推荐用于多节点）

节点超过 2 台后，用 Ansible 统一管理：

| 任务 | 手工 | Ansible |
|---|---|---|
| 创建 20 个用户 | 20 次命令 | 一个 playbook，幂等 |
| 保证各节点 UID 一致 | 容易漏 | `uid:` 显式指定 |
| 分发 `sudoers` / `cron.allow` | 逐台改 | 一个 task |
| 检查所有节点状态 | 逐台登录 | 一条 ad-hoc 命令 |

```bash
# 一次检查所有计算节点的用户与服务
ansible gpu_nodes -m shell -a \
  'getent passwd chao; systemctl is-active slurmd'
```

!!! tip "优先把「用户创建」和「配置分发」交给 Ansible"
    这两件事最频繁，也最容易因为漏做某台而产生
    「同样的命令在 A 机器上能跑、B 机器上报错」的问题。

## 日常账号检查

```bash
# 列出所有普通登录账户
getent passwd | awk -F: \
  '$3>=1000 && $3<65534 && $7 !~ /(nologin|false)$/ {print $1, $3, $6, $7}'

# 检查有没有人拿到了 sudo
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $1}'); do
  printf '%-12s ' "$u"; sudo -l -U "$u" 2>&1 | head -1
done

# 确认所有用户都下发了设备限制
for u in $(getent passwd | awk -F: '$3>=1000 && $3<65534 {print $3}'); do
  printf 'user-%-6s %s\n' "$u" \
    "$(systemctl show "user-${u}.slice" -p DevicePolicy --value 2>/dev/null)"
done

# 确认所有用户都在 Slurm 记账里
sacctmgr show associations format=Cluster,Account,User
```

!!! danger "这三张表要能对上"
    「有 Linux 账号」的用户集合，应该和
    「有 `DevicePolicy=closed`」以及「在 `sacctmgr` 里有记录」
    的集合一致。任何一个集合多出或少掉人，都意味着某个流程被绕过了。

建议每月执行一次，输出存档。

## 相关文档

* [访问入口与安全加固](access-security.md) —— 设备限制的原理与手工下发方式
* [记账与用量统计](accounting.md) —— `sacctmgr` 账户与关联
* [访问集群](../user/access.md) —— 用户侧的登录说明
