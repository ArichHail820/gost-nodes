# gost exit nodes (relay+quic)

GitHub Actions 跑出口节点池:每个 runner 用 gost 反向隧道(relay+quic)接入服务器的 gost relay,组成出口 IP 池。服务器侧 mihomo 负责挑活节点、客户端用 Hysteria2 接入。

相比 frp 版:服务器↔节点改用 **QUIC**,避免 frp 的 TCP-over-TCP 把 TLS ClientHello 拆段被 Akamai 这类风控识别(实测同一出口 IP,frp 被挡、gost 能过)。

## 部署

### 1. 服务器装 gost relay(取代 frps)

把 `install_server_gost.sh` 传到服务器跑:

```bash
sudo TOKEN=你的强口令 RELAY_PORT=8443 bash install_server_gost.sh
# 云安全组放行 8443/udp
```

mihomo 不用动(仍连 `127.0.0.1:20001..20060`)。

### 2. 配置仓库 Secrets

Settings → Secrets and variables → Actions:

| Secret | 值 |
|---|---|
| `FRP_SERVER_ADDR` | 服务器公网 IP |
| `GOST_TOKEN` | 与服务器 relay 的 `TOKEN` 一致 |
| `PAT` | 有 `repo`+`workflow` 权限的 Personal Access Token |

### 3. 启动

Actions → "gost exit nodes" → Run workflow。之后靠 relay 自接力滚动。

## 验证

服务器上:

```bash
ss -ltnp | grep -E ':200[0-9][0-9]'   # 应看到陆续有节点绑定端口
curl -x socks5h://127.0.0.1:7890 https://api.ipify.org   # 出口 IP 在节点间轮换
```

## 说明

- 节点用**配置文件**起 gost(CLI 的 `rtcp://:端口/...` 紧凑写法会把绑定地址拼成 `0.0.0.0::端口` 非法地址导致 bind 失败)。
- 绑定地址用服务器的 `127.0.0.1:端口`,只给本机 mihomo 用,不对公网暴露。
- 公开仓库 Actions 免费不限量,但密钥务必放 Secrets,别写进代码。
- 长时间占用 runner 跑代理属灰色用法,自行评估。
