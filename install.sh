#!/usr/bin/env bash
# ============================================================================
# Xray Reality + Vision + Caddy 一键管理脚本
# ----------------------------------------------------------------------------
# 功能：
#   1) 安装      - 部署 Xray(Reality+Vision) + Caddy(伪装站)，自动申请证书
#   2) 卸载      - 停止并移除服务、配置、可选清理伪装站和日志策略
#   3) 查看状态  - 展示服务运行、端口监听、版本、日志保留情况
#   4) 客户端参数- 输出 VLESS 分享链接（可选用户）
#   5) 用户管理  - 列出 / 添加 / 删除 / 查看某用户分享链接
#
# 适用系统：Debian 11/12/13、Ubuntu 20.04/22.04/24.04
# ============================================================================

set -euo pipefail   # -e 出错退出；-u 未定义变量报错；-o pipefail 管道任一失败即失败

# ----------------------------------------------------------------------------
# 颜色定义（用于终端输出美化）
# ----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ----------------------------------------------------------------------------
# 输出辅助函数
# ----------------------------------------------------------------------------
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }    # 普通信息（绿）
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }   # 警告（黄）
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }  # 错误并退出（红）
step()  { echo -e "\n${BLUE}===== $* =====${NC}"; }   # 步骤分隔（蓝）

# ----------------------------------------------------------------------------
# 权限检查：必须以 root 运行
# ----------------------------------------------------------------------------
[[ $EUID -ne 0 ]] && error "请使用 root 用户运行，或先执行: sudo -i"

# ----------------------------------------------------------------------------
# 发行版检测：仅允许 Debian / Ubuntu
# ----------------------------------------------------------------------------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu)
      info "系统: ${PRETTY_NAME:-$ID}"
      ;;
    *)
      error "本脚本仅支持 Debian / Ubuntu，当前系统: ${PRETTY_NAME:-未知}"
      ;;
  esac
else
  error "无法识别系统（缺少 /etc/os-release）"
fi

# ----------------------------------------------------------------------------
# 全局变量（路径与常量）
# ----------------------------------------------------------------------------
USERS_FILE=/etc/reality-caddy/users.txt   # 用户列表（UUID|EMAIL|备注）
INFO_FILE=/etc/reality-caddy/info.txt     # 安装信息（域名、密钥、端口等）
XRAY_CONF=/usr/local/etc/xray/config.json # Xray 主配置
LOG_RETENTION_DAYS=7                      # 日志保留天数
CADDY_BIN=""                              # Caddy 可执行文件路径（运行时探测）

# ============================================================================
# 主菜单
# ============================================================================
show_menu() {
  clear
  echo -e "${CYAN}"
  cat <<'EOF'
  ╔══════════════════════════════════════════════════╗
  ║   Xray Reality + Vision + Caddy 管理脚本         ║
  ╠══════════════════════════════════════════════════╣
  ║   1) 安装                                        ║
  ║   2) 卸载                                        ║
  ║   3) 查看状态                                    ║
  ║   4) 查看客户端参数                              ║
  ║   5) 用户管理                                    ║
  ║   0) 退出                                        ║
  ╚══════════════════════════════════════════════════╝
EOF
  echo -e "${NC}"
  read -rp "请选择 [0-5]: " CHOICE
}

# ============================================================================
# 判断是否已安装（存在 info.txt 或 caddy-json 服务即视为已装）
# ============================================================================
is_installed() {
  [[ -f "$INFO_FILE" ]] || systemctl list-unit-files 2>/dev/null | grep -q "^caddy-json.service"
}

