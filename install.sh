#!/usr/bin/env bash
# ============================================================
#  mpd2hls 一键远程安装脚本
# ------------------------------------------------------------
#  用法:
#    curl -fsSL https://raw.githubusercontent.com/judy-gotv/MPD-HLS/main/install.sh | bash
#    或
#    wget -qO- https://raw.githubusercontent.com/judy-gotv/MPD-HLS/main/install.sh | bash
#
#  非交互一键模式:
#    curl -fsSL ... | bash -s install      # 直接安装+启动
#    curl -fsSL ... | bash -s uninstall    # 直接卸载
#    curl -fsSL ... | bash -s update       # 全自动在线升级
# ============================================================
set -e

# ---------------- 配色 ----------------
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERR ]${NC} $*" >&2; exit 1; }
step()  { echo -e "${MAGENTA}[STEP]${NC} ${BOLD}$*${NC}"; }

# ---------------- 默认配置 ----------------
INSTALL_DIR="${INSTALL_DIR:-/opt/mpd2hls}"
BIN_PATH="${INSTALL_DIR}/mpd2hls"
ENV_FILE="${INSTALL_DIR}/mpd2hls.env"
MANAGER_SCRIPT_PATH="${INSTALL_DIR}/install.sh"
INSTALLER_API_VERSION="3"
INSTALLER_RELEASE_VERSION="0.0.35"
SERVICE_NAME="mpd2hls"
LEGACY_SERVICE_NAME="mpd2hls-panel"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_FILE="${SYSTEMD_DIR}/${SERVICE_NAME}.service"
LEGACY_SERVICE_FILE="${SYSTEMD_DIR}/${LEGACY_SERVICE_NAME}.service"

PANEL_PORT="${PANEL_PORT:-9527}"
PANEL_ADMIN_PATH="${PANEL_ADMIN_PATH:-/admin}"
GH_REPO="${GH_REPO:-judy-gotv/MPD-HLS}"

# GitHub Releases - latest 自动指向最新版本
GH_RELEASE_TAG="${GH_RELEASE_TAG:-latest}"

release_tag_path() {
  local tag="$1"
  case "$tag" in
    ''|latest|v*) echo "${tag:-latest}" ;;
    [0-9]*) echo "v${tag}" ;;
    *) echo "$tag" ;;
  esac
}

resolve_release_tag() {
  local requested="${1:-latest}"
  local resolved final_url
  if [ -n "${MPD2HLS_LATEST_TAG:-}" ] && { [ -z "$requested" ] || [ "$requested" = "latest" ]; }; then
    resolved="$MPD2HLS_LATEST_TAG"
  elif [ -z "$requested" ] || [ "$requested" = "latest" ]; then
    step "解析 GitHub 最新稳定版本 ..." >&2
    final_url="$(curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
      -o /dev/null -w '%{url_effective}' \
      "https://github.com/${GH_REPO}/releases/latest")" || \
      error "无法解析 GitHub latest 版本，现有服务未改动"
    resolved="${final_url##*/}"
  else
    resolved="$(release_tag_path "$requested")"
  fi
  if ! echo "$resolved" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    error "Release 标签格式无效: ${resolved:-empty}"
  fi
  case "$resolved" in
    v*) echo "$resolved" ;;
    *) echo "v${resolved}" ;;
  esac
}

release_version() {
  local tag="$1"
  echo "${tag#v}"
}

installer_url() {
  local tag="${1:-$GH_RELEASE_TAG}"
  if [ -n "${MPD2HLS_INSTALLER_URL:-}" ]; then
    echo "$MPD2HLS_INSTALLER_URL"
  elif [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    echo "https://github.com/${GH_REPO}/releases/latest/download/install.sh"
  else
    echo "https://github.com/${GH_REPO}/releases/download/$(release_tag_path "$tag")/install.sh"
  fi
}

# ---------------- sudo 检测 ----------------
SUDO=""
if [ "$(id -u)" != "0" ]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    error "当前非 root 用户且未安装 sudo，请用 root 执行或安装 sudo"
  fi
fi

# ---------------- 架构检测 ----------------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)        echo "amd64" ;;
    aarch64|arm64)       echo "arm64" ;;
    armv7l|armv7|armhf)  echo "armv7" ;;
    *)                   echo "unknown" ;;
  esac
}

arch_url() {
  local tag="${2:-$GH_RELEASE_TAG}"
  local base
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    base="https://github.com/${GH_REPO}/releases/latest/download"
  else
    base="https://github.com/${GH_REPO}/releases/download/$(release_tag_path "$tag")"
  fi
  case "$1" in
    amd64) echo "${base}/mpd2hls" ;;
    arm64) echo "${base}/mpd2hls-aarch64" ;;
    armv7) echo "${base}/mpd2hls-armv7" ;;
    *)     echo "" ;;
  esac
}

is_arch() {
  case "${1:-}" in
    auto|amd64|arm64|armv7) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------- 工具：包管理器抽象 ----------------
PM=""
detect_pm() {
  if   command -v apt-get >/dev/null 2>&1; then PM="apt"
  elif command -v dnf     >/dev/null 2>&1; then PM="dnf"
  elif command -v yum     >/dev/null 2>&1; then PM="yum"
  elif command -v apk     >/dev/null 2>&1; then PM="apk"
  elif command -v pacman  >/dev/null 2>&1; then PM="pacman"
  elif command -v zypper  >/dev/null 2>&1; then PM="zypper"
  else PM="unknown"
  fi
}

