#!/usr/bin/env bash
# 初始化 submodule。在 worktree 中，对主仓库已 clone 的 submodule，临时把 .git/config
# 的 submodule URL 改写为指向主仓库 modules dir 的绝对路径，让 git 走本地 clone；
# init 完成后用 git submodule sync 把 URL 恢复成 .gitmodules 中的远程地址。
# 各 worktree 持独立的 modules 与 core.worktree，互不干扰；同时绕过远端网络 clone 的延迟。
# 注：
# - 不用 --reference：该选项在源仓库 shallow 时报错，本仓库 submodule 均为 shallow。
# - 不用 file:// 前缀：git 2.38+ 默认禁 file transport（CVE-2022-39253）；
#   绝对路径走 filesystem-direct clone，不经 file transport。
# - protocol.file.allow=always 作为 fallback，避免 git 内部归一化为 file:// 时被阻断。
set -euo pipefail

git_dir=$(realpath "$(git rev-parse --git-dir)")
main_git_dir=$(realpath "$(git rev-parse --git-common-dir)")

if [ "$git_dir" != "$main_git_dir" ]; then
    while IFS= read -r sm; do
        if [ -d "$main_git_dir/modules/$sm" ]; then
            git config "submodule.$sm.url" "$main_git_dir/modules/$sm"
        fi
    done < <(git config --file .gitmodules --name-only --get-regexp 'submodule\..*\.path' \
             | sed -E 's/^submodule\.(.+)\.path$/\1/')

    git -c protocol.file.allow=always submodule update --init --recursive

    git submodule sync --recursive
else
    git submodule update --init --recursive
fi
