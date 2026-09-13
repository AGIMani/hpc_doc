# Tensei A100 集群使用与管理文档

八卡 NVIDIA A100 服务器的**用户使用指南**与**管理员运维手册**，基于 MkDocs Material 构建。

- **用户指南**：如何登录集群、如何用 Slurm 申请 GPU、如何跑单卡/多卡/多机训练、如何查看用量。
- **管理员手册**：如何从零部署 Slurm 集群、如何制定调度策略与配额、如何做记账与监控、如何管理账号与加固安全。

> 站点自身的部署说明不放在文档里，统一记在本 README。

## 本地预览

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

mkdocs serve
```

!!! note "预览地址带子路径"
    `mkdocs serve` 遵循 `site_url` 的路径部分。若 `site_url` 是
    `https://<owner>.github.io/tensei-server-doc/`，本地地址就是
    `http://127.0.0.1:8000/tensei-server-doc/`，访问根路径会被 302 重定向过去。

## 构建

```bash
mkdocs build --strict     # 产物在 site/
```

`--strict` 会把警告当错误，能提前发现死链。提交前务必跑一次。

## 发布到 GitHub Pages

```bash
./scripts/deploy-github-pages.sh <账号或组织名> <仓库名>
```

脚本会自动推断站点地址（区分 `<owner>.github.io` 仓库与普通仓库）、改写
`mkdocs.yml` 里的三处地址、跑一次 `--strict` 构建校验、提交并添加远程。
之后按提示 `git push -u origin main`，再到仓库 **Settings → Pages**
把 **Source** 设为 **GitHub Actions**。

推送后 `.github/workflows/ci.yml` 会自动构建并发布。

### 部署前需要修改

`mkdocs.yml` 顶部有三处占位符（脚本会自动替换）：

| 配置项 | 说明 |
|---|---|
| `site_url` | 线上访问地址，影响资源路径、搜索与社交分享卡片 |
| `repo_url` | 代码仓库地址，右上角图标与「编辑此页」入口 |
| `extra.social[0].link` | 页脚 GitHub 图标链接 |

**`site_url` 写错的后果**：它决定站点根路径。仓库叫 `tensei-server-doc`
而 `site_url` 写成根路径，线上会页面能开但样式全丢。用脚本而不是手改。

### 部署到组织账号的注意事项

三个组织级设置会导致工作流失败，推送前先确认：

| 设置 | 位置 | 要求 |
|---|---|---|
| Pages 发布权限 | 组织 → Settings → Access → Member privileges → Pages creation | 勾选 **Public** |
| Actions 策略 | 组织 → Settings → Actions → General → Policies | 允许 **GitHub 创建的操作** |
| SHA 固定策略 | 同上 | 若开启 "Require actions to be pinned to a full-length commit SHA"，`@v4` 写法会失败，需改成完整 commit SHA |

**私有仓库 ≠ 私有站点。** 站点要仅组织成员可见需要 GitHub Enterprise Cloud；
Team 计划下代码不公开，但发布出来的站点任何人都能访问。

## 飞书接入

如果读者主要在飞书里，正确做法是**站点部署在可达地址上、飞书只做入口** ——
飞书不托管任意静态站点。

配置路径：飞书开发者后台 → 创建企业自建应用 → 添加「网页应用」能力 →
**网页配置**填桌面端/移动端主页地址 → **安全设置**加 H5 可信域名 →
提交发布，由企业管理员审核。

| 要点 | 说明 |
|---|---|
| H5 可信域名 | 只在调用飞书 JSAPI 时才必须，纯展示文档站可不配 |
| 地址可达性 | 内网地址仅在公司网络/VPN 下可打开；官方建议上线用公网地址 |
| 移动端 | 需 HTTPS |
| 更新文档 | 只更新内容不需要重新发布飞书应用，改应用配置才需要 |

## 国内 / 内网访问适配

站点**不依赖任何境外 CDN**，可以直接部署在无外网出口的内网环境：

| 项 | 处理 |
|---|---|
| 字体 | `theme.font: false`，用系统字体栈（中文本来就是系统字体渲染，观感不变） |
| mermaid 架构图 | 自托管 `docs/assets/javascripts/mermaid.min.js`，不走 unpkg |

!!! warning "`docs/assets/javascripts/mermaid.min.js` 约 3.4 MB"
    它会在首次访问时加载一次（gzip 后约 950 KB），之后走浏览器缓存。
    确认部署环境能稳定访问 unpkg 时，可以删掉它和 `mkdocs.yml` 里的
    `extra_javascript` 退回 CDN —— **内网部署不要这么做**，否则架构图全部空白。

## 目录结构

```
tensei-server-doc/
├── mkdocs.yml                 # 站点配置（导航、主题、插件）
├── requirements.txt           # 构建依赖
├── scripts/
│   └── deploy-github-pages.sh # 一键配置并发布到 GitHub Pages
├── .github/workflows/ci.yml   # 自动构建并发布到 GitHub Pages
└── docs/
    ├── index.md               # 概述
    ├── assets/
    │   ├── extra.css          # 自定义样式与中文字体栈
    │   └── javascripts/
    │       └── mermaid.min.js # 自托管 mermaid（避免 unpkg）
    ├── overrides/main.html    # 主题覆盖（页脚作者信息）
    ├── user/                  # 用户指南
    └── admin/                 # 管理员手册
```

## 文档维护约定

1. **命令要能直接复制执行**。给命令时说明执行身份（普通用户 / `root`）。
2. **危险操作必须加 `!!! danger` 提示**，写清后果与回滚方式。
3. **区分「当前已配置」与「建议但未启用」**，避免读者误以为功能已生效。
4. **只写这台机器上真实存在的东西**，不介绍没用到的替代方案。
5. 修改后本地执行 `mkdocs build --strict`，确保没有死链和语法错误。

## 已知的配置取舍

| 取舍 | 原因 |
|---|---|
| 不启用 `mkdocs-add-number-plugin` | 它会把标题 id 换成 `#1`、`#4-srun-pty`，导致所有跨页锚点失效 |
| `toc.slugify` 用 pymdownx Unicode 版 | 默认 slugify 丢弃非 ASCII，中文标题的锚点会退化成 `_1`、`_2` |
| `theme.font: false` | 默认从 Google Fonts 取 Roboto，国内不可达；中文本来就走系统字体 |
| mermaid 自托管 | 默认从 unpkg 动态拉取，国内不可达、内网完全不可用 |