pkg_install() {
  detect_pm
  local pkg=""
  for spec in "$@"; do
    if [ "${spec%%:*}" = "$PM" ]; then
      pkg="${spec#*:}"
      break
    fi
  done
  [ -z "$pkg" ] && { warn "未识别的包管理器 ($PM)，跳过"; return 0; }
  case "$PM" in
    apt)    $SUDO apt-get update -y >/dev/null 2>&1 || true; $SUDO apt-get install -y $pkg ;;
    dnf)    $SUDO dnf install -y $pkg ;;
    yum)    $SUDO yum install -y $pkg ;;
    apk)    $SUDO apk add --no-cache $pkg ;;
    pacman) $SUDO pacman -Sy --noconfirm $pkg ;;
    zypper) $SUDO zypper install -y $pkg ;;
  esac
}

ensure_cmd() {
  local cmd="$1"; shift
  if command -v "$cmd" >/dev/null 2>&1; then return 0; fi
  warn "缺少命令 $cmd，正在自动安装..."
  pkg_install "$@"
  command -v "$cmd" >/dev/null 2>&1 || warn "$cmd 仍未安装，可能影响后续步骤"
}

# ---------------- 基础依赖 ----------------
prepare_basics() {
  step "检查基础工具 (curl/ca-certificates) ..."
  ensure_cmd curl apt:curl dnf:curl yum:curl apk:curl pacman:curl zypper:curl
  # ca-certificates 对 HTTPS 拉流是必须的
  case "$(detect_pm; echo $PM)" in
    apt)    $SUDO apt-get install -y ca-certificates >/dev/null 2>&1 || true ;;
    dnf|yum) $SUDO ${PM:-yum} install -y ca-certificates >/dev/null 2>&1 || true ;;
    apk)    $SUDO apk add --no-cache ca-certificates >/dev/null 2>&1 || true ;;
  esac
}

# ---------------- 准备目录 ----------------
prepare_dirs() {
  step "准备目录 $INSTALL_DIR ..."
  $SUDO mkdir -p "$INSTALL_DIR"
  $SUDO chmod 755 "$INSTALL_DIR"
  log "  - $INSTALL_DIR ✅"
}

# ---------------- 下载二进制 ----------------
download_binary_asset() {
  local arch="$1"
  local tag="${2:-$GH_RELEASE_TAG}"
  local url expected_version binary_version actual_version
  url="$(arch_url "$arch" "$tag")"
  [ -z "$url" ] && error "不支持的架构: $arch"

  step "下载 $arch 二进制 ..."
  log "  - URL: $url"
  local tmp="/tmp/mpd2hls-$arch.$$"
  rm -f "$tmp"
  if ! curl -fL --progress-bar -o "$tmp" "$url"; then
    rm -f "$tmp"
    error "下载失败，请检查网络或 GitHub 是否可访问"
  fi
  log "  - 已下载: $(du -h "$tmp" | cut -f1) -> $tmp"

  chmod 0755 "$tmp"
  local binary_role
  binary_role="$("$tmp" --binary-role 2>/dev/null || true)"
  if [ "$binary_role" != "panel" ]; then
    rm -f "$tmp"
    error "下载的文件不是后台 panel 二进制，已拒绝安装，避免 systemd 重启循环"
  fi
  log "  - 二进制角色校验: panel ✅"
  binary_version="$("$tmp" --version 2>/dev/null || true)"
  actual_version="${binary_version##* }"
  expected_version="$INSTALLER_RELEASE_VERSION"
  if [ "$actual_version" != "$expected_version" ]; then
    rm -f "$tmp"
    error "二进制版本不匹配：期望 ${expected_version}，实际 ${actual_version:-unknown}；现有服务未改动"
  fi
  log "  - 二进制版本校验: ${actual_version} ✅"

  DOWNLOADED_BINARY="$tmp"
}

download_binary() {
  local arch="$1"
  local tag="${2:-$GH_RELEASE_TAG}"
  local tmp
  download_binary_asset "$arch" "$tag"
  tmp="$DOWNLOADED_BINARY"

  # 备份旧二进制
  if [ -f "$BIN_PATH" ]; then
    $SUDO cp -a "$BIN_PATH" "${BIN_PATH}.bak.$(date +%Y%m%d-%H%M%S)" || true
  fi

  $SUDO install -m 0755 "$tmp" "$BIN_PATH"
  rm -f "$tmp"
  log "  - 已安装到 $BIN_PATH ✅"
}

validate_manager_script() {
  local path="$1" expected_version="$2" actual_version
  bash -n "$path" && \
    grep -q '^INSTALLER_API_VERSION="3"$' "$path" || return 1
  actual_version="$(awk -F'"' '/^INSTALLER_RELEASE_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/ { print $2; exit }' "$path")"
  [[ "$actual_version" == "$expected_version" ]]
}

download_manager_script() {
  local tag="${1:-$GH_RELEASE_TAG}"
  local url tmp
  url="$(installer_url "$tag")"
  tmp="/tmp/mpd2hls-install.$$"
  rm -f "$tmp"
  step "下载并校验最新管理脚本 ..."
  log "  - URL: $url"
  if ! curl -fL --progress-bar -o "$tmp" "$url" || ! validate_manager_script "$tmp" "$(release_version "$tag")"; then
    rm -f "$tmp"
    error "管理脚本下载或兼容性校验失败，现有服务和二进制未改动"
  fi
  log "  - 管理脚本兼容性校验: API ${INSTALLER_API_VERSION} ✅"
  chmod 0755 "$tmp"
  DOWNLOADED_MANAGER_SCRIPT="$tmp"
}

