#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Komari Agent 迁移脚本：从官方 komari-monitor/komari-agent 切换到本 fork
#   xinian5216/komari-agent-stable
#
# 迁移只做三件事：
#   1. 保留现有 systemd 单元里的全部启动参数（endpoint / token / interval 等）
#   2. 用本 fork 的二进制替换 /opt/komari/agent（旧二进制留作备份）
#   3. 重启服务，使 Agent 的自更新来源变为 xinian5216/komari-agent-stable
#
# 不需要重新添加节点、不需要重新生成 token、不会丢失任何历史数据。
#
# 用法：
#   bash migrate-komari-agent.sh              # 交互确认
#   bash migrate-komari-agent.sh -y           # 非交互（一键迁移）
#   bash migrate-komari-agent.sh --status     # 只查看当前来源与版本
#   bash migrate-komari-agent.sh --target-version v1.5.10-stable.0
# ---------------------------------------------------------------------------
set -u

GITHUB_API_BASE="${KOMARI_AGENT_API_BASE:-https://api.github.com}"
GITHUB_RELEASE_BASE="${KOMARI_AGENT_RELEASE_BASE:-https://github.com}"
REPO_OWNER="${KOMARI_AGENT_REPO_OWNER:-xinian5216}"
REPO_NAME="${KOMARI_AGENT_REPO_NAME:-komari-agent-stable}"
REPO_SLUG="$REPO_OWNER/$REPO_NAME"

TARGET_DIR="/opt/komari"
BINARY_PATH="$TARGET_DIR/agent"
SERVICE_NAME="${KOMARI_AGENT_SERVICE:-komari-agent}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

ASSUME_YES=0
ACTION=""
TARGET_VERSION="${KOMARI_TARGET_VERSION:-}"

# 旧来源（官方 agent 的默认仓库），仅用于提示与迁移前后对照
UPSTREAM_REPO="komari-monitor/komari-agent"

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; }
die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

require_root() {
    if [ "$(id -u)" != "0" ]; then
        die "please run as root (sudo bash $0)"
    fi
}

# 从现有 systemd 单元里取出启动参数（去掉二进制路径本身）
current_args() {
    [ -f "$UNIT_FILE" ] || return 1
    sed -n 's/^ExecStart=//p' "$UNIT_FILE" | head -1 | sed "s|^[^ ]*${BINARY_PATH}[^ ]*[[:space:]]*||"
}

current_version() {
    if [ ! -x "$BINARY_PATH" ]; then
        printf 'unknown'
        return
    fi
    local out=""
    out=$("$BINARY_PATH" version 2>/dev/null | head -1) || true
    if [ -z "$out" ]; then
        out=$("$BINARY_PATH" --version 2>/dev/null | head -1) || true
    fi
    if [ -n "$out" ]; then
        printf '%s' "$out" | awk '{print $NF}'
        return
    fi
    grep -aoE '[0-9]+\.[0-9]+\.[0-9]+' "$BINARY_PATH" 2>/dev/null | head -1 || printf 'unknown'
}

# Agent 启动时会打印 "Github Repo: <repo>"，用它验证更新来源
logged_repo() {
    command -v journalctl >/dev/null 2>&1 || return 1
    journalctl -u "$SERVICE_NAME" --no-pager -n 200 2>/dev/null \
        | sed -n 's/.*Github Repo:[[:space:]]*//p' | tail -1
}

print_status() {
    say "Komari Agent 迁移状态"
    say "  单元文件     : $UNIT_FILE $([ -f "$UNIT_FILE" ] && echo '(found)' || echo '(missing)')"
    say "  安装路径     : $BINARY_PATH $([ -x "$BINARY_PATH" ] && echo '(found)' || echo '(missing)')"
    say "  当前版本     : $(current_version)"
    say "  当前启动参数 : $(current_args || echo '-')"
    say "  日志中的来源 : $(logged_repo || echo '(未取到，服务未运行或日志已轮转)')"
    say "  目标来源     : $REPO_SLUG ($GITHUB_RELEASE_BASE/$REPO_SLUG)"
    if command -v systemctl >/dev/null 2>&1; then
        say "  服务状态     : $(systemctl is-active ${SERVICE_NAME}.service 2>/dev/null || echo inactive)"
    fi
}

target_version_label() {
    if [ -n "$TARGET_VERSION" ]; then printf '%s' "$TARGET_VERSION"; return; fi
    local tag=""
    tag=$(curl -fsSL -m 15 "${GITHUB_API_BASE}/repos/${REPO_SLUG}/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    if [ -n "$tag" ]; then printf '%s' "$tag"; else printf '%s' "latest"; fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64' ;;
        aarch64|arm64) printf 'arm64' ;;
        armv7l|armv7) printf 'armv7' ;;
        i386|i686) printf '386' ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
}

asset_name() {
    printf 'komari-agent-linux-%s' "$(detect_arch)"
}

