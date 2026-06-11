#!/usr/bin/env bash
# 服务器一键安装(自包含): gost relay(relay+quic 反向隧道入口) + mihomo(Hysteria2 inbound + 出口池)
# 节点(GHA/VPS)用 gost rtcp 反向把本地 socks5 映射成服务器本地端口 20000+N,
# mihomo 连 127.0.0.1:20001..20000+POOL_SIZE 组成出口池,客户端用 Hysteria2 接入。
#
# 用法:
#   sudo TOKEN=relay口令 HY2_PASSWORD=hy2密码 HY2_PORT=443 bash install_server_gost.sh
set -euo pipefail

# ---------- 可配置参数 ----------
GOST_VERSION="${GOST_VERSION:-3.2.6}"
MIHOMO_VERSION="${MIHOMO_VERSION:-1.18.10}"
TOKEN="${TOKEN:-CHANGE_ME_TOKEN}"          # relay 接入口令,节点侧 password 要一致
RELAY_PORT="${RELAY_PORT:-8443}"           # gost relay 监听端口(QUIC/UDP)
RELAY_USER="${RELAY_USER:-node}"           # relay 用户名,节点侧 username 要一致
HY2_PASSWORD="${HY2_PASSWORD:-CHANGE_ME_HY2_PASSWORD}"  # 客户端 hy2 密码
HY2_PORT="${HY2_PORT:-443}"
HY2_USER="${HY2_USER:-user}"
BASE_PORT="${BASE_PORT:-20000}"            # 端口池起点(节点反向绑定 BASE_PORT+1 .. BASE_PORT+POOL_SIZE)
POOL_SIZE="${POOL_SIZE:-60}"               # 端口池大小(要 >= 峰值节点数)
HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"   # mihomo 健康检查间隔(秒)
HEALTH_URL="${HEALTH_URL:-http://cp.cloudflare.com/generate_204}" # 探测地址(用稳的,gstatic/google 部分机房不稳)
GROUP_TYPE="${GROUP_TYPE:-load-balance}"   # 出口组类型: load-balance(逐连接/哈希分流,IP轮换) | url-test(粘住一个活节点)
STRATEGY="${STRATEGY:-round-robin}"        # load-balance 策略: round-robin(逐连接轮换) 或 consistent-hashing(同目标固定)
TOLERANCE="${TOLERANCE:-150}"              # url-test 容差(ms)

# ---------- 架构识别 ----------
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "不支持的架构: $(uname -m)"; exit 1 ;;
esac

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令: $1"; exit 1; }; }
need curl; need tar; need openssl; need gzip

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

echo "==> [1/5] 安装 gost v${GOST_VERSION} (${ARCH})"
curl -fsSL "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/gost_${GOST_VERSION}_linux_${ARCH}.tar.gz" \
  -o "$WORK/gost.tar.gz"
tar -xzf "$WORK/gost.tar.gz" -C "$WORK"
install -m 0755 "$WORK/gost" /usr/local/bin/gost

echo "==> [2/5] 写入 gost relay 配置 (relay+quic://:${RELAY_PORT}, bind=true)"
mkdir -p /etc/gost
cat > /etc/gost/config.yaml <<EOF
services:
- name: relay
  addr: ":${RELAY_PORT}"
  handler:
    type: relay
    auth:
      username: ${RELAY_USER}
      password: ${TOKEN}
    metadata:
      bind: true
  listener:
    type: quic
EOF

echo "==> [3/5] 安装 mihomo v${MIHOMO_VERSION} (${ARCH})"
curl -fsSL "https://github.com/MetaCubeX/mihomo/releases/download/v${MIHOMO_VERSION}/mihomo-linux-${ARCH}-v${MIHOMO_VERSION}.gz" \
  -o "$WORK/mihomo.gz"
gzip -d "$WORK/mihomo.gz"
install -m 0755 "$WORK/mihomo" /usr/local/bin/mihomo
mkdir -p /etc/mihomo