# ---------------- 写入环境变量配置文件 ----------------
init_env_file() {
  step "初始化环境配置 $ENV_FILE ..."
  if [ -f "$ENV_FILE" ]; then
    log "  - 已存在: $ENV_FILE ✅ (跳过覆盖，保留用户修改)"
    return
  fi

  # 自动检测 IPv6：有 IPv6 接口则用 [::1] 双栈 loopback，否则纯 IPv4
  local default_addr
  if [ -s /proc/net/if_inet6 ]; then
    default_addr="[::1]:${PANEL_PORT}"
    log "  - 检测到 IPv6 支持，PANEL_ADDR 默认为 [::1]:${PANEL_PORT} (双栈)"
  else
    default_addr="127.0.0.1:${PANEL_PORT}"
    log "  - 未检测到 IPv6，PANEL_ADDR 默认为 127.0.0.1:${PANEL_PORT}"
  fi
  # 允许用户通过环境变量强制指定
  default_addr="${PANEL_ADDR:-$default_addr}"

  $SUDO tee "$ENV_FILE" >/dev/null <<EOF
# ============================================================
# mpd2hls 运行配置 (由 install.sh 生成)
# 修改后执行: systemctl restart ${SERVICE_NAME}
# ============================================================

# ---------- 面板监听 ----------
# 默认只监听本机，如需公网访问请放在 HTTPS 反向代理后面
# 监听写法：
#   127.0.0.1:${PANEL_PORT}     仅 IPv4 本机
#   [::1]:${PANEL_PORT}         仅 IPv6 本机
#   [::]:${PANEL_PORT}          双栈监听所有接口（公网，需先设 PANEL_ALLOW_INSECURE_PUBLIC_BIND=1 或前置 HTTPS）
#   0.0.0.0:${PANEL_PORT}       仅 IPv4 所有接口
# 若 IPv4 loopback/unspecified 绑定失败，面板会自动尝试 [::1]/[::] fallback。
PANEL_ADDR=${default_addr}

# 内建 HTTPS 监听（两项必须同时设置）；留空时使用反向代理或仅监听 127.0.0.1
PANEL_TLS_CERT=
PANEL_TLS_KEY=

# 仅当确认已由 HTTPS 反向代理保护时，才允许面板直接监听公网地址
PANEL_ALLOW_INSECURE_PUBLIC_BIND=0

# Worker 远端编排默认开启；仅在可信内网/VPN 中需要安装或卸载 worker 时临时启用
PANEL_ENABLE_WORKER_ADMIN=1
PANEL_ADMIN_PATH=${PANEL_ADMIN_PATH}
PANEL_PROCESS_NAME=mpd2hls
PANEL_CHANNELS_FILE=./channels.json
PANEL_AUTH_FILE=./panel_auth.json
PANEL_AUDIT_LOG_FILE=./audit.log
# Panel/worker API token 文件；留空环境 token 时会自动生成并使用该文件
PANEL_API_TOKEN_FILE=./panel_api_token

# ---------- 默认账号 (仅首次生成 panel_auth.json 时生效) ----------
PANEL_ADMIN_USER=admin
# 留空时首次启动会随机生成临时密码并打印到 stderr/journal，登录后可在面板自行修改。
PANEL_ADMIN_PASS=

# 0=HTTP/HTTPS 都发 Cookie；1=仅 HTTPS
PANEL_COOKIE_SECURE=1

# 下游播放器 UA 白名单（空=不校验）
PANEL_PLAYER_USER_AGENT=""

# 日志与调试：0=只保留启停/退出/错误，1=完整调试日志
MPD2HLS_LOG_DEBUG=0

# ---------- 网络超时（直播建议） ----------
MPD2HLS_READ_TIMEOUT_SEC=90
MPD2HLS_REQUEST_TIMEOUT_SEC=90
# HLS 同一轨道的受控并发下载数；结果仍按序发布，1=完全串行，默认 4。
MPD2HLS_HLS_SEGMENT_CONCURRENCY=4

# 连续 MPEG-TS/MMT/TLV 输入仍由 Rust 切成 HLS；默认每 2 秒及时发布一个 TS 分片。
# 面板频道中设置的“输出切片时长”大于 0 时优先于此值。
MPD2HLS_MPEGTS_SEGMENT_SEC=2

# ---------- 直播对齐 / 重锚（默认偏离值） ----------
MPD2HLS_AV_ALIGN_WIDE_MAX_GAP=64
MPD2HLS_SID_MISMATCH_ALLOW_SAME_IDX_MAX_DIFF_MS=800
MPD2HLS_SID_MISMATCH_ADAPTIVE_MAX_DIFF_MS=2500
MPD2HLS_REANCHOR_AFTER_SKIPS=0
EOF
  $SUDO chmod 600 "$ENV_FILE"
  log "  - 已写入并设置权限 600 ✅"
}

read_env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 1
  grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2-
}

