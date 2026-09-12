# Tensei A100 集群使用与管理文档

八卡 NVIDIA A100 服务器的**用户使用指南**与**管理员运维手册**，基于 MkDocs Material 构建，可直接发布为线上文档站。

- **用户指南**：如何登录集群、如何用 Slurm 申请 GPU、如何跑单卡/多卡/多机训练、如何查看用量。
- **管理员手册**：如何从零部署 Slurm 集群、如何制定调度策略与配额、如何做记账与监控、如何管理账号与加固安全。

## 本地预览

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

mkdocs serve          # 打开 http://127.0.0.1:8000
```

## 构建与发布

```bash
mkdocs build --strict     # 产物在 site/
mkdocs gh-deploy --force  # 一键发布到 GitHub Pages 的 gh-pages 分支
```

推送到 `main` 分支后，`.github/workflows/ci.yml` 会自动构建并发布到 GitHub Pages。

## 部署前需要修改

`mkdocs.yml` 顶部有三处占位符，发布前请替换为真实值：

| 配置项 | 说明 |
|---|---|
| `site_url` | 线上访问地址，影响搜索与社交分享卡片 |
| `repo_url` | 代码仓库地址，右上角图标与「编辑此页」入口 |
| `extra.social[0].link` | 页脚 GitHub 图标链接 |

详细步骤见文档中的「部署本文档站」章节。

## 目录结构

```
tensei-server-doc/
├── mkdocs.yml                 # 站点配置（导航、主题、插件）
├── requirements.txt           # 构建依赖
├── .github/workflows/ci.yml   # 自动构建并发布到 GitHub Pages
└── docs/
    ├── index.md               # 概述
    ├── deploy.md              # 文档站部署说明
    ├── assets/extra.css       # 自定义样式
    ├── overrides/main.html    # 主题覆盖（页脚作者信息）
    ├── user/                  # 用户指南
    └── admin/                 # 管理员手册
```

## 文档维护约定

1. **命令要能直接复制执行**。给命令时说明执行身份（普通用户 / `root`）。
2. **危险操作必须加 `!!! danger` 提示**，写清后果与回滚方式。
3. **区分「当前已配置」与「建议但未启用」**，避免读者误以为功能已生效。
4. 修改后本地执行 `mkdocs build --strict`，确保没有死链和语法错误。
