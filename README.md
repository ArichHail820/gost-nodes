# gost exit nodes (relay+quic)

用 GitHub Actions 跑一个**出口 IP 池**:每个 runner 用 gost 反向隧道(relay+quic)接入服务器,组成出口池;服务器上 mihomo 负责挑节点/轮换,客户端用 Hysteria2 接入,程序走本地 socks5。

相比 frp:服务器↔节点改用 **QUIC**,避免 frp 的 TCP-over-TCP 把 TLS ClientHello 拆段被 Akamai 这类风控识别(实测同一出口 IP,frp 被挡、gost 能过)。

## 架构

```
你的程序 → 127.0.0.1:1080(本地socks)
                 │ hy2 客户端
                 ▼
        服务器 :443 (mihomo Hysteria2 入口)
                 │
        mihomo exit-pool (round-robin 轮换)
                 │ 连本机 127.0.0.1:20001..200xx
                 ▼
        gost relay :8443 (quic, bind=true)
                 ▲ 反向隧道(节点主动拨入)
                 │
   ┌─────────────┴─────────────┐
   GHA runner1 ... GHA runner19   ← 每个一个独立出口 IP
   (各跑 gost: socks5 + rtcp 反向隧道)
```

三个角色都在哪:
- **服务器**(1 台公网 VPS):gost relay + mihomo。客户端连它、节点也连它。
- **节点**:GitHub Actions runner(本仓库的 workflow 自动拉起),或任意公网 VPS。
- **客户端**:你本地,跑 hysteria2 客户端,给程序提供 `127.0.0.1:1080`。

---

## 一、服务器搭建

一台公网 Linux VPS(amd64/arm64)。

### 1. 跑安装脚本

把本仓库的 `install_server_gost.sh` 传到服务器(scp 或 `curl` raw 链接),然后:

```bash
sudo TOKEN=你的relay口令 \
     HY2_PASSWORD=你的hy2密码 \
     HY2_PORT=443 \
     bash install_server_gost.sh
```

脚本会:装 gost relay(`relay+quic://:8443`,开 bind)+ mihomo(hy2 入口 + 出口池),生成自签证书,注册并启动 systemd。

可选参数:
- `GROUP_TYPE`:`load-balance`(默认,IP 逐连接轮换)或 `url-test`(粘住一个延迟最低的节点)。
- `STRATEGY`:load-balance 时 `round-robin`(默认)或 `consistent-hashing`(同目标固定走同一节点)。
- `POOL_SIZE`:端口池大小,默认 60(要 ≥ 峰值节点数)。
- `RELAY_PORT` 默认 8443,`HY2_PORT` 默认 443。

### 2. 放行防火墙 / 云安全组(关键)

QUIC 走 UDP,放 TCP 没用:
- **`8443/udp`** — 节点接入
- **`443/udp`** — 客户端 hy2 接入

DigitalOcean/AWS 等在控制台的安全组里加入站 UDP 规则。

### 3. 确认服务起来了

```bash
systemctl status gost-relay mihomo --no-pager | head
ss -lunp | grep 8443      # gost relay 在听 8443/udp
```

记下:**服务器公网 IP、relay 口令(TOKEN)、hy2 密码**,后面客户端和 GHA 要用。

---

## 二、GitHub Actions 节点池

### 1. 准备一个仓库

把本仓库(含 `.github/workflows/gost-node.yml`)推到你自己的 GitHub 仓库,**建议公开仓库**(Actions 免费不限量;密钥放 Secrets,不写进代码)。

```bash
git init
git add .
git commit -m "gost exit nodes"
git branch -M main
gh repo create 你的仓库名 --public --source=. --push
# 或手动 git remote add origin ... && git push -u origin main
```

### 2. 配置仓库 Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret:

| Secret | 值 |
|---|---|
| `FRP_SERVER_ADDR` | 服务器公网 IP |
| `GOST_TOKEN` | 服务器的 relay 口令(= 安装时的 `TOKEN`) |
| `PAT` | 有 `repo` + `workflow` 权限的 Personal Access Token |

