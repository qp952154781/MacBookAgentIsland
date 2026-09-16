#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == "--help" ]]; then
    echo "用法：scripts/install.sh（构建并安装到 /Applications；先退出正在运行的旧版）"
    exit 0
fi
if [[ $# -ne 0 ]]; then
    echo "不支持的参数；使用 --help 查看说明。" >&2
    exit 2
fi
scripts/bundle.sh
agent_is_running() {
    local query_status=0
    /usr/bin/pgrep -x AgentIsland >/dev/null || query_status=$?
    if [[ $query_status -gt 1 ]]; then
        echo "无法检查旧版 AgentIsland，安装已中止。" >&2
        exit "$query_status"
    fi
    return "$query_status"
}
if agent_is_running; then
    quit_status=0
    /usr/bin/pkill -x AgentIsland || quit_status=$?
    if [[ $quit_status -gt 1 ]]; then
        echo "退出旧版 AgentIsland 失败，安装已中止。" >&2
        exit "$quit_status"
    fi
    if [[ $quit_status -ne 0 ]]; then
        if agent_is_running; then
            echo "无法退出旧版 AgentIsland，安装已中止。" >&2
            exit 1
        fi
    fi
    for ((attempt=0; attempt<20; attempt++)); do
        if ! agent_is_running; then break; fi
        sleep 0.25
    done
    if agent_is_running; then
        echo "旧版尚未退出，请从岛的右键菜单退出后重试。" >&2
        exit 1
    fi
fi
INSTALL_STAGE="/Applications/.AgentIsland-install-$$.app"
trap 'rm -rf "$INSTALL_STAGE"' EXIT
/usr/bin/ditto dist/AgentIsland.app "$INSTALL_STAGE"
/usr/bin/codesign --verify --deep --strict "$INSTALL_STAGE"
# Retain a complete previous bundle until the replacement has been staged and verified.
if [[ -e /Applications/AgentIsland.app ]]; then
    if [[ -e /Applications/AgentIsland.previous.app ]]; then
        echo "请先移走 /Applications/AgentIsland.previous.app，再重试。" >&2
        exit 1
    fi
    mv /Applications/AgentIsland.app /Applications/AgentIsland.previous.app
fi
if ! mv "$INSTALL_STAGE" /Applications/AgentIsland.app; then
    if [[ -e /Applications/AgentIsland.previous.app ]]; then
        mv /Applications/AgentIsland.previous.app /Applications/AgentIsland.app
    fi
    exit 1
fi
echo "已安装 /Applications/AgentIsland.app。请手动打开；右键岛 → 设置 → 开机启动。"
echo "如系统要求，请在 系统设置 → 通用 → 登录项与扩展 中允许 AgentIsland。"
echo "如有 AgentIsland.previous.app，确认新版正常后可手动移除。"