# ============================================================================
# 安全读取 key=value 文件
#   - 跳过空行与注释
#   - 去掉值两端的单/双引号
#   - 通过 printf -v 赋值，避免 eval 注入
# 用法: load_kv /path/to/file
# ============================================================================
load_kv() {
  local FILE=$1
  [[ ! -f "$FILE" ]] && return 1
  while IFS='=' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    key=$(echo "$key" | xargs)           # 去 key 两端空白
    value=${value%\"}; value=${value#\"} # 去双引号
    value=${value%\'}; value=${value#\'} # 去单引号
    printf -v "$key" '%s' "$value"       # 动态赋值
  done < "$FILE"
  return 0
}

# ============================================================================
# 根据 users.txt 生成 Xray 的 clients JSON 数组片段
# 输出示例:
#   [
#     {
#       "id": "uuid-1",
#       "email": "alice@example.com",
#       "flow": "xtls-rprx-vision"
#     },
#     ...
#   ]
# ============================================================================
build_clients_json() {
  [[ ! -f "$USERS_FILE" ]] && { echo '[]'; return; }
  local first=1
  echo "["
  while IFS='|' read -r uuid email note; do
    [[ -z "$uuid" || "$uuid" =~ ^# ]] && continue
    [[ $first -eq 0 ]] && echo ","   # 非首个元素前加逗号
    first=0
    printf '          {\n'
    printf '            "id": "%s",\n' "$uuid"
    printf '            "email": "%s",\n' "${email:-user@local}"
    printf '            "flow": "xtls-rprx-vision"\n'
    printf '          }'
  done < "$USERS_FILE"
  echo
  echo "        ]"
}

# ============================================================================
# 用 info.txt + users.txt 重建 Xray config.json
# 成功后执行 xray -test 校验；失败返回 1
# ============================================================================
rebuild_xray_config() {
  load_kv "$INFO_FILE" || error "未找到 $INFO_FILE，请先安装"

  mkdir -p "$(dirname "$XRAY_CONF")"
  local CLIENTS_JSON
  CLIENTS_JSON=$(build_clients_json)

  cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT:-443},
      "protocol": "vless",
      "settings": {
        "clients": ${CLIENTS_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:8003",
          "xver": 0,
          "serverNames": [
            "${DOMAIN}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake": 5,
        "connIdle": 300
      }
    }
  }
}
EOF

  # 校验配置合法性
  if ! xray -test -config "$XRAY_CONF" >/dev/null 2>&1; then
    warn "Xray 配置校验失败，输出："
    xray -test -config "$XRAY_CONF" || true
    return 1
  fi
  return 0
}

# ============================================================================
# 处理常见 80/443 端口占用
#   - 停用 nginx / apache2 / 默认 caddy 服务
#   - 打印仍被占用的端口，便于人工排查
# ============================================================================
handle_common_occupiers() {
  step "检测并处理常见端口占用"

  # 停止 Nginx（若在运行）
  systemctl is-active --quiet nginx 2>/dev/null && {
    warn "停止 Nginx"
    systemctl stop nginx
    systemctl disable nginx
  }

  # 停止 Apache2（若在运行）
  systemctl is-active --quiet apache2 2>/dev/null && {
    warn "停止 Apache2"
    systemctl stop apache2
    systemctl disable apache2
  }
  # 停止 Apache2 的 socket 激活（Ubuntu 常见）
  systemctl stop apache2.socket 2>/dev/null || true
  systemctl disable apache2.socket 2>/dev/null || true

  # 停用 apt 安装自带的 caddy 服务（避免抢 80/443）
  systemctl stop caddy.service 2>/dev/null || true
  systemctl disable caddy.service 2>/dev/null || true

  # 检查 80/443 是否仍被占
  if ss -tlnp 2>/dev/null | grep -qE ':(80|443)\b'; then
    warn "80/443 仍被占用："
    ss -tlnp | grep -E ':(80|443)' || true
  else
    info "80/443 端口空闲"
  fi
}

# ============================================================================
# 配置日志保留策略（默认 7 天）
#   - journald: /etc/systemd/journald.conf.d/99-retention.conf
#   - Xray 文件日志: /etc/tmpfiles.d/xray-log.conf
# ============================================================================
configure_log_retention() {
  step "配置日志保留策略（${LOG_RETENTION_DAYS} 天）"

  # --- journald 保留策略 ---
  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/99-retention.conf <<EOF
[Journal]
Storage=persistent
MaxRetentionSec=${LOG_RETENTION_DAYS}day
SystemMaxUse=500M
RuntimeMaxUse=100M
SystemMaxFileSize=50M
RuntimeMaxFileSize=20M
SystemMaxFiles=20
RuntimeMaxFiles=10
MaxFileSec=1day
EOF

  # 确保 journal 目录存在并持久化
  mkdir -p /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
  systemctl restart systemd-journald
  # 立即清理一次，只保留最近 N 天
  journalctl --vacuum-time=${LOG_RETENTION_DAYS}d >/dev/null 2>&1 || true

  # --- Xray 文件日志清理规则（按 mtime 删 > N 天的文件） ---
  mkdir -p /var/log/xray
  cat > /etc/tmpfiles.d/xray-log.conf <<EOF
d /var/log/xray 0755 root root -
e /var/log/xray - - - ${LOG_RETENTION_DAYS}d
EOF
  systemd-tmpfiles --create 2>/dev/null || true
  systemctl enable systemd-tmpfiles-clean.timer 2>/dev/null || true
  systemctl start  systemd-tmpfiles-clean.timer 2>/dev/null || true

  info "journald + Xray 文件日志保留 ${LOG_RETENTION_DAYS} 天已生效"
}

# ============================================================================
# 一、安装
# ============================================================================
do_install() {
  # ---------- 已安装检测 ----------
  local KEEP_USERS=0    # 1=保留 users.txt；0=清空
  if is_installed; then
    clear
    warn "检测到本机已安装过本方案："
    echo
    if [[ -f "$INFO_FILE" ]]; then
      load_kv "$INFO_FILE"
      echo "  域名      : ${DOMAIN:-未知}"
      echo "  端口      : ${XRAY_PORT:-未知}"
      echo "  安装时间  : ${INSTALL_TIME:-未知}"
      echo "  用户数量  : $(grep -vcE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null || echo 0)"
      echo
    fi
    echo "  1) 覆盖重装（保留 users.txt，重建配置）"
    echo "  2) 完全重装（清空用户与配置）"
    echo "  0) 返回主菜单"
    echo
    read -rp "请选择 [0-2]: " REINSTALL
    case "$REINSTALL" in
      1)
        info "将保留 /etc/reality-caddy/users.txt，覆盖其他配置"
        KEEP_USERS=1
        ;;
      2)
        read -rp "确认清空用户与配置？输入 yes 继续: " C
        [[ "$C" != "yes" ]] && { info "已取消"; read -rp "按回车返回..." _; return; }
        info "将清空用户与配置"
        KEEP_USERS=0
        ;;
      *)
        info "已取消"; read -rp "按回车返回..." _; return
        ;;
    esac
  fi

  # ---------- 参数配置（交互式） ----------
  step "参数配置"

  read -rp "请输入你的域名 (例如: example.com): " DOMAIN
  [[ -z "$DOMAIN" ]] && error "域名不能为空"

  read -rp "请输入用于 ACME 的邮箱 (例如: admin@example.com): " EMAIL
  [[ -z "$EMAIL" ]] && error "邮箱不能为空"

  read -rp "请输入伪装站标题 (默认: Welcome): " SITE_TITLE
  SITE_TITLE=${SITE_TITLE:-Welcome}

  read -rp "请输入 Xray 监听端口 (默认 443): " XRAY_PORT
  XRAY_PORT=${XRAY_PORT:-443}

  info "参数已录入"

  # 静默检查域名解析（不打印真实 IP，仅警告）
  if command -v dig >/dev/null 2>&1; then
    RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
    [[ -z "$RESOLVED_IP" ]] && warn "域名解析失败，证书申请可能不成功"
  fi

  # 生成初始 UUID（若完全重装会被写入 users.txt；覆盖重装时仅作兜底）
  UUID=$(cat /proc/sys/kernel/random/uuid)
  info "自动生成 UUID: $UUID"

  # ---------- 安装基础依赖 ----------
  step "安装基础依赖"
  export DEBIAN_FRONTEND=noninteractive   # 避免交互式弹窗
  apt-get update -y
  apt-get install -y sudo debian-keyring debian-archive-keyring apt-transport-https \
    curl gnupg lsb-release ca-certificates openssl dnsutils

  # ---------- 安装 Caddy ----------
  step "安装 Caddy"
  if [[ ! -x "$CADDY_BIN" ]] && ! command -v caddy >/dev/null 2>&1; then
    # 添加 Caddy 官方 GPG key
    if [[ ! -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg ]]; then
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    fi
    # 添加 Caddy APT 源
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -y
    apt-get install -y caddy || true
    # 兜底：dpkg 认为已装但文件丢失时强制重装
    if ! command -v caddy >/dev/null 2>&1; then
      warn "/usr/bin/caddy 不存在，执行强制重装"
      apt-get install --reinstall -y caddy
    fi
  fi

  # 动态探测 Caddy 路径
  CADDY_BIN=$(command -v caddy || true)
  [[ -z "$CADDY_BIN" || ! -x "$CADDY_BIN" ]] && error "Caddy 安装失败"
  info "Caddy 可用: $($CADDY_BIN version)"

  # ---------- 安装 Xray ----------
  step "安装 Xray"
  if [[ ! -x /usr/local/bin/xray ]]; then
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
  fi

  # ---------- 端口占用 + 日志保留 ----------
  handle_common_occupiers
  configure_log_retention

  # ---------- 生成 Reality 密钥对 ----------
  step "生成 Reality 密钥"
  X25519_OUT=$(xray x25519)
  PRIVATE_KEY=$(echo "$X25519_OUT" | grep -i "private" | awk '{print $NF}')
  PUBLIC_KEY=$(echo "$X25519_OUT"  | grep -i "public"  | awk '{print $NF}')
  # 兼容不同版本 xray x25519 的输出格式
  [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]] && {
    PRIVATE_KEY=$(echo "$X25519_OUT" | sed -n '1p' | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$X25519_OUT"  | sed -n '2p' | awk '{print $NF}')
  }
  # 随机 8 字节 shortId（16 位十六进制）
  SHORT_ID=$(openssl rand -hex 8)

  # ---------- 初始用户 ----------
  step "创建初始用户"
  mkdir -p /etc/reality-caddy

  if [[ "${KEEP_USERS:-0}" == "1" && -s "$USERS_FILE" ]]; then
    info "保留已有用户（$(grep -vcE '^\s*(#|$)' "$USERS_FILE") 个），不创建默认用户"
  else
    : > "$USERS_FILE"
    echo "${UUID}|default|初始用户" >> "$USERS_FILE"
    info "已创建默认用户 default"
  fi
  chmod 600 "$USERS_FILE"

  # ---------- 保存安装信息 ----------
  INSTALL_TIME=$(date '+%Y-%m-%d %H:%M:%S')
  cat > "$INFO_FILE" <<EOF
DOMAIN="${DOMAIN}"
EMAIL="${EMAIL}"
SITE_TITLE="${SITE_TITLE}"
XRAY_PORT="${XRAY_PORT}"
PRIVATE_KEY="${PRIVATE_KEY}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
INSTALL_TIME="${INSTALL_TIME}"
EOF
  chmod 600 "$INFO_FILE"

  # ---------- Caddy 配置 ----------
  step "配置 Caddy"
  mkdir -p /etc/caddy
  cat > /etc/caddy/caddy.json <<EOF
{
  "apps": {
    "http": {
      "servers": {
        "srvh1": {
          "listen": [":80"],
          "routes": [{
            "handle": [{
              "handler": "static_response",
              "headers": {
                "Location": ["https://{http.request.host}{http.request.uri}"]
              },
              "status_code": 301
            }]
          }],
          "protocols": ["h1"]
        },
        "srvh2": {
          "listen": ["127.0.0.1:8003"],
          "listener_wrappers": [{
            "wrapper": "proxy_protocol",
            "allow": ["127.0.0.1/32"]
          }, {
            "wrapper": "tls"
          }],
          "routes": [{
            "handle": [{
                "handler": "headers",
                "response": {
                  "set": {
                    "Strict-Transport-Security": ["max-age=31536000; includeSubDomains; preload"],
                    "Alt-Svc": ["h3=\":443\"; ma=2592000"]
                  }
                }
              },
              {
                "handler": "file_server",
                "root": "/var/www/html"
              }
            ]
          }],
          "tls_connection_policies": [{
            "match": {
              "sni": ["${DOMAIN}"]
            },
            "cipher_suites": [
              "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
              "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256",
              "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256"
            ],
            "curves": ["x25519", "secp521r1", "secp384r1", "secp256r1"],
            "alpn": ["h3", "h2", "http/1.1"]
          }],
          "protocols": ["h1", "h2", "h3"]
        }
      }
    },
    "tls": {
      "certificates": {
        "automate": ["${DOMAIN}"]
      },
      "automation": {
        "policies": [{
          "issuers": [{
            "module": "acme",
            "email": "${EMAIL}"
          }]
        }]
      }
    }
  }
}
EOF

  # 校验 Caddy 配置
  "$CADDY_BIN" validate --config /etc/caddy/caddy.json >/dev/null 2>&1 \
    || { "$CADDY_BIN" validate --config /etc/caddy/caddy.json || true; error "Caddy 配置校验失败"; }
  info "Caddy 配置校验通过"

  # ---------- 伪装站（含内联 SVG favicon） ----------
  step "创建伪装站点"
  mkdir -p /var/www/html
  local FIRST_CHAR="${SITE_TITLE:0:1}"   # 取标题首字母作为 favicon 字符
  local FAVICON_SVG="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Crect width='100' height='100' rx='20' fill='%23667eea'/%3E%3Ctext x='50' y='68' font-size='56' text-anchor='middle' fill='white' font-family='Arial'%3E${FIRST_CHAR}%3C/text%3E%3C/svg%3E"

  cat > /var/www/html/index.html <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>${SITE_TITLE}</title>
  <link rel="icon" type="image/svg+xml" href="${FAVICON_SVG}">
  <link rel="apple-touch-icon" href="${FAVICON_SVG}">
  <style>
    body { font-family: -apple-system, "Segoe UI", Arial, sans-serif; display:flex;
           align-items:center; justify-content:center; height:100vh; margin:0;
           background:linear-gradient(135deg,#667eea,#764ba2); color:#fff; }
    .box { text-align:center; }
    h1 { font-size:3rem; margin:0; }
    p  { opacity:.85; }
  </style>
</head>
<body>
  <div class="box">
    <h1>${SITE_TITLE}</h1>
    <p>It works!</p>
  </div>
</body>
</html>
EOF
  info "伪装站点已创建（含内联 favicon）"

  # ---------- Caddy systemd 服务 ----------
  step "配置 Caddy systemd"
  cat > /etc/systemd/system/caddy-json.service <<EOF
[Unit]
Description=Caddy JSON Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${CADDY_BIN} run --config /etc/caddy/caddy.json
Restart=always
RestartSec=3
User=root
WorkingDirectory=/etc/caddy
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable caddy-json.service
  info "caddy-json.service 已启用"

  # ---------- Xray 配置 ----------
  step "配置 Xray"
  rebuild_xray_config || error "Xray 配置生成失败"
  systemctl enable xray
  systemctl restart xray

  # ---------- 启动 Caddy ----------
  step "启动 Caddy"
  systemctl stop caddy-json.service 2>/dev/null || true
  systemctl start caddy-json.service

  # 等待 Caddy 启动并完成首次证书申请（最长 30 秒）
  info "等待 Caddy 启动并申请证书（最多 30 秒）..."
  for i in $(seq 1 30); do
    systemctl is-active --quiet caddy-json.service && \
      ss -tln 2>/dev/null | grep -q '127.0.0.1:8003' && break
    sleep 1
  done

  # ---------- 安装后自检 ----------
  step "安装后自检"
  systemctl is-active --quiet caddy-json.service \
    && info "caddy-json.service: 运行中" \
    || warn "caddy-json.service: 未运行 → journalctl -u caddy-json.service -n 80 --no-pager"
  systemctl is-active --quiet xray \
    && info "xray.service: 运行中" \
    || warn "xray.service: 未运行 → journalctl -u xray -n 80 --no-pager"

  echo
  ss -tlnp 2>/dev/null | grep -E ':(80|443|8003)\b' || warn "未发现预期端口监听"

  echo
  # 本地 curl 测试伪装站（通过 --resolve 绕过 DNS）
  if curl -sk --max-time 5 --resolve "${DOMAIN}:8003:127.0.0.1" "https://${DOMAIN}:8003/" | head -n 3; then
    info "Caddy 本地伪装站响应正常"
  else
    warn "Caddy 本地伪装站无响应"
  fi

  echo
  echo -e "${CYAN}--- 日志保留 ---${NC}"
  journalctl --disk-usage 2>/dev/null || true

  show_client_info
  info "安装完成！建议 reboot 一次。"
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 二、卸载
# ============================================================================
do_uninstall() {
  if ! is_installed; then
    warn "尚未安装，无需卸载"
    read -rp "按回车返回..." _
    return
  fi

  echo
  warn "即将卸载："
  if [[ -f "$INFO_FILE" ]]; then
    load_kv "$INFO_FILE"
    echo "  域名      : ${DOMAIN:-未知}"
    echo "  端口      : ${XRAY_PORT:-未知}"
    echo "  用户数量  : $(grep -vcE '^\s*(#|$)' "$USERS_FILE" 2>/dev/null || echo 0)"
    echo
  fi
  read -rp "确认卸载？输入 yes 继续: " CONFIRM
  [[ "$CONFIRM" != "yes" ]] && { info "已取消"; read -rp "按回车返回..." _; return; }

  # 停止并删除服务
  systemctl stop caddy-json.service 2>/dev/null || true
  systemctl disable caddy-json.service 2>/dev/null || true
  rm -f /etc/systemd/system/caddy-json.service

  systemctl stop xray 2>/dev/null || true
  systemctl disable xray 2>/dev/null || true
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf /etc/systemd/system/xray.service.d

  systemctl daemon-reload

  # 卸载 Caddy
  dpkg -l | grep -q "^ii  caddy " && apt-get purge -y caddy || true
  rm -f /etc/apt/sources.list.d/caddy-stable.list
  rm -f /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  rm -rf /etc/caddy /var/lib/caddy /var/log/caddy
  rm -f /usr/bin/caddy

  # 卸载 Xray（官方卸载脚本）
  [[ -f /usr/local/bin/xray ]] && \
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ remove --purge || true
  rm -rf /usr/local/etc/xray /usr/local/share/xray /var/log/xray
  rm -f /usr/local/bin/xray

  # 可选：移除日志保留策略
  read -rp "移除日志保留策略 (journald 99-retention.conf + tmpfiles xray-log.conf) ? [y/N]: " DEL_LOG
  if [[ "${DEL_LOG,,}" == "y" ]]; then
    rm -f /etc/systemd/journald.conf.d/99-retention.conf
    rm -f /etc/tmpfiles.d/xray-log.conf
    systemctl restart systemd-journald 2>/dev/null || true
    info "已移除日志保留策略"
  else
    info "保留日志保留策略"
  fi

  # 可选：删除伪装站
  read -rp "删除伪装站点 /var/www/html ? [y/N]: " DEL_WWW
  [[ "${DEL_WWW,,}" == "y" ]] && rm -rf /var/www/html && info "已删除 /var/www/html" || info "保留 /var/www/html"

  # 可选：删除安装信息
  read -rp "删除安装信息 /etc/reality-caddy ? [y/N]: " DEL_INFO
  [[ "${DEL_INFO,,}" == "y" ]] && rm -rf /etc/reality-caddy && info "已删除 /etc/reality-caddy" || info "保留 /etc/reality-caddy"

  warn "可执行 apt-get autoremove -y && apt-get clean 进一步清理"
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 三、查看状态
# ============================================================================
do_status() {
  clear
  if ! is_installed; then
    warn "尚未安装，请先选择 1) 安装"
    read -rp "按回车返回..." _
    return
  fi

  step "服务状态"

  echo -e "${CYAN}--- Xray ---${NC}"
  systemctl list-unit-files | grep -q "^xray.service" \
    && systemctl status xray --no-pager -l | head -n 12 \
    || warn "xray.service 未安装"

  echo
  echo -e "${CYAN}--- Caddy (caddy-json) ---${NC}"
  systemctl list-unit-files | grep -q "^caddy-json.service" \
    && systemctl status caddy-json.service --no-pager -l | head -n 12 \
    || warn "caddy-json.service 未安装"

  echo
  echo -e "${CYAN}--- 端口 ---${NC}"
  ss -tlnp 2>/dev/null | grep -E ':(80|443|8003)\b' || echo "未发现 80/443/8003 监听"

  echo
  echo -e "${CYAN}--- 版本 ---${NC}"
  command -v xray  >/dev/null 2>&1 && xray version | head -n1 || echo "Xray: 未安装"
  command -v caddy >/dev/null 2>&1 && caddy version          || echo "Caddy: 未安装"

  echo
  echo -e "${CYAN}--- 日志保留 ---${NC}"
  if [[ -f /etc/systemd/journald.conf.d/99-retention.conf ]]; then
    grep -E 'MaxRetentionSec|SystemMaxUse' /etc/systemd/journald.conf.d/99-retention.conf
    journalctl --disk-usage 2>/dev/null || true
  else
    echo "未配置日志保留策略"
  fi

  echo
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 四、查看客户端参数（可选用户）
# ============================================================================
show_client_info() {
  load_kv "$INFO_FILE" || { warn "未找到 $INFO_FILE"; return 1; }

  # 从 users.txt 选择用户
  local uuid="" email=""
  if [[ -f "$USERS_FILE" ]]; then
    echo
    echo "可用用户："
    local i=1
    local -a UUIDS=() EMAILS=()
    while IFS='|' read -r u e n; do
      [[ -z "$u" || "$u" =~ ^# ]] && continue
      UUIDS+=("$u"); EMAILS+=("$e")
      printf "  %d) %s (%s) %s\n" "$i" "$e" "$u" "${n:-}"
      ((i++))
    done < "$USERS_FILE"

    if [[ ${#UUIDS[@]} -gt 0 ]]; then
      read -rp "选择用户编号 (默认 1): " SEL
      SEL=${SEL:-1}
      if [[ "$SEL" =~ ^[0-9]+$ ]] && (( SEL >= 1 && SEL <= ${#UUIDS[@]} )); then
        uuid="${UUIDS[$((SEL-1))]}"
        email="${EMAILS[$((SEL-1))]}"
      else
        uuid="${UUIDS[0]}"; email="${EMAILS[0]}"
      fi
    fi
  fi
  [[ -z "$uuid" ]] && uuid="${UUID:-}"   # 兜底：使用 info.txt 里的旧 UUID

  echo
  echo -e "${CYAN}==================== 客户端配置参数 ====================${NC}"
  cat <<EOF
协议        : VLESS地址        : ${DOMAIN}
端口        : ${XRAY_PORT:-443}
UUID        : ${uuid}
用户标识    : ${email}
流控 (flow) : xtls-rprx-vision
传输协议    : tcp
安全        : reality
SNI         : ${DOMAIN}
Fingerprint : chrome
PublicKey   : ${PUBLIC_KEY}
ShortId     : ${SHORT_ID}
SpiderX     : /

${CYAN}==================== VLESS 分享链接 ====================${NC}
vless://${uuid}@${DOMAIN}:${XRAY_PORT:-443}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email:-${DOMAIN}}

${CYAN}=======================================================${NC}
伪装站点    : https://${DOMAIN}
Xray 配置   : /usr/local/etc/xray/config.json
Caddy 配置  : /etc/caddy/caddy.json
伪装站目录  : /var/www/html
安装时间    : ${INSTALL_TIME:-未知}
日志保留    : ${LOG_RETENTION_DAYS} 天
${CYAN}=======================================================${NC}
EOF
}

do_show_client() {
  clear
  if ! is_installed; then
    warn "尚未安装，请先选择 1) 安装"
    read -rp "按回车返回..." _
    return
  fi
  show_client_info || true
  echo
  read -rp "按回车返回主菜单..." _
}

# ============================================================================
# 五、用户管理
# ============================================================================
users_menu() {
  if ! is_installed; then
    warn "尚未安装，请先选择 1) 安装"
    read -rp "按回车返回..." _
    return
  fi

  while true; do
    clear
    echo -e "${CYAN}"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════╗
  ║   用户管理                                       ║
  ╠══════════════════════════════════════════════════╣
  ║   1) 列出用户                                    ║
  ║   2) 添加用户                                    ║
  ║   3) 删除用户                                    ║
  ║   4) 查看某用户分享链接                          ║
  ║   0) 返回主菜单                                  ║
  ╚══════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    read -rp "请选择 [0-4]: " UC
    case "$UC" in
      1) users_list ;;
      2) users_add ;;
      3) users_del ;;
      4) users_show ;;
      0) return ;;
      *) warn "无效选择"; sleep 1 ;;
    esac
  done
}

# 打印用户列表（不等待输入，供其他函数调用）
users_list_noread() {
  printf "%-4s %-40s %-24s %s\n" "No." "UUID" "标识" "备注"
  printf "%-4s %-40s %-24s %s\n" "----" "----------------------------------------" "------------------------" "----"
  local i=1
  while IFS='|' read -r u e n; do
    [[ -z "$u" || "$u" =~ ^# ]] && continue
    printf "%-4s %-40s %-24s %s\n" "$i" "$u" "$e" "${n:-}"
    ((i++))
  done < "$USERS_FILE"
}

# 列出用户（等待回车）
users_list() {
  clear
  step "用户列表"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"
  else
    users_list_noread
  fi
  echo
  read -rp "按回车返回..." _
}

# 添加用户
users_add() {
  clear
  step "添加用户"
  read -rp "用户标识 email (例如 alice@example.com，可空): " EMAIL
  read -rp "备注 note (可空): " NOTE
  EMAIL=${EMAIL:-user$(date +%s)@local}   # 空则用时间戳生成

  # 邮箱去重提醒
  if [[ -f "$USERS_FILE" ]] && grep -q "|${EMAIL}|" "$USERS_FILE" 2>/dev/null; then
    warn "已存在相同标识的用户：$EMAIL"
    read -rp "仍要添加？[y/N]: " C
    [[ "${C,,}" != "y" ]] && { info "已取消"; read -rp "按回车返回..." _; return; }
  fi

  local UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)

  mkdir -p /etc/reality-caddy
  touch "$USERS_FILE"
  chmod 600 "$USERS_FILE"
  echo "${UUID}|${EMAIL}|${NOTE}" >> "$USERS_FILE"

  info "已添加用户：$EMAIL ($UUID)"

  # 重建配置并重启 Xray
  if rebuild_xray_config; then
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray && info "Xray 已重启，用户生效" || warn "Xray 重启失败：journalctl -u xray -n 50 --no-pager"
  else
    warn "配置生成失败，已回滚最后一行"
    sed -i '$ d' "$USERS_FILE"
  fi

  echo
  read -rp "按回车返回..." _
}

# 删除用户
users_del() {
  clear
  step "删除用户"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"; read -rp "按回车返回..." _; return
  fi

  users_list_noread

  read -rp "输入要删除的用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; read -rp "按回车返回..." _; return; }

  local total
  total=$(grep -vcE '^\s*(#|$)' "$USERS_FILE" || true)
  (( IDX < 1 || IDX > total )) && { warn "编号越界"; read -rp "按回车返回..." _; return; }

  local target_email
  target_email=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p" | cut -d'|' -f2)

  read -rp "确认删除用户 $target_email ? [y/N]: " C
  [[ "${C,,}" != "y" ]] && { info "已取消"; read -rp "按回车返回..." _; return; }

  # 备份后按编号删除对应行
  cp "$USERS_FILE" "${USERS_FILE}.bak"
  awk -v n="$IDX" '
    BEGIN { c=0 }
    /^\s*(#|$)/ { print; next }
    { c++; if (c==n) next; print }
  ' "${USERS_FILE}.bak" > "$USERS_FILE"

  info "已删除用户 $target_email"

  if rebuild_xray_config; then
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray && info "Xray 已重启" || warn "Xray 重启失败"
  else
    warn "配置生成失败，已恢复备份"
    cp "${USERS_FILE}.bak" "$USERS_FILE"
  fi
  rm -f "${USERS_FILE}.bak"

  echo
  read -rp "按回车返回..." _
}

# 查看某用户分享链接
users_show() {
  clear
  step "查看某用户分享链接"
  if [[ ! -f "$USERS_FILE" || ! -s "$USERS_FILE" ]]; then
    warn "无用户"; read -rp "按回车返回..." _; return
  fi
  users_list_noread
  read -rp "输入用户编号: " IDX
  [[ ! "$IDX" =~ ^[0-9]+$ ]] && { warn "无效编号"; read -rp "按回车返回..." _; return; }

  local line uuid email
  line=$(grep -vE '^\s*(#|$)' "$USERS_FILE" | sed -n "${IDX}p")
  [[ -z "$line" ]] && { warn "编号越界"; read -rp "按回车返回..." _; return; }
  uuid=$(echo "$line" | cut -d'|' -f1)
  email=$(echo "$line" | cut -d'|' -f2)

  load_kv "$INFO_FILE" || { warn "未找到 $INFO_FILE"; read -rp "按回车返回..." _; return; }

  echo
  echo -e "${CYAN}==================== 用户 $email ====================${NC}"
  cat <<EOF
协议        : VLESS
地址        : ${DOMAIN}
端口        : ${XRAY_PORT:-443}
UUID        : ${uuid}
流控 (flow) : xtls-rprx-vision
传输协议    : tcp
安全        : reality
SNI         : ${DOMAIN}
Fingerprint : chrome
PublicKey   : ${PUBLIC_KEY}
ShortId     : ${SHORT_ID}
SpiderX     : /

${CYAN}==================== VLESS 分享链接 ====================${NC}
vless://${uuid}@${DOMAIN}:${XRAY_PORT:-443}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#Reality-${email}
EOF
  echo
  read -rp "按回车返回..." _
}

# ============================================================================
# 主循环
# ============================================================================
while true; do
  show_menu
  case "$CHOICE" in
    1) do_install ;;
    2) do_uninstall ;;
    3) do_status ;;
    4) do_show_client ;;
    5) users_menu ;;
    0) info "再见！"; exit 0 ;;
    *) warn "无效选择"; sleep 1 ;;
  esac
doneis_installed