echo "==> [4/5] 生成自签证书 + mihomo 配置 (POOL_SIZE=${POOL_SIZE}, ${GROUP_TYPE})"
if [[ ! -f /etc/mihomo/cert.crt ]]; then
  openssl ecparam -genkey -name prime256v1 -out /etc/mihomo/cert.key
  openssl req -new -x509 -days 3650 -key /etc/mihomo/cert.key \
    -out /etc/mihomo/cert.crt -subj "/CN=bing.com" \
    -addext "subjectAltName=DNS:bing.com"
fi

{
  cat <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info

listeners:
  - name: hy2-in
    type: hysteria2
    listen: 0.0.0.0
    port: ${HY2_PORT}
    users:
      ${HY2_USER}: ${HY2_PASSWORD}
    certificate: /etc/mihomo/cert.crt
    private-key: /etc/mihomo/cert.key

proxies:
EOF
  for i in $(seq 1 "$POOL_SIZE"); do
    echo "  - { name: node${i}, type: socks5, server: 127.0.0.1, port: $((BASE_PORT + i)), udp: true }"
  done
  cat <<EOF

proxy-groups:
EOF
  if [[ "$GROUP_TYPE" == "url-test" ]]; then
    cat <<EOF
  - name: exit-pool
    type: url-test
    url: ${HEALTH_URL}
    interval: ${HEALTH_INTERVAL}
    tolerance: ${TOLERANCE}
    lazy: false
    proxies:
EOF
  else
    cat <<EOF
  - name: exit-pool
    type: load-balance
    strategy: ${STRATEGY}
    url: ${HEALTH_URL}
    interval: ${HEALTH_INTERVAL}
    lazy: false
    proxies:
EOF
  fi
  for i in $(seq 1 "$POOL_SIZE"); do
    echo "      - node${i}"
  done
  cat <<EOF

rules:
  - MATCH,exit-pool
EOF
} > /etc/mihomo/config.yaml

echo "==> [5/5] 注册并启动 systemd 服务"
cat > /etc/systemd/system/gost-relay.service <<EOF
[Unit]
Description=gost relay (reverse tunnel entry)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/mihomo.service <<EOF
[Unit]
Description=mihomo proxy
After=network.target gost-relay.service

[Service]
Type=simple
ExecStart=/usr/local/bin/mihomo -d /etc/mihomo
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# 清理可能存在的旧 frps(已被 gost 取代)
systemctl disable --now frps 2>/dev/null || true

systemctl daemon-reload
systemctl enable --now gost-relay mihomo

echo ""
echo "================ 安装完成 (gost + mihomo) ================"
echo " relay 端口    : ${RELAY_PORT} (UDP, QUIC)  用户:${RELAY_USER}  口令:${TOKEN}"
echo " Hysteria2     : ${HY2_PORT}/udp  用户:${HY2_USER}  密码:${HY2_PASSWORD}"
echo " 端口池        : ${POOL_SIZE} 个 (${BASE_PORT}+1 .. ${BASE_PORT}+${POOL_SIZE})"
echo " 出口组        : ${GROUP_TYPE}$([[ "$GROUP_TYPE" == url-test ]] && echo " (容差 ${TOLERANCE}ms)" || echo " (策略 ${STRATEGY})")"
echo " 健康检查      : ${HEALTH_URL} 每 ${HEALTH_INTERVAL}s"
echo "---------------------------------------------------------"
echo " 防火墙放行    : ${RELAY_PORT}/udp(节点接入) 和 ${HY2_PORT}/udp(客户端 hy2)"
echo " 节点接入      : 用 gost rtcp 反向隧道连 本机:${RELAY_PORT},口令 ${TOKEN}"
echo " 查看状态      : systemctl status gost-relay mihomo"
echo " 看日志        : journalctl -u mihomo -f"
echo "========================================================="
