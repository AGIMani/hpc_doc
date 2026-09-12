# 部署本文档站

本文档站基于 **MkDocs + Material for MkDocs** 构建，是纯静态站点，
可以部署到 GitHub Pages、内网 Nginx、对象存储等任何能托管静态文件的地方。

## 1 环境准备

### 本机预览

```bash
cd tensei-server-doc

# 创建虚拟环境并安装依赖
python3 -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 启动本地预览（带热重载）
mkdocs serve
```

浏览器打开 <http://127.0.0.1:8000>。**修改 `docs/` 下的任意文件后页面会自动刷新。**

!!! tip "本地预览时地址为什么会带一个子路径"
    `mkdocs serve` 会遵循 `site_url` 里的路径部分。
    如果 `site_url` 是 `https://your-org.github.io/tensei-server-doc/`，
    那么本地服务实际地址是 `http://127.0.0.1:8000/tensei-server-doc/`，
    访问根路径会被 302 重定向过去。

    如果希望本地就在根路径预览，临时把 `site_url` 改成 `http://127.0.0.1:8000/` 即可
    —— 但**提交前记得改回来**，否则线上资源路径会错。

### 依赖清单

`requirements.txt`：

```text
mkdocs-material>=9.5,<10
mkdocs-git-authors-plugin>=0.9
jieba>=0.42
```

!!! note "为什么需要 jieba"
    `mkdocs.yml` 中 `plugins.search.lang` 包含 `zh`，Material 会使用 jieba 做**中文分词**，
    否则中文搜索只能整句匹配，效果很差。