命令行设也行:
```bash
gh secret set FRP_SERVER_ADDR --body "服务器IP" -R 用户名/仓库名
gh secret set GOST_TOKEN     --body "relay口令" -R 用户名/仓库名
gh secret set PAT            --body "你的PAT"   -R 用户名/仓库名
```

> **PAT 必须设**:没有它,relay 任务无法触发下一轮,这批节点(默认每个寿命 5 分钟)跑完后池子就空、客户端立刻没出口。设了 PAT 才能滚动续命、长期不空。
> 生成 PAT:GitHub → 头像 → Settings → Developer settings → Personal access tokens (classic) → 勾 `repo` + `workflow`。

### 3. 启动

Actions → "gost exit nodes" → **Run workflow**(选 main)。
之后 relay 任务每轮自动触发下一轮,无需再手动点。

### 4. 验证节点上来了(在服务器上看)

```bash
watch -n3 'ss -ltnp | grep -c ":200"'        # 绑定的端口数,应涨到接近 19
curl -x socks5h://127.0.0.1:7890 https://api.ipify.org   # 出口IP,多跑几次会轮换
```

参数都在 `.github/workflows/gost-node.yml` 的 `env` 里(节点数、寿命、端口池),要和服务器 `POOL_SIZE` 对齐。

---

## 三、客户端连接

任意机器,下载 [Hysteria2 客户端](https://github.com/apernet/hysteria/releases)。

### 1. 写客户端配置 `client.yaml`

```yaml
server: 服务器IP:443
auth: 你的hy2密码          # 与服务器 HY2_PASSWORD 一致
tls:
  insecure: true          # 自签证书必须开
  sni: bing.com           # 与服务器证书一致
socks5:
  listen: 127.0.0.1:1080
http:
  listen: 127.0.0.1:8080
```

### 2. 运行

```bash
hysteria client -c client.yaml
# Windows: hysteria-windows-amd64.exe -c client.yaml
```

看到 `connected to server` + `SOCKS5 server listening 127.0.0.1:1080` 即成功。

### 3. 让程序走代理

把抓取程序 / 浏览器的代理设成 `socks5://127.0.0.1:1080`(或 `http://127.0.0.1:8080`)。

> **别设 Windows 全局代理**:系统后台流量(如 7680 P2P)会涌进来占用节点。只让目标程序走代理。

### 4. 验证

```bash
curl.exe -x socks5h://127.0.0.1:1080 https://api.ipify.org
```
多跑几次 IP 在 GHA 节点间变化即成功。

---

## 出口轮换说明

- **`load-balance round-robin`(默认)**:逐连接换 IP。适合 USPS 单号查询这类独立请求,分摊到多个 IP。
- **`load-balance consistent-hashing`**:同一目标固定走同一节点。适合对"同会话换 IP"敏感的多步流程。
- **`url-test`**:粘住一个延迟最低的节点,等它掉线(GHA 约 5 分钟换批)才换。

切换:改服务器 `/etc/mihomo/config.yaml` 里 exit-pool 的 `type`/`strategy`,`systemctl restart mihomo`。

---

## 注意事项

- **PAT 不设 = 池子 5 分钟后空**,见上。
- **出口是 Azure 机房 IP**:GHA runner 是 Azure 段。gost 解决了拆段问题,但 Azure IP 信誉对某些站点仍可能被封。目标站点挡 Azure 段时,改用公网小厂 VPS 当节点(节点侧用配置文件跑 gost,见 workflow 里的写法),或住宅/4G 代理。
- **改强口令**:别一直用安装时的默认值;relay 口令、hy2 密码都设强的,节点 `GOST_TOKEN`、客户端 `auth` 同步。
- **节点用配置文件起 gost**,不要用 CLI 的 `rtcp://:端口/...` 紧凑写法(会把绑定地址拼成 `0.0.0.0::端口` 非法地址导致 bind 失败)。workflow 里已用配置文件方式。
- 长时间占用 GitHub runner 跑代理属灰色用法,自行评估。