set_env_value() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if [ -f "$ENV_FILE" ]; then
    if grep -qE "^${key}=" "$ENV_FILE"; then
      sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$tmp"
    else
      cat "$ENV_FILE" > "$tmp"
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
    fi
  else
    printf '%s=%s\n' "$key" "$value" > "$tmp"
  fi
  $SUDO install -m 600 "$tmp" "$ENV_FILE"
  rm -f "$tmp"
}

extract_addr_port() {
  local addr="$1"
  if echo "$addr" | grep -qE '^\[[^]]+\]:[0-9]+$'; then
    echo "$addr" | sed -E 's/^.*:([0-9]+)$/\1/'
  elif echo "$addr" | grep -qE '^[^:]+:[0-9]+$'; then
    echo "${addr##*:}"
  else
    echo "$PANEL_PORT"
  fi
}

server_ipv4() {
  local ip
  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -Ev '^(127|169\.254)\.' | head -1)"
  [ -z "$ip" ] && ip="$(hostname -i 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -Ev '^(127|169\.254)\.' | head -1)"
  [ -z "$ip" ] && ip="<服务器IP>"
  echo "$ip"
}

open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi "Status: active"; then
    $SUDO ufw allow "${port}/tcp" >/dev/null 2>&1 || true
    log "  - ufw 已放行 ${port}/tcp"
    return
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    $SUDO firewall-cmd --reload >/dev/null 2>&1 || true
    log "  - firewalld 已放行 ${port}/tcp"
    return
  fi
  warn "未检测到已启用的 ufw/firewalld；如云服务器仍无法访问，请在安全组放行 TCP ${port}"
}

configure_ip_port_mode() {
  step "配置 IP+端口直连访问模式 ..."
  if [ ! -x "$BIN_PATH" ]; then
    warn "尚未安装服务，请先执行一键安装后再开启 IP+端口模式。"
    return
  fi

  [ -f "$ENV_FILE" ] || init_env_file

  local current_addr current_port input port ip
  current_addr="$(read_env_value PANEL_ADDR || true)"
  current_port="$(extract_addr_port "$current_addr")"
  [ -z "$current_port" ] && current_port="$PANEL_PORT"

  read -r -p "请输入面板端口 [${current_port}]: " input
  port="${input:-$current_port}"
  case "$port" in
    ''|*[!0-9]*)
      warn "端口无效：$port"
      return
      ;;
  esac
  if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    warn "端口范围必须是 1-65535"
    return
  fi

  set_env_value PANEL_ADDR "0.0.0.0:${port}"
  set_env_value PANEL_ALLOW_INSECURE_PUBLIC_BIND "1"
  set_env_value PANEL_COOKIE_SECURE "0"
  PANEL_PORT="$port"

  open_firewall_port "$port"
  write_systemd_service
  start_service

  ip="$(server_ipv4)"
  echo
  log "IP+端口模式已启用："
  echo -e "    面板地址 : ${CYAN}http://${ip}:${port}${PANEL_ADMIN_PATH}${NC}"
  echo -e "    监听配置 : ${CYAN}PANEL_ADDR=0.0.0.0:${port}${NC}"
  echo -e "    HTTP登录 : ${CYAN}PANEL_COOKIE_SECURE=0${NC}"
  echo -e "    配置文件 : ${ENV_FILE}"
}

# ---------------- 写入 systemd 服务 ----------------
migrate_legacy_service() {
  local legacy_found=0
  if [ -e "$LEGACY_SERVICE_FILE" ] || \
     $SUDO systemctl is-active --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null || \
     $SUDO systemctl is-enabled --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null; then
    legacy_found=1
  fi
  [ "$legacy_found" -eq 0 ] && return 0

  step "迁移旧服务 ${LEGACY_SERVICE_NAME}.service -> ${SERVICE_NAME}.service ..."
  $SUDO systemctl disable --now "$LEGACY_SERVICE_NAME" >/dev/null 2>&1 || true
  $SUDO rm -f "$LEGACY_SERVICE_FILE" || return 1
  $SUDO systemctl daemon-reload || return 1
  $SUDO systemctl reset-failed "$LEGACY_SERVICE_NAME" >/dev/null 2>&1 || true
  log "  - 旧服务已停止、禁用并删除，避免重复监听 ${PANEL_PORT} 端口 ✅"
}

write_systemd_service() {
  step "写入 systemd 服务 $SERVICE_FILE ..."
  if ! $SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=mpd2hls Panel Service
After=network-online.target
Wants=network-online.target
Conflicts=${LEGACY_SERVICE_NAME}.service

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${BIN_PATH}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
# 仅允许写入安装目录与临时目录
ProtectSystem=full
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  then
    return 1
  fi
  $SUDO systemctl daemon-reload || return 1
  $SUDO systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || return 1
  migrate_legacy_service || return 1
  log "  - 已写入并启用开机自启 ✅"
}

# ---------------- 启停 ----------------
start_service() {
  if [ ! -f "$SERVICE_FILE" ]; then
    write_systemd_service
  else
    migrate_legacy_service
  fi
  step "启动 $SERVICE_NAME ..."
  $SUDO systemctl restart "$SERVICE_NAME"
  sleep 2
  if $SUDO systemctl is-active --quiet "$SERVICE_NAME"; then
    log "  - 服务运行中 ✅"
    return 0
  else
    warn "  - 服务启动失败，请查看日志:"
    $SUDO journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    return 1
  fi
}

