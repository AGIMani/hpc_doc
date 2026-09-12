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

## 7 在飞书里接入

文档站的读者主要在飞书里，有三种接入方式，按投入从低到高排列。

!!! info "先说结论"
    飞书**不托管**任意静态站点，所以没有「把 MkDocs 部署到飞书」这回事。
    正确做法是：**站点部署在能访问的地址上，飞书只做入口。**

### 7.1 方式一：直接发链接（零配置）

把站点地址发到飞书群或云文档里即可。飞书会给链接生成卡片预览。

适合：临时分享、人数少的团队。

### 7.2 方式二：工作台「网页应用」（推荐）

配好之后，文档会作为应用出现在飞书工作台，桌面端和移动端都能一键打开。

**步骤**（官方教程：[将已有网页应用嵌入飞书工作台](https://open.feishu.cn/document/uAjLw4CM/uMzNwEjLzcDMx4yM3ATM/embed-web-app-into-feishu-workbench/introduction)）：

1. 打开[飞书开发者后台](https://open.feishu.cn/app)，**创建企业自建应用**；
2. 左侧 **添加应用能力** → 选择 **网页应用** → 添加能力；
3. 在 **网页配置** 中填写 **桌面端主页** 和 **移动端主页**，两者都填文档站地址：

    ```text
    https://doc.example.internal/
    ```

4. 左侧 **安全设置** → **H5 可信域名**，加入同一个域名；
5. **版本管理与发布** → 创建版本 → 提交发布 → **企业管理员审核**。

!!! tip "H5 可信域名什么时候才必须配"
    `H5 可信域名` 是给**调用飞书 JSAPI**（免登、获取用户信息、扫码等）用的。
    如果只是单纯展示一个文档站、不调用任何飞书能力，**这一项可以不配**。
    但建议还是填上——以后想加「免登显示用户名」之类的功能时不用回头改配置。

!!! note "自建应用不需要飞书官方审核"
    企业自建应用由**你们自己的企业管理员**审核通过即可使用，
    不走飞书应用中心的上架流程。参考
    [企业自建应用开发流程](https://open.feishu.cn/document/develop-process/self-built-application-development-process.md)。

最后在 **可用范围** 里选择哪些部门/成员能看到这个应用。

### 7.3 最关键的约束：地址必须对飞书客户端可达

这是整件事里最容易翻车的地方。

| 部署位置 | 桌面端 | 移动端（外网） | 说明 |
|---|---|---|---|
| 公网域名 + HTTPS | ✅ | ✅ | 最省心，官方推荐 |
| 公司内网域名 | ✅ 仅内网时 | ❌ | 适合全员在公司网络或已连 VPN |
| `localhost` / `127.0.0.1` | ❌ | ❌ | 只适合开发者后台里临时调试 |

!!! danger "飞书客户端不一定在你公司的内网里"
    官方文档明确要求「正式上线应用时，主页地址需为**公网地址**」。
    因为飞书客户端（尤其手机）可能在任何网络下打开这个应用。

    如果你的文档站只在内网，那么**只有在公司网络或连了 VPN 时**才能打开。
    上线前先让一个同事用手机飞书试一下，别等到全员用的时候才发现打不开。

!!! warning "移动端用 HTTPS"
    飞书移动端对 HTTP 地址限制较严。公网部署请务必配 HTTPS。

### 7.4 `site_url` 必须和飞书里填的地址一致

这一步错了会导致**页面能开但样式全丢**。

```yaml
# mkdocs.yml
site_url: https://doc.example.internal/
```

`site_url` 决定站点的根路径。如果实际访问地址是 `https://doc.example.internal/docs/`，
而 `site_url` 写的是 `https://doc.example.internal/`，所有 CSS/JS 都会 404。

!!! danger "改完 `site_url` 必须重新构建"
    它是**构建期**参数，只改 `mkdocs.yml` 不重新 `mkdocs build` 是没用的。

### 7.5 已做的国内访问适配

为了让站点在国内网络和飞书内置浏览器里打开够快，已做两处改造：

| 问题 | 处理 |
|---|---|
| 字体从 `fonts.googleapis.com` 加载，国内不可达 | `theme.font: false`，改用系统字体栈（中文本来就是系统字体渲染，观感不变） |
| mermaid 图从 `unpkg.com` 动态拉取，国内不可达、纯内网完全不可用 | 自托管 `docs/assets/javascripts/mermaid.min.js`，Material 检测到全局 `mermaid` 后跳过 CDN |

!!! tip "自托管 mermaid 的代价"
    这份文件约 3.4 MB（gzip 后约 950 KB），会在**首次访问时**加载一次，
    之后由浏览器缓存。仓库因此多了 3.4 MB。

    如果确定部署环境能稳定访问 unpkg，可以删掉 `mkdocs.yml` 里的
    `extra_javascript` 和 `docs/assets/javascripts/mermaid.min.js` 退回 CDN 方案。
    **内网部署不要这么做** —— 内网通常根本没有外网出口，9 张架构图会全部空白。

### 7.6 移动端阅读体验

Material 主题本身是响应式的，手机上可以正常看。两点需要提醒读者：

* **参数表格较宽**，手机竖屏需要横向滑动，建议横屏查看；
* **命令块**可以横向滚动，不会折行错乱。

### 7.7 文档更新后的流程

站点更新**不影响飞书侧配置** —— 地址不变，应用不用重新发布：

```bash
# 修改 docs/ 下的内容后
mkdocs build --strict

# 推送到部署位置
git push                 # GitHub Pages 会自动构建
# 或
sudo rsync -a --delete site/ /var/www/tensei-doc/    # 内网 Nginx
```

!!! note "什么时候需要重新发布飞书应用"
    只有改**应用配置**（主页地址、可信域名、可用范围、应用名称图标）时才需要
    重新创建版本并提交审核。单纯更新文档内容不需要。

## 8 维护约定

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

## 9 常见问题

| 现象 | 原因与处理 |
|---|---|
| `mkdocs build --strict` 报 `contains a link ... but the target is not found` | 文档里有失效的相对链接，按提示路径修正 |
| 中文搜索搜不到 | 确认 `requirements.txt` 装了 `jieba`，且 `plugins.search.lang` 含 `zh` |
| CI 报 `fatal: detected dubious ownership` 或作者信息为空 | `actions/checkout` 没设 `fetch-depth: 0` |
| 页面样式错乱 | `site_url` 与实际部署路径不一致，检查子路径是否写对 |
| 本地正常，线上 404 | Pages 的 Source 配置与实际分支不一致 |
| 中文标题的锚点变成 `_1` / `_2` | `toc.slugify` 没配 Unicode 版本，见 [第 2 节](#2-部署前必须修改的配置) |
| 飞书里打开页面但样式全丢 | `site_url` 与飞书里配置的地址不一致，见 [7.4](#74-site_url-必须和飞书里填的地址一致) |
| 飞书里打不开页面 | 地址对客户端不可达；内网地址仅在公司网络/VPN 下有效，见 [7.3](#73-最关键的约束地址必须对飞书客户端可达) |
| 架构图在内网部署后空白 | mermaid 被改回 CDN 加载，见 [7.5](#75-已做的国内访问适配) |