download_url() {
    local version="$1" asset="$2"
    if [ "$version" = "latest" ]; then
        printf '%s/%s/releases/latest/download/%s' "$GITHUB_RELEASE_BASE" "$REPO_SLUG" "$asset"
    else
        printf '%s/%s/releases/download/%s/%s' "$GITHUB_RELEASE_BASE" "$REPO_SLUG" "$version" "$asset"
    fi
}

verify_checksum() {
    local url="$1" file="$2" expected actual
    command -v sha256sum >/dev/null 2>&1 || { warn "sha256sum 不可用，跳过校验"; return 0; }
    expected=$(curl -fsSL -m 20 "${url}.sha256" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -z "$expected" ]; then
        warn "该版本未提供 .sha256，跳过校验"
        return 0
    fi
    actual=$(sha256sum "$file" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        warn "校验失败（期望 $expected，实际 $actual）"
        return 1
    fi
    say "校验通过：$actual"
    return 0
}

main() {
    require_root

    if [ ! -f "$UNIT_FILE" ]; then
        die "未找到 $UNIT_FILE：这不是官方脚本安装的 Agent 实例。
如需全新安装，请使用本 fork 的安装脚本（install.sh），它会直接指向 $REPO_SLUG。"
    fi
    [ -x "$BINARY_PATH" ] || die "未找到可执行文件 $BINARY_PATH"

    local args
    args="$(current_args || true)"
    if [ -z "${args// /}" ]; then
        die "无法从 $UNIT_FILE 读取启动参数（ExecStart 为空？），已中止以免丢失 endpoint/token。"
    fi

    local version target asset url
    version="$(target_version_label)"
    target="$(current_version)"
    asset="$(asset_name)"
    url="$(download_url "$version" "$asset")"

    say "Komari Agent 迁移（保留节点与 token）"
    say "  当前版本   : $target"
    say "  目标版本   : $version"
    say "  旧来源     : $UPSTREAM_REPO（或其它）"
    say "  目标来源   : $REPO_SLUG"
    say "  启动参数   : $args"
    say "  下载地址   : $url"

    if [ "$ASSUME_YES" -ne 1 ]; then
        printf '\n继续迁移？(Y/n): '
        read -r answer || answer="n"
        case "$answer" in
            ""|y|Y|yes|YES) ;;
            *) say "已取消"; exit 0 ;;
        esac
    fi

    command -v curl >/dev/null 2>&1 || die "需要 curl"

    local stamp tmp backup
    stamp="$(date +%Y%m%d_%H%M%S)"
    tmp="${BINARY_PATH}.new.${stamp}"
    backup="${BINARY_PATH}.backup.${stamp}"

    step "下载新二进制"
    if ! curl -fSL --retry 2 -o "$tmp" "$url"; then
        rm -f "$tmp"
        die "下载失败：$url"
    fi
    verify_checksum "$url" "$tmp" || { rm -f "$tmp"; die "校验未通过，未做任何改动"; }
    chmod +x "$tmp"

    step "停止服务并替换二进制（启动参数保持原样）"
    systemctl stop "${SERVICE_NAME}.service" || true
    cp "$BINARY_PATH" "$backup" || { rm -f "$tmp"; die "无法备份旧二进制"; }
    if ! mv -f "$tmp" "$BINARY_PATH"; then
        cp "$backup" "$BINARY_PATH"
        systemctl start "${SERVICE_NAME}.service" || true
        die "替换二进制失败，已回滚"
    fi

    step "启动服务"
    systemctl daemon-reload || true
    systemctl start "${SERVICE_NAME}.service"
    sleep 5

    if ! systemctl is-active --quiet "${SERVICE_NAME}.service"; then
        warn "新二进制未能启动服务，正在回滚..."
        cp "$backup" "$BINARY_PATH"
        systemctl start "${SERVICE_NAME}.service" || true
        sleep 3
        die "已回滚到旧二进制；请检查 journalctl -u ${SERVICE_NAME} -n 50"
    fi

    step "验证更新来源"
    local repo_line
    repo_line="$(logged_repo || true)"
    if [ -n "$repo_line" ]; then
        say "日志中的 Github Repo: $repo_line"
        case "$repo_line" in
            "$REPO_SLUG") say "✅ 自更新来源已切换到 $REPO_SLUG" ;;
            *) warn "日志显示来源仍为 '$repo_line'，请稍后执行 journalctl -u ${SERVICE_NAME} -n 50 复查" ;;
        esac
    else
        warn "未能从 journal 读到 'Github Repo' 行；请手动执行：journalctl -u ${SERVICE_NAME} -n 50 | grep 'Github Repo'"
    fi

    say ""
    say "迁移完成："
    say "  - 节点与 token 未变动（启动参数原样保留）"
    say "  - 旧二进制备份：$backup"
    say "  - 如需回滚：systemctl stop ${SERVICE_NAME} && cp $backup $BINARY_PATH && systemctl start ${SERVICE_NAME}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) ASSUME_YES=1 ;;
        --status) ACTION="status" ;;
        --target-version) shift; TARGET_VERSION="${1:-}" ;;
        --target-version=*) TARGET_VERSION="${1#*=}" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) ;;
    esac
    shift
done

if [ "$ACTION" = "status" ]; then
    print_status
    exit 0
fi

main