!!! warning "为什么没有用 mkdocs-add-number-plugin"
    [AIR-Server-Doc](https://github.com/Co1lin/AIR-Server-Doc) 用这个插件给标题自动编号，
    但它会把标题的 `id` **替换成序号**（`#1`、`#4-srun-pty`），
    导致所有「页面#小节」形式的交叉引用失效，且每次增删小节都要重新编号。

    本项目的取舍是：**保留可读、稳定的中文锚点**，不自动编号。
    如果确实需要编号，请手工写在标题里（例如 `## 3 启动服务`），
    锚点会变成 `#3-启动服务`，仍然可引用。

## 2 部署前必须修改的配置

打开 `mkdocs.yml`，替换以下占位符：

```yaml
# 1. 线上访问地址（影响搜索索引、canonical 链接、社交分享卡片）
site_url: https://your-org.github.io/tensei-server-doc/

# 2. 代码仓库地址（右上角图标与每页「编辑此页」）
repo_url: https://github.com/your-org/tensei-server-doc
repo_name: your-org/tensei-server-doc
edit_uri: edit/main/docs/

extra:
  # 3. 页脚 GitHub 图标链接
  social:
    - icon: fontawesome/brands/github
      link: https://github.com/your-org/tensei-server-doc
      name: 文档仓库
```

!!! warning "`site_url` 末尾的斜杠不能少"
    必须是 `https://.../tensei-server-doc/`，写成 `.../tensei-server-doc` 会导致
    部分相对链接解析错误。

### 不要改掉 `toc.slugify`

`mkdocs.yml` 里有这样一段，**它是中文站点的关键配置**：

```yaml
markdown_extensions:
  - toc:
      permalink: true
      slugify: !!python/object/apply:pymdownx.slugs.slugify
        kwds:
          case: lower
```

Python-Markdown 默认的 slugify 会**丢弃所有非 ASCII 字符**。
对中文标题来说，这等于标题被清空，于是锚点退化成 `_1`、`_2`、`_3`……
既没法阅读，也没法稳定引用（插一个新标题，后面全部错位）。

换成 `pymdownx.slugs.slugify` 后，中文标题会得到可读的锚点：

| 标题 | 默认 slugify | 配置后 |
|---|---|---|
| `## 快速开始` | `_1` | `快速开始` |
| `## 为什么必须通过 Slurm 使用 GPU` | `_2` | `为什么必须通过-slurm-使用-gpu` |
| `## 后台批处理：sbatch 与任务组` | `_3` | `后台批处理sbatch-与任务组` |

!!! danger "改这个配置会让所有已有的对外链接失效"
    如果文档已经发布并被别人引用过，切换 slugify 方案后旧锚点全部 404。
    建议在**首次发布前**就定好，不要中途改。

## 3 构建

```bash
# 严格模式：把警告当错误，能提前发现死链和语法问题
mkdocs build --strict

# 本地起一个静态服务器检查产物
python3 -m http.server 8080 -d site
```

产物在 `site/` 目录，整个目录就是可部署的静态站点。

!!! tip "什么时候该用 `--strict`"
    提交前、CI 里都应该用。本地边写边看时用 `mkdocs serve` 就够了。
    `--strict` 会因为**任何**警告失败，包括「某页不在 nav 中」这种小问题。

## 4 方案一：GitHub Pages（推荐）

### 4.1 推送仓库

```bash
cd tensei-server-doc
git init -b main
git add .
git commit -m "docs: 初始化 Tensei 集群文档站"
git remote add origin git@github.com:your-org/tensei-server-doc.git
git push -u origin main
```

!!! note "`git-authors` 插件需要提交历史"
    `mkdocs.yml` 启用了 `git-authors` 插件，用于在页脚显示撰写者。
    它依赖 git 提交记录，所以**仓库必须有至少一次提交**，
    CI 中也必须用 `fetch-depth: 0` 拉取完整历史（工作流里已配置）。

### 4.2 开启 Pages

在 GitHub 仓库中：**Settings → Pages → Build and deployment → Source** 选择
**GitHub Actions**。

### 4.3 自动部署工作流

仓库已包含 `.github/workflows/ci.yml`：

```yaml
name: build-and-deploy

on:
  push:
    branches: [main, master]
  workflow_dispatch:

permissions:
  contents: read
  pages: write
  id-token: write

concurrency:
  group: pages
  cancel-in-progress: true

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0          # git-authors 需要完整历史
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
          cache: pip
      - run: pip install -r requirements.txt
      - run: mkdocs build --strict
      - uses: actions/upload-pages-artifact@v3
        with:
          path: site

  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - uses: actions/deploy-pages@v4
        id: deployment
```

推送到 `main` 后，Actions 会自动构建并发布。访问地址形如
`https://your-org.github.io/tensei-server-doc/`。

### 4.4 备选：`gh-deploy` 一键发布

如果不想用 Actions，也可以用 MkDocs 自带命令把产物推到 `gh-pages` 分支：

```bash
mkdocs gh-deploy --force
```

然后把 **Settings → Pages → Source** 改成 **Deploy from a branch** → `gh-pages` / `root`。

!!! warning "两种方式不要同时用"
    `gh-deploy` 和 Actions 都会写 Pages，混用会互相覆盖。
    选了 Actions（Source = GitHub Actions）就不要再跑 `gh-deploy`。

## 5 方案二：内网 Nginx

适合把文档放在公司内网或集群登录节点上。

```bash
mkdocs build --strict
sudo rsync -a --delete site/ /var/www/tensei-doc/
```

Nginx 配置：

```nginx
server {
    listen 80;
    server_name doc.example.internal;
    root /var/www/tensei-doc;
    index index.html;

    # MkDocs 使用目录式 URL，需要 try_files 兜底
    location / {
        try_files $uri $uri/ $uri.html =404;
    }

    # 静态资源缓存
    location ~* \.(css|js|png|jpg|svg|woff2?)$ {
        expires 7d;
        add_header Cache-Control "public";
    }
}
```

!!! tip "本地 `mkdocs serve` 与 Nginx 的路径差异"
    `mkdocs serve` 会处理 `$uri` → `$uri.html` 的映射，Nginx 需要上面那行 `try_files` 才能
    直接访问 `…/user/slurm/` 这类目录式链接。如果希望完全不依赖服务器配置，
    可以设置 `use_directory_urls: false`，但链接会变成 `slurm.html` 形式。

## 6 方案三：Docker

```dockerfile
FROM squidfunk/mkdocs-material:9
RUN pip install --no-cache-dir \
      mkdocs-git-authors-plugin jieba
WORKDIR /docs
COPY . /docs
RUN mkdocs build --strict
```

```bash
docker build -t tensei-doc .
docker run --rm -v "$PWD/site:/docs/site" tensei-doc
```

!!! note "git-authors 在容器里可能失效"
    如果构建上下文没有 `.git` 目录，`git-authors` 插件会拿不到作者信息。
    构建时确保 `.git` 在上下文内，或者临时在 `mkdocs.yml` 中注释掉该插件。

## 7 维护约定

| 约定 | 说明 |
|---|---|
| 命令必须可直接复制执行 | 写清执行身份（普通用户 / `root`），不要写占位符命令 |
| 危险操作加 `!!! danger` | 说明后果与回滚方式 |
| 区分「已配置」与「建议」 | 未启用的功能要显式标注，避免读者误以为已生效 |
| 提交前跑 `mkdocs build --strict` | 提前发现死链 |
| 链接用相对路径 | 例如 `../admin/policy.md#调度策略`，换域名不会失效 |

### 常用 Markdown 扩展

本项目启用了 Material 的扩展语法：

````markdown
!!! danger "标题"
    警告内容，缩进 4 个空格。

=== "Tab 1"
    内容

    ```bash
    echo hello
    ```

```mermaid
flowchart LR
    A[提交任务] --> B[排队] --> C[运行]
```
````

行内代码高亮、按键样式、折叠块等用法见
[Material 官方文档](https://squidfunk.github.io/mkdocs-material/)。

## 8 常见问题

| 现象 | 原因与处理 |
|---|---|
| `mkdocs build --strict` 报 `contains a link ... but the target is not found` | 文档里有失效的相对链接，按提示路径修正 |
| 中文搜索搜不到 | 确认 `requirements.txt` 装了 `jieba`，且 `plugins.search.lang` 含 `zh` |
| CI 报 `fatal: detected dubious ownership` 或作者信息为空 | `actions/checkout` 没设 `fetch-depth: 0` |
| 页面样式错乱 | `site_url` 与实际部署路径不一致，检查子路径是否写对 |
| 本地正常，线上 404 | Pages 的 Source 配置与实际分支不一致 |
| 中文标题的锚点变成 `_1` / `_2` | `toc.slugify` 没配 Unicode 版本，见 [第 2 节](#2-部署前必须修改的配置) |