stop_service() {
  step "停止 $SERVICE_NAME ..."
  $SUDO systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  migrate_legacy_service
  log "  - 已停止"
}

health_check_url() {
  local addr port scheme cert key
  addr="$(read_env_value PANEL_ADDR || true)"
  addr="${addr%\"}"
  addr="${addr#\"}"
  port="$(extract_addr_port "$addr")"
  cert="$(read_env_value PANEL_TLS_CERT || true)"
  key="$(read_env_value PANEL_TLS_KEY || true)"
  cert="${cert%\"}"
  cert="${cert#\"}"
  key="${key%\"}"
  key="${key#\"}"
  scheme="http"
  if [ -n "$cert" ] && [ -n "$key" ]; then
    scheme="https"
  fi
  case "$addr" in
    0.0.0.0:*) echo "${scheme}://127.0.0.1:${port}/api/health" ;;
    \[::\]:*) echo "${scheme}://[::1]:${port}/api/health" ;;
    '') echo "${scheme}://127.0.0.1:${port}/api/health" ;;
    *) echo "${scheme}://${addr}/api/health" ;;
  esac
}

verify_service_health() {
  local url attempt
  url="$(health_check_url)"
  for attempt in $(seq 1 10); do
    if curl -kfsS --noproxy '*' --max-time 3 "$url" >/dev/null 2>&1; then
      log "  - 健康检查通过: $url ✅"
      return 0
    fi
    sleep 1
  done
  warn "  - 健康检查失败: $url"
  return 1
}

verify_update_topology() {
  local binary_role binary_version
  binary_role="$("$BIN_PATH" --binary-role 2>/dev/null || true)"
  binary_version="$("$BIN_PATH" --version 2>/dev/null || true)"
  if [ "$binary_role" != "panel" ] || [ -z "$binary_version" ]; then
    warn "  - 二进制验证失败: role=${binary_role:-none} version=${binary_version:-none}"
    return 1
  fi
  if ! $SUDO systemctl is-active --quiet "$SERVICE_NAME"; then
    warn "  - 规范服务未处于运行状态: ${SERVICE_NAME}.service"
    return 1
  fi
  if ! $SUDO systemctl is-enabled --quiet "$SERVICE_NAME"; then
    warn "  - 规范服务未启用开机自启: ${SERVICE_NAME}.service"
    return 1
  fi
  if [ -e "$LEGACY_SERVICE_FILE" ] || \
     $SUDO systemctl is-active --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null || \
     $SUDO systemctl is-enabled --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null; then
    warn "  - 旧服务仍然存在: ${LEGACY_SERVICE_NAME}.service"
    return 1
  fi
  verify_service_health
}

rollback_binary_update() {
  local backup_path="$1"
  warn "升级验证失败，开始回滚二进制..."
  $SUDO systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  if [ -n "$backup_path" ] && [ -f "$backup_path" ]; then
    $SUDO install -m 0755 "$backup_path" "$BIN_PATH"
    $SUDO systemctl restart "$SERVICE_NAME" 2>/dev/null || true
    warn "已恢复升级前二进制，请查看: journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  else
    warn "升级前没有可回滚的二进制，服务保持停止以避免运行未知版本"
  fi
  return 1
}

# ---------------- 提取首次启动密码 ----------------
show_admin_password() {
  if [ -f "${INSTALL_DIR}/panel_auth.json" ]; then
    # 已存在 auth 文件，密码已被哈希持久化
    return
  fi
  # 等待日志输出
  local i=0
  local line=""
  while [ $i -lt 10 ]; do
    line=$($SUDO journalctl -u "$SERVICE_NAME" --no-pager 2>/dev/null | grep -i "generated one-time temporary password" | tail -1 || true)
    [ -n "$line" ] && break
    sleep 1
    i=$((i+1))
  done
  if [ -n "$line" ]; then
    echo -e "${YELLOW}${BOLD}$line${NC}"
  fi
}

