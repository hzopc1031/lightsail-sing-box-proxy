# sing-box 一键部署脚本（Hysteria2 + VLESS REALITY）

这是一套在 Debian 上安装并配置官方 [sing-box](https://sing-box.sagernet.org) 的一键部署脚本，不是从零实现的代理协议。同一台服务器会同时提供：

- **Hysteria2**：UDP，默认端口 443
- **VLESS + REALITY**：TCP，端口 443（写在脚本里，没有单独的端口变量）

实际旧服验证环境是 **Debian GNU/Linux 11**（bullseye），AWS Lightsail，区域 `ap-northeast-1`，官方 sing-box **1.13.14**。本教程计划选择 **Debian 12**，但 Debian 12 **尚未验证**。下面的命令说明对应脚本当前行为，不是一次新的安装实测。

密钥在首次运行时生成，写在服务器本地的 `/cloud/service/vpnProxy/state/server.env`。不要把真实配置或分享链接提交到 Git。

## 前置条件

1. 一台 **AWS Lightsail** 上的 **Debian** 实例，并且有公网 IPv4。旧服验证的是 Debian 11；计划使用 Debian 12，但尚未验证。
2. 用 Lightsail 控制台提供的方式 **SSH 登录** 这台实例。下面的命令都在这台服务器上执行。
3. 在 Lightsail 实例的 **Networking** 防火墙里放行（这一层脚本不会改，和系统里的 iptables / ufw 是分开的）：
   - **TCP 22**（SSH）
   - **TCP 443**（VLESS + REALITY）
   - **UDP 443**（Hysteria2；只有改了下面的 `HYSTERIA2_PORT` 时，才改为放行那个 UDP 端口）
4. 准备一个伪装域名，用作 REALITY 的 SNI，以及 Hysteria2 自签证书的 CN。它应是公网可访问、且在 443 端口提供 TLS 的网站主机名。不要把字面值 `YOUR_SNI` 留给脚本。

脚本只读取这几个环境变量，没有命令行参数：

| 变量 | 默认值 | 脚本实际用它做什么 |
| --- | --- | --- |
| `SNI` | `YOUR_SNI` | 证书 CN / SAN、REALITY 的 `server_name` 和 `handshake.server`、两条分享链接里的 `sni` |
| `HYSTERIA2_PORT` | `443` | Hysteria2 的 UDP 监听端口、对应分享链接端口，以及本机防火墙放行的 UDP 端口 |
| `REALITY_SERVER_PORT` | `443` | 只写入 REALITY `handshake.server_port`。VLESS 监听端口仍是 443 |
| `REALITY_DEST` | `YOUR_SNI:443` | 只写入 `state/server.env`。当前 `write_config` 不用它，握手目标用的是 `SNI` |

## 一键安装

先导出伪装域名（把 `www.example.com` 换成你自己的），再执行脚本。`sudo -E` 会把这些变量带进 root 环境；脚本在非 root 下自行提权时用的也是 `sudo -E`。不带 `-E` 的 `sudo` 会丢掉 `SNI`，脚本就会使用默认值 `YOUR_SNI`。

用 git 克隆整个仓库：

```bash
git clone https://github.com/hzopc1031/lightsail-sing-box-proxy.git
cd lightsail-sing-box-proxy
export SNI="www.example.com"
sudo -E bash ./deploy_vpn.sh
```

或者只下载 `deploy_vpn.sh`：

```bash
curl -fsSL -o deploy_vpn.sh https://raw.githubusercontent.com/hzopc1031/lightsail-sing-box-proxy/main/deploy_vpn.sh
export SNI="www.example.com"
sudo -E bash ./deploy_vpn.sh
```

需要同时改 Hysteria2 端口时，在同一条 shell 里额外导出后再执行，例如 `export HYSTERIA2_PORT=443`。不导出则用默认 443。

## 脚本做了什么

固定目录是 `/cloud/service/vpnProxy`。要改这个路径，只能编辑 `deploy_vpn.sh` 顶部的 `PROJECT_DIR`，脚本没有别的路径参数。执行顺序与源码里的 `main` 相同：

1. 记录系统、路由、端口和现有 sing-box 状态。
2. `apt-get install`：`ca-certificates`、`curl`、`gnupg`、`lsb-release`、`openssl`、`iproute2`、`iptables`、`nftables`。
3. 添加官方 APT 源（GPG `https://sing-box.app/gpg.key`，软件源 `https://deb.sagernet.org/`）并安装 `sing-box`。
4. 若已有 `state/server.env` 则读入已有密钥、SNI 和端口；否则生成 UUID、SHORT_ID、Hysteria2 密码和 REALITY 密钥对。
5. 证书文件不存在时，用 OpenSSL 生成 RSA 4096、有效期 3650 天的自签证书（仅给 Hysteria2；没有 ACME / Let's Encrypt）。
6. 写入服务端配置 `/cloud/service/vpnProxy/server/sing-box-config.json`。
7. `sing-box check`。若因版本不支持 `xtls-rprx-vision` 而失败，会去掉 `flow` 再检查一次。
8. 配置 systemd：已有官方 `sing-box.service` 时写入 drop-in，把启动命令改成这份配置；否则新建单元。然后 `daemon-reload` 并 `enable`。
9. 本机防火墙：ufw 已启用时放行 22/tcp、443/tcp 和 Hysteria2 的 UDP 端口；nftables 处于 active 时不改规则，只提示你自己放行；否则尝试添加运行时 iptables 规则（不一定重启后还在）。
10. 在 `/cloud/service/vpnProxy/clients/` 生成客户端 JSON、分享链接和说明。
11. `systemctl restart sing-box`，并检查版本、配置和监听端口。

服务实际读取的是 `/cloud/service/vpnProxy/server/sing-box-config.json`，不是 `/etc/sing-box/config.json`。安装日志在 `/cloud/service/vpnProxy/logs/deploy-<UTC时间>.log`。

## 生成文件的位置

| 路径 | 内容 |
| --- | --- |
| `/cloud/service/vpnProxy/server/sing-box-config.json` | 服务端配置，模式 600 |
| `/cloud/service/vpnProxy/server/tls/hysteria2.crt` | Hysteria2 自签证书 |
| `/cloud/service/vpnProxy/server/tls/hysteria2.key` | 证书私钥，模式 600 |
| `/cloud/service/vpnProxy/state/server.env` | UUID、REALITY 密钥、Hysteria2 密码、SNI、端口、公网 IP，模式 600 |
| `/cloud/service/vpnProxy/clients/sing-box-vless-reality-client.json` | VLESS REALITY 的 sing-box 客户端配置 |
| `/cloud/service/vpnProxy/clients/sing-box-hysteria2-client.json` | Hysteria2 的 sing-box 客户端配置 |
| `/cloud/service/vpnProxy/clients/vless-reality-share-link.txt` | VLESS 分享链接 |
| `/cloud/service/vpnProxy/clients/hysteria2-share-link.txt` | Hysteria2 分享链接 |
| `/cloud/service/vpnProxy/clients/README.md` | 脚本写给这台服务器的连接说明 |
| `/cloud/service/vpnProxy/backups/` | 再次运行时备份的旧配置和旧客户端目录 |

`clients/` 目录模式是 700，其中文件模式是 600。脚本会尝试把该目录交给系统用户 `admin`（Lightsail Debian 镜像上常见的登录用户）。没有这个用户时，所有权不变。

## 查看客户端配置和分享链接

SSH 登录服务器后：

```bash
sudo ls -la /cloud/service/vpnProxy/clients
sudo cat /cloud/service/vpnProxy/clients/vless-reality-share-link.txt
sudo cat /cloud/service/vpnProxy/clients/hysteria2-share-link.txt
sudo cat /cloud/service/vpnProxy/clients/sing-box-vless-reality-client.json
sudo cat /cloud/service/vpnProxy/clients/sing-box-hysteria2-client.json
```

若当前 SSH 用户就是 `admin`，并且脚本成功改过所有权，可以不加 `sudo`。把链接复制到自己的客户端即可。脚本不会把这些文件传到你的电脑，也不要把它们贴回公开仓库。

仓库里的 `config.example.json` 和 `examples/` 只是占位符样例，不是这台服务器生成的可用配置。

## 客户端用法

脚本只生成上面的 sing-box JSON 和两条分享链接。本仓库不附带 v2rayN、Shadowrocket、Clash Meta 或其他客户端。

Hysteria2 用的是自签证书。分享链接里已经带有 `insecure=1`，sing-box 客户端 JSON 里是 `"insecure": true`。导入后必须允许不安全证书（有的客户端叫 allow insecure）。不开启时 Hysteria2 连不上。

### sing-box

把对应 JSON 拷到本机后执行。VLESS 那份在本机 `127.0.0.1:2080` 提供 mixed（HTTP/SOCKS）入站，Hysteria2 那份在 `127.0.0.1:2081`。这是 JSON 里的端口，不是服务器端口。

```bash
sing-box check -c sing-box-vless-reality-client.json
sing-box run -c sing-box-vless-reality-client.json
curl -x socks5h://127.0.0.1:2080 https://ifconfig.me

sing-box check -c sing-box-hysteria2-client.json
sing-box run -c sing-box-hysteria2-client.json
curl -x socks5h://127.0.0.1:2081 https://ifconfig.me
```

### v2rayN、Shadowrocket、Clash Meta 等

客户端自己支持 VLESS REALITY 或 Hysteria2 时，导入对应的分享链接：

- VLESS：`vless-reality-share-link.txt`（TCP，REALITY，指纹 chrome，flow 为 `xtls-rprx-vision`）
- Hysteria2：`hysteria2-share-link.txt`，并允许不安全证书

Clash Meta（Mihomo）没有由本脚本生成的配置文件。需要在支持这两种协议的核心里，按链接中的地址、端口、UUID 或密码、SNI、public key、short ID 自行填写；Hysteria2 同样要允许不安全证书。

## 常用运维命令

```bash
sudo systemctl status sing-box --no-pager
sudo systemctl restart sing-box
sudo journalctl -u sing-box -n 100 --no-pager
sudo sing-box check -c /cloud/service/vpnProxy/server/sing-box-config.json
sudo ss -lntup | grep ':443'
```

正常时 `sing-box` 为 `active (running)`，并在 `0.0.0.0:443` 上同时监听 TCP 和 UDP（Hysteria2 端口若改过，UDP 行是那个端口）。

## 更新或重装

没有单独的更新命令或版本参数。在服务器上再次执行原来的安装命令即可：

```bash
sudo -E bash ./deploy_vpn.sh
```

再次执行时脚本会：

- 再次 `apt-get install -y sing-box`（官方源里若有更新的包，会被装上）
- 读入已有的 `/cloud/service/vpnProxy/state/server.env`。文件里的 UUID、密钥、密码、SNI 和端口会覆盖你这次新 export 的同名变量
- 已有服务端 JSON 复制到 `/cloud/service/vpnProxy/backups/`
- 已有 `clients/` 目录先备份，再按当前密钥重写
- 证书文件还在时不重新签发
- `systemctl restart sing-box`

要换成新的 SNI、端口或密钥，脚本没有对应参数。需要先改或移走 `state/server.env` 里的对应行；换 SNI 后若还要新证书，再移走 `server/tls/hysteria2.crt` 和 `hysteria2.key`，然后重新执行。移走整个 `server.env` 会生成一套新密钥，旧客户端链接失效。

## 卸载

脚本写给服务器的说明使用下面这组命令。它们停用并删除本脚本创建的单元和 drop-in，再卸载 `sing-box` 包：

```bash
sudo systemctl disable --now sing-box
sudo rm -f /etc/systemd/system/sing-box.service
sudo rm -rf /etc/systemd/system/sing-box.service.d
sudo systemctl daemon-reload
sudo apt-get remove -y sing-box
```

这组命令不会删除 `/cloud/service/vpnProxy` 里的配置、证书、密钥和客户端文件。确认不再需要后，再自行删除该目录。

## 常见问题

**Q: 连不上，先查什么？**  
先看 Lightsail **Networking** 里有没有放行 **UDP 443**。只放行 TCP 443 时，VLESS 可能可用，Hysteria2 不可用。然后再看客户端是否允许了不安全证书、密码和 SNI 是否与 `/cloud/service/vpnProxy/clients/` 里的文件一致。服务端日志：

```bash
sudo journalctl -u sing-box -n 100 --no-pager
```

**Q: 这是官方 hysteria 二进制吗？**  
不是。运行的是官方 `sing-box` 的 `hysteria2` inbound，没有 `hysteria-server` 服务。

**Q: 可以只安装 Hysteria2、不要 VLESS 吗？**  
不可以靠某个参数关掉。当前脚本每次都会写两个 inbound。要只留一个，需要自己改 `deploy_vpn.sh` 的 `write_config` 或生成后的 JSON，再 `sing-box check` 并重启服务。

**Q: 仓库里的 example 能直接连吗？**  
不能。那些文件里的 `YOUR_SERVER_IP`、`YOUR_PASSWORD`、`YOUR_UUID` 等都是占位符。可用的是服务器上 `clients/` 目录里生成的文件。

## License

本项目采用 [MIT](./LICENSE) 许可证。Copyright (c) 2026 hzopc1031。
