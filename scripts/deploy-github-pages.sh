#!/usr/bin/env bash
#
# 把文档站发布到 GitHub Pages。个人账号和组织（Organization）都适用。
#
#   ./scripts/deploy-github-pages.sh <账号或组织名> <仓库名>
#
# 例如：
#   ./scripts/deploy-github-pages.sh xiaoxu03 tensei-server-doc
#   ./scripts/deploy-github-pages.sh xiaoxu03 xiaoxu03.github.io
#   ./scripts/deploy-github-pages.sh my-lab tensei-server-doc     # 组织
#
# 脚本会：改写 mkdocs.yml 里的三处地址 -> 构建校验 -> 提交 -> 添加远程。
# 推送与开启 Pages 的步骤见脚本末尾的输出提示。
#
# 注意（组织账号）：推送前请确认组织没有限制 Pages 发布或 Actions 运行，
# 否则工作流会失败。详见 docs/deploy.md 的「部署到 GitHub 组织」一节。

set -Eeuo pipefail

GITHUB_USER="${1:-}"
REPO_NAME="${2:-}"

die() { echo "错误：$*" >&2; exit 1; }

[[ -n "$GITHUB_USER" ]] || die "用法：$0 <账号或组织名> <仓库名>"
[[ -n "$REPO_NAME" ]]   || die "用法：$0 <账号或组织名> <仓库名>"

# 必须在仓库根目录执行
[[ -f mkdocs.yml ]] || die "当前目录没有 mkdocs.yml，请在 tensei-server-doc 目录下执行"
[[ -d .git ]]       || die "当前目录不是 git 仓库"

# --- 关键：站点地址取决于仓库名 -------------------------------------------
# 仓库叫 <user>.github.io  ->  站点在根路径
# 仓库叫其它名字           ->  站点在 /<repo>/ 子路径
# 写错会导致线上样式全丢（资源路径 404）。
if [[ "$REPO_NAME" == "${GITHUB_USER}.github.io" ]]; then
    SITE_URL="https://${GITHUB_USER}.github.io/"
else
    SITE_URL="https://${GITHUB_USER}.github.io/${REPO_NAME}/"
fi
REPO_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}"

echo "账号 / 组织 : $GITHUB_USER"
echo "仓库名      : $REPO_NAME"
echo "站点地址    : $SITE_URL"
echo "仓库地址    : $REPO_URL"
echo

# --- 改写 mkdocs.yml -------------------------------------------------------
if grep -q "your-org" mkdocs.yml; then
    cp -a mkdocs.yml "mkdocs.yml.bak-$(date +%Y%m%d-%H%M%S)"

    # site_url 单独处理（值取决于仓库名）
    sed -i.tmp "s|^site_url: .*|site_url: ${SITE_URL}|" mkdocs.yml
    # 其余三处 repo_url / repo_name / social link 共用同一个替换
    sed -i.tmp "s|your-org/tensei-server-doc|${GITHUB_USER}/${REPO_NAME}|g" mkdocs.yml
    rm -f mkdocs.yml.tmp

    echo "==> mkdocs.yml 已更新："
    grep -nE "^site_url:|^repo_url:|^repo_name:|link: https://github.com" mkdocs.yml
    echo
else
    echo "==> mkdocs.yml 里已无 your-org 占位符，跳过改写"
    echo "    当前 site_url: $(grep -E '^site_url:' mkdocs.yml)"
    echo
fi

# --- 构建校验 -------------------------------------------------------------
if [[ -x .venv/bin/mkdocs ]]; then
    MKDOCS=.venv/bin/mkdocs
elif command -v mkdocs >/dev/null 2>&1; then
    MKDOCS=mkdocs
else
    die "找不到 mkdocs，请先执行：python3 -m venv .venv && ./.venv/bin/pip install -r requirements.txt"
fi

echo "==> 构建校验（--strict）"
"$MKDOCS" build --strict
echo "    构建通过"
echo

# --- 提交 -----------------------------------------------------------------
if [[ -n "$(git status --porcelain)" ]]; then
    git add -A
    git commit -q -m "chore: 配置 GitHub Pages 地址为 ${SITE_URL}"
    echo "==> 已提交配置变更"
else
    echo "==> 没有需要提交的变更"
fi
echo

# --- 添加远程并推送 -------------------------------------------------------
if git remote get-url origin >/dev/null 2>&1; then
    echo "==> origin 已存在：$(git remote get-url origin)"
    echo "    如需修改：git remote set-url origin ${REPO_URL}.git"
else
    git remote add origin "${REPO_URL}.git"
    echo "==> 已添加 origin: ${REPO_URL}.git"
fi

echo
echo "接下来执行推送（需要你先在 GitHub 上建好空仓库）："
echo
echo "    git push -u origin main"
echo
cat <<EOF
============================ 推送后必做 ============================
1. 打开 ${REPO_URL}/settings/pages
2. Build and deployment -> Source 选择 **GitHub Actions**（不要选分支）
3. 回到 ${REPO_URL}/actions 看工作流是否成功
4. 访问 ${SITE_URL}
====================================================================
EOF