# ---------------- 完成横幅 ----------------
print_banner() {
  local arch="$1"
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -z "$ip" ] && ip="$(hostname -i 2>/dev/null | awk '{print $1}')"
  [ -z "$ip" ] && ip="<服务器 IP>"
  # 同时尝试获取 IPv6
  local ip6
  ip6="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9a-fA-F:]+$' | grep ':' | head -1)"

  echo
  echo -e "${GREEN}╔════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║   ✅  mpd2hls 安装并启动完成 (${arch})         ║${NC}"
  echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}"
  echo -e "  ${BOLD}访问地址${NC}"
  if [ -s /proc/net/if_inet6 ]; then
    echo -e "    本机 IPv4 : ${CYAN}http://127.0.0.1:${PANEL_PORT}${PANEL_ADMIN_PATH}${NC}"
    echo -e "    本机 IPv6 : ${CYAN}http://[::1]:${PANEL_PORT}${PANEL_ADMIN_PATH}${NC}"
  else
    echo -e "    本机面板 : ${CYAN}http://127.0.0.1:${PANEL_PORT}${PANEL_ADMIN_PATH}${NC}"
  fi
  local bind_addr bind_port public_ip
  bind_addr="$(read_env_value PANEL_ADDR || true)"
  bind_port="$(extract_addr_port "$bind_addr")"
  public_ip="$(server_ipv4)"
  if echo "$bind_addr" | grep -Eq '^(0\.0\.0\.0|\[::\]):'; then
    echo -e "    IP+端口 : ${CYAN}http://${public_ip}:${bind_port}${PANEL_ADMIN_PATH}${NC}"
  fi
  echo -e "    若已配置反代/公网: ${CYAN}https://<你的域名>${PANEL_ADMIN_PATH}${NC}"
  echo -e "  ${BOLD}文件位置${NC}"
  echo -e "    二进制   : ${BIN_PATH}"
  echo -e "    配置     : ${ENV_FILE}   ${YELLOW}(修改后 systemctl restart ${SERVICE_NAME})${NC}"
  echo -e "    频道     : ${INSTALL_DIR}/channels.json"
  echo -e "    认证     : ${INSTALL_DIR}/panel_auth.json"
  echo -e "    日志     : journalctl -u ${SERVICE_NAME} -f"
  echo -e "${GREEN}--------------------------------------------${NC}"
  echo -e "  🔐  ${YELLOW}${BOLD}默认账号${NC}"
  echo -e "      用户名 : ${CYAN}${BOLD}admin${NC}"
  echo -e "      密  码 : ${YELLOW}首次启动随机生成，请查看下方日志：${NC}"
  echo
  show_admin_password
  echo
  echo -e "      ${BOLD}手动查看密码命令：${NC}"
  echo -e "        ${CYAN}journalctl -u ${SERVICE_NAME} | grep -i 'temporary password'${NC}"
  echo -e "  ⚠️   ${YELLOW}登录后请立即在面板「账号设置」中修改密码！${NC}"
  echo -e "${GREEN}--------------------------------------------${NC}"
  echo -e "  ${BOLD}常用命令${NC}"
  echo -e "    systemctl start|stop|restart|status ${SERVICE_NAME}"
  echo -e "    journalctl -u ${SERVICE_NAME} -f                # 实时日志"
  echo -e "    bash $0 menu                                    # 交互菜单"
  echo -e "    bash $0 ip-port                                 # 开启/修改 IP+端口访问"
  echo -e "    bash $0 update                                  # 升级到最新版"
  echo -e "    bash $0 uninstall                               # 卸载"
  echo -e "${GREEN}============================================${NC}"
}

# ---------------- 主动作 ----------------
do_install() {
  local arch="${1:-}"
  local tag="${2:-$GH_RELEASE_TAG}"
  if ! is_arch "$arch"; then
    tag="$arch"
    arch="auto"
  fi
  if [ -z "$arch" ] || [ "$arch" = "auto" ]; then
    arch="$(detect_arch)"
    [ "$arch" = "unknown" ] && error "无法识别架构: $(uname -m)，请手动指定 amd64/arm64/armv7"
    log "自动检测架构: ${BOLD}$arch${NC} ($(uname -m))"
  fi
  prepare_basics
  prepare_dirs
  tag="$(resolve_release_tag "$tag")"
  log "锁定安装版本: ${tag}"
  GH_RELEASE_TAG="$tag"
  download_binary "$arch" "$tag"
  init_env_file
  write_systemd_service
  start_service || error "服务启动失败，请查看 journalctl -u ${SERVICE_NAME} -n 80 --no-pager"
  print_banner "$arch"
}

do_update_internal() {
  local tag="${1:-$GH_RELEASE_TAG}"
  local arch rollback_path="" staged_binary
  log "全自动升级：迁移服务 + 更新二进制 + 健康验证（配置保留）"
  prepare_dirs
  [ -f "$ENV_FILE" ] || init_env_file
  arch="$(detect_arch)"
  [ "$arch" = "unknown" ] && error "无法识别架构: $(uname -m)"
  tag="$(resolve_release_tag "$tag")"
  log "锁定升级版本: ${tag}"
  GH_RELEASE_TAG="$tag"
  download_binary_asset "$arch" "$tag"
  staged_binary="$DOWNLOADED_BINARY"
  if [ -f "$BIN_PATH" ]; then
    rollback_path="${BIN_PATH}.rollback.$(date +%Y%m%d-%H%M%S)"
    $SUDO cp -a "$BIN_PATH" "$rollback_path"
  fi
  if ! $SUDO install -m 0755 "$staged_binary" "$BIN_PATH"; then
    rm -f "$staged_binary"
    rollback_binary_update "$rollback_path" || true
    error "安装新二进制失败，已尝试恢复升级前版本"
  fi
  rm -f "$staged_binary"
  log "  - 已安装到 $BIN_PATH ✅"
  if ! write_systemd_service || ! start_service || ! verify_update_topology; then
    rollback_binary_update "$rollback_path"
    return 1
  fi
  [ -z "$rollback_path" ] || $SUDO rm -f "$rollback_path"
  log "✅ 全自动升级完成：${SERVICE_NAME}.service 正在独占面板端口"
  $SUDO systemctl status "$SERVICE_NAME" --no-pager -n 5 || true
}

do_update() {
  local tag="${1:-$GH_RELEASE_TAG}"
  local manager_tmp
  log "在线升级：先更新管理脚本，再升级服务和二进制"
  prepare_basics
  prepare_dirs
  tag="$(resolve_release_tag "$tag")"
  log "锁定在线升级版本: ${tag}"
  download_manager_script "$tag"
  manager_tmp="$DOWNLOADED_MANAGER_SCRIPT"
  $SUDO install -m 0755 "$manager_tmp" "$MANAGER_SCRIPT_PATH"
  rm -f "$manager_tmp"
  log "  - 最新管理脚本已安装: $MANAGER_SCRIPT_PATH ✅"
  INSTALL_DIR="$INSTALL_DIR" \
    PANEL_PORT="$PANEL_PORT" \
    PANEL_ADMIN_PATH="$PANEL_ADMIN_PATH" \
    GH_REPO="$GH_REPO" \
    GH_RELEASE_TAG="$tag" \
    MPD2HLS_LATEST_TAG="${MPD2HLS_LATEST_TAG:-}" \
    SYSTEMD_DIR="$SYSTEMD_DIR" \
    MPD2HLS_INSTALLER_URL="${MPD2HLS_INSTALLER_URL:-}" \
    bash "$MANAGER_SCRIPT_PATH" update-internal "$tag"
}

do_uninstall() {
  echo -e "${RED}╔════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║   ⚠️   卸载 mpd2hls                         ║${NC}"
  echo -e "${RED}╚════════════════════════════════════════════╝${NC}"
  echo -e "  将执行:"
  echo -e "    1) 停止并禁用 systemd 服务"
  echo -e "    2) 删除 ${SERVICE_FILE}"
  echo -e "    3) 删除 ${INSTALL_DIR} (含二进制 / 频道 / 认证 / 日志)"
  echo
  read -r -p "确认输入 YES 继续: " ans
  if [ "$ans" != "YES" ]; then
    warn "已取消"
    return
  fi
  $SUDO systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  $SUDO systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  $SUDO systemctl disable --now "$LEGACY_SERVICE_NAME" 2>/dev/null || true
  $SUDO rm -f "$SERVICE_FILE"
  $SUDO rm -f "$LEGACY_SERVICE_FILE"
  $SUDO systemctl daemon-reload || true
  $SUDO rm -rf "$INSTALL_DIR"
  log "✅ 已卸载并清理完毕"
}

do_status() {
  local addr status_port public_ip
  addr="$(read_env_value PANEL_ADDR || true)"
  status_port="$(extract_addr_port "$addr")"
  public_ip="$(server_ipv4)"
  echo "============================================"
  echo "  mpd2hls 服务状态"
  echo "============================================"
  if $SUDO systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo -e "  状态  : ${GREEN}运行中${NC}"
  else
    echo -e "  状态  : ${RED}未运行${NC}"
  fi
  echo "  端口  : ${status_port:-$PANEL_PORT}"
  echo "  监听  : ${addr:-未生成配置}"
  if echo "$addr" | grep -Eq '^(0\.0\.0\.0|\[::\]):'; then
    echo "  IP访问: http://${public_ip}:${status_port}${PANEL_ADMIN_PATH}"
  fi
  echo "  目录  : $INSTALL_DIR"
  echo "  二进制: $BIN_PATH ($([ -f "$BIN_PATH" ] && du -h "$BIN_PATH" | cut -f1 || echo '未安装'))"
  echo "  配置  : $ENV_FILE"
  echo "  服务  : $SERVICE_FILE"
  if [ -e "$LEGACY_SERVICE_FILE" ] || \
     $SUDO systemctl is-active --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null || \
     $SUDO systemctl is-enabled --quiet "$LEGACY_SERVICE_NAME" 2>/dev/null; then
    echo -e "  ${YELLOW}警告  : 检测到旧服务 ${LEGACY_SERVICE_NAME}.service；执行 update 或 start 会自动迁移${NC}"
  fi
  echo "--------------------------------------------"
  $SUDO systemctl status "$SERVICE_NAME" --no-pager -n 10 2>/dev/null || true
  echo "============================================"
}

do_logs() {
  echo "[Ctrl+C 退出查看]"
  $SUDO journalctl -u "$SERVICE_NAME" -f --no-pager
}

do_show_password() {
  step "查找首次启动随机密码 ..."
  local line
  line=$($SUDO journalctl -u "$SERVICE_NAME" --no-pager 2>/dev/null | grep -i "generated one-time temporary password" | tail -1 || true)
  if [ -n "$line" ]; then
    echo -e "${YELLOW}${BOLD}$line${NC}"
  else
    warn "未在日志中找到随机密码记录。可能原因："
    echo "  1) 你已经在 $ENV_FILE 里设置了 PANEL_ADMIN_PASS=xxx"
    echo "  2) panel_auth.json 已存在（密码已被持久化哈希存储）"
    echo "  3) 日志已轮转，可尝试: journalctl -u $SERVICE_NAME --since '2 hours ago'"
    echo ""
    echo "如需重置密码："
    echo "  systemctl stop $SERVICE_NAME"
    echo "  rm -f $INSTALL_DIR/panel_auth.json"
    echo "  # 编辑 $ENV_FILE 把 PANEL_ADMIN_PASS 留空（或设为你想要的密码）"
    echo "  systemctl start $SERVICE_NAME"
    echo "  bash $0 password   # 再次查看"
  fi
}

# ---------------- 菜单 ----------------
show_menu() {
  clear 2>/dev/null || true
  local arch; arch="$(detect_arch)"
  echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}     ${BOLD}mpd2hls  一键远程安装/管理${NC}              ${BLUE}║${NC}"
  echo -e "${BLUE}║${NC}     ${CYAN}https://github.com/${GH_REPO}${NC}            ${BLUE}║${NC}"
  echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
  echo -e "  当前架构 : ${CYAN}${arch}${NC} ($(uname -m))"
  echo -e "  升级通道 : ${CYAN}${GH_RELEASE_TAG}${NC}"
  echo -e "  安装目录 : ${CYAN}${INSTALL_DIR}${NC}"
  echo -e "  端  口   : ${CYAN}${PANEL_PORT}${NC}  路径: ${CYAN}${PANEL_ADMIN_PATH}${NC}"
  echo -e "${BLUE}--------------------------------------------${NC}"
  echo -e "  ${GREEN}1)${NC}  一键安装 (自动识别架构)        ${YELLOW}★ 推荐${NC}"
  echo -e "  ${GREEN}2)${NC}  指定架构安装 (amd64 / arm64 / armv7)"
  echo -e "  ${GREEN}3)${NC}  全自动在线升级 (脚本+二进制+服务迁移)"
  echo -e "  ${GREEN}4)${NC}  启动服务"
  echo -e "  ${GREEN}5)${NC}  停止服务"
  echo -e "  ${GREEN}6)${NC}  查看运行状态"
  echo -e "  ${GREEN}7)${NC}  查看实时日志"
  echo -e "  ${GREEN}8)${NC}  开启/修改 IP+端口访问模式"
  echo -e "  ${GREEN}9)${NC}  查看首次启动随机密码"
  echo -e "  ${RED}10)${NC} 卸载 (清理所有文件)"
  echo -e "  ${YELLOW}0)${NC}  退出"
  echo -e "${BLUE}============================================${NC}"
}

menu_loop() {
  while true; do
    show_menu
    read -r -p "请选择 [0-10]: " choice
    case "$choice" in
      1) do_install auto;  read -r -p "按回车返回菜单..." _ ;;
      2)
         echo "  a) amd64    b) arm64    c) armv7"
         read -r -p "选择 [a/b/c]: " a
         case "$a" in
           a|A|amd64) do_install amd64 ;;
           b|B|arm64) do_install arm64 ;;
           c|C|armv7) do_install armv7 ;;
           *) warn "无效选择" ;;
         esac
         read -r -p "按回车返回菜单..." _ ;;
      3) do_update;       read -r -p "按回车返回菜单..." _ ;;
      4) start_service;   read -r -p "按回车返回菜单..." _ ;;
      5) stop_service;    read -r -p "按回车返回菜单..." _ ;;
      6) do_status;       read -r -p "按回车返回菜单..." _ ;;
      7) do_logs ;;
      8) configure_ip_port_mode; read -r -p "按回车返回菜单..." _ ;;
      9) do_show_password; read -r -p "按回车返回菜单..." _ ;;
      10) do_uninstall;    read -r -p "按回车返回菜单..." _ ;;
      0) echo "Bye 👋"; exit 0 ;;
      *) warn "无效选择: $choice"; sleep 1 ;;
    esac
  done
}

# ---------------- 入口 ----------------
case "${1:-}" in
  install)            do_install "${2:-auto}" "${3:-$GH_RELEASE_TAG}" ;;
  install-version)    do_install auto "${2:-$GH_RELEASE_TAG}" ;;
  install-amd64)      do_install amd64 "${2:-$GH_RELEASE_TAG}" ;;
  install-arm64)      do_install arm64 "${2:-$GH_RELEASE_TAG}" ;;
  install-armv7)      do_install armv7 "${2:-$GH_RELEASE_TAG}" ;;
  ip-port|ipport|public-bind) configure_ip_port_mode ;;
  update)             do_update "${2:-$GH_RELEASE_TAG}" ;;
  update-internal)    do_update_internal "${2:-$GH_RELEASE_TAG}" ;;
  start)              start_service ;;
  stop)               stop_service ;;
  restart)            stop_service; start_service ;;
  status)             do_status ;;
  logs)               do_logs ;;
  password|passwd)    do_show_password ;;
  uninstall|remove)   do_uninstall ;;
  menu|"")            menu_loop ;;
  -h|--help|help)
    cat <<EOF
mpd2hls 一键安装脚本

用法:
  bash $0                  # 交互菜单 (默认)
  bash $0 install [arch]   # 安装 (arch: auto|amd64|arm64|armv7)
  bash $0 ip-port          # 开启/修改 IP+端口直连访问模式
  bash $0 update           # 全自动在线升级并验证服务
  bash $0 start|stop       # 启停服务
  bash $0 restart          # 重启服务
  bash $0 status           # 查看状态
  bash $0 logs             # 实时日志
  bash $0 password         # 查看首次启动随机密码
  bash $0 uninstall        # 卸载

环境变量（可在执行前 export 覆盖默认值）:
  INSTALL_DIR=/opt/mpd2hls       # 安装目录
  PANEL_PORT=9527                # 面板端口
  PANEL_ADMIN_PATH=/admin        # 面板路径
  GH_REPO=judy-gotv/MPD-HLS      # GitHub 仓库
  GH_RELEASE_TAG=latest          # 版本号，如 0.2.33

示例：
  GH_RELEASE_TAG=0.2.33 bash $0 install
  bash $0 install 0.2.33
  bash $0 install amd64 0.2.33
  bash $0 install-version 0.2.33
  bash $0 update 0.0.32
  PANEL_PORT=18080 bash $0 install amd64
  bash $0 ip-port
EOF
    ;;
  *) error "未知命令: $1   (使用 'bash $0 help' 查看帮助)" ;;
esac
