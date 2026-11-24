# sing-box 一键部署脚本（Hysteria2 + VLESS REALITY）

这是一套在 Debian 上安装并配置官方 [sing-box](https://sing-box.sagernet.org) 的**一键部署脚本**，不是从零实现的代理协议。同一台服务器会同时提供：

- **Hysteria2**：监听 **UDP 443**（端口可改）
- **VLESS + REALITY**：监听 **TCP 443**

实际旧服验证环境是 **Debian GNU/Linux 11**（bullseye），AWS Lightsail，区域 `ap-northeast-1`。本教程计划选择 **Debian 12**，但 Debian 12 **尚未验证**。

脚本会生成自签 TLS 证书（仅用于 Hysteria2）、服务端配置、systemd 服务，以及客户端 JSON 和分享链接。密钥在首次运行时自动生成，并保存在服务器本地的 `state/server.env`，请不要把真实配置提交到 Git。

## 适用环境

已在下列旧服环境中实际跑通（只记录核对到的事实）：

- 系统：Debian GNU/Linux 11（bullseye），x86_64
- 云厂商：AWS（区域 `ap-northeast-1`，东京）；用户侧通过 Lightsail 控制台管理
- 代理程序：官方 `sing-box` 包，版本 **1.13.14**（APT 来源 `https://deb.sagernet.org/`）
- 实例规格：`t3.nano`（内存较小，但当前服务可正常运行）

脚本使用 `apt-get`，面向 Debian。上面是旧服已验证环境（Debian 11）。新教程计划选择 **Debian 12**，但 Debian 12 尚未验证；其他发行版、其他区域也未验证。需要 `sudo` / root。

## 安装前准备

1. 准备一台可 SSH 登录的 Debian 服务器，并已绑定公网 IPv4。
2. 在云厂商防火墙中放行（Lightsail 在实例的 **Networking** 页操作，这与系统里的 iptables 是两层，两层都要放行才进得来）：
   - TCP 22（SSH）
   - TCP 443（VLESS + REALITY）
   - UDP 443（Hysteria2；若你改了 `HYSTERIA2_PORT`，则放行对应 UDP 端口）
3. 选定一个用作 REALITY 伪装和 Hysteria2 证书 CN / SNI 的域名。它应是一个公网可访问、且在 443 端口提供 TLS 的常用网站主机名，**不要**把字面值 `YOUR_SNI` 留给脚本去签发证书。

安装前在当前 shell 导出（示例）：

```bash
export SNI="www.example.com"
export REALITY_DEST="${SNI}:443"
```

把 `www.example.com` 换成你选定的伪装站点。也可同时覆盖端口：

```bash
export REALITY_SERVER_PORT=443
export HYSTERIA2_PORT=443
```

## 安装步骤

脚本会把项目文件写到固定目录 **`/cloud/service/vpnProxy`**（服务端配置、证书、客户端文件、日志都在这里）。如需改路径，先编辑 `deploy_vpn.sh` 顶部的 `PROJECT_DIR`。

将本仓库中的 `deploy_vpn.sh` 上传到服务器后执行：

```bash
chmod +x deploy_vpn.sh
sudo -E bash ./deploy_vpn.sh
```

`sudo -E` 用来保留你在上一步导出的 `SNI` 等环境变量。脚本会自行提权；它执行的顺序与源码中的 `main` 一致：

1. `inspect_server`：记录系统、路由、端口和现有 sing-box 状态
2. `install_packages`：安装 `ca-certificates curl gnupg lsb-release openssl iproute2 iptables nftables`
3. `install_sing_box`：添加官方 APT 源（GPG：`https://sing-box.app/gpg.key`，软件源：`https://deb.sagernet.org/`）并安装 `sing-box`
4. `load_or_create_state`：若已有 `state/server.env` 则复用密钥，否则生成 UUID、SHORT_ID、Hysteria2 密码和 REALITY 密钥对
5. `ensure_cert`：若证书不存在，则用 OpenSSL 生成 RSA 4096、有效期 3650 天的自签证书（CN / SAN 使用 `SNI`，SAN 中还会写入公网 IP）
6. `write_config`：写入 `/cloud/service/vpnProxy/server/sing-box-config.json`
7. `validate_config_or_retry_without_flow`：`sing-box check`；若因版本不支持 `xtls-rprx-vision` 失败，会去掉 `flow` 再检查一次
8. `configure_systemd`：若系统已有官方 `sing-box.service`，则写入 drop-in `override.conf`，改为 `sing-box run -c /cloud/service/vpnProxy/server/sing-box-config.json`；否则创建同内容的服务单元。然后 `daemon-reload` 并 `enable`
9. `configure_firewall`：若 ufw 已启用，放行 22/tcp、443/tcp 和 Hysteria2 的 UDP 端口；若 nftables 服务处于 active，脚本 **不会改规则**，只提示你自行放行；否则尝试添加运行时 iptables 规则（不一定持久生效）
10. `write_clients`：在 `/cloud/service/vpnProxy/clients/` 生成客户端 JSON、分享链接和说明
11. `restart_service`：`systemctl restart sing-box`
12. `post_validation` / `print_finish`：检查版本、配置、端口，并提示 Lightsail 控制台还要放行的端口

完成后确认：

```bash
sudo systemctl status sing-box --no-pager
sudo sing-box check -c /cloud/service/vpnProxy/server/sing-box-config.json
sudo ss -lntup | grep -E '(:443|:22)'
```

正常时应看到 `sing-box` 在 **0.0.0.0:443** 上同时监听 TCP 和 UDP，服务为 `active (running)` 且已开机启用。

## 配置说明

示例文件：

- `config.example.json`：与脚本生成的服务端 JSON 结构相同（sing-box 使用 JSON，不是 YAML）
- `examples/server.env.example`：本地密钥文件的字段列表
- `examples/sing-box-hysteria2-client.json`、`examples/sing-box-vless-reality-client.json`：客户端示例
- `examples/hysteria2-share-link.example.txt`、`examples/vless-reality-share-link.example.txt`：分享链接格式

需要你自行填写的值：

| 占位符 | 含义 |
| --- | --- |
| `YOUR_SNI` | REALITY / 证书使用的伪装域名 |
| `YOUR_SERVER_IP` | 服务器公网 IPv4 |
| `YOUR_PASSWORD` | Hysteria2 用户密码 |
| `YOUR_UUID` | VLESS 用户 UUID |
| `YOUR_REALITY_PRIVATE_KEY` / `YOUR_REALITY_PUBLIC_KEY` | `sing-box generate reality-keypair` 生成的密钥对 |
| `YOUR_SHORT_ID` | REALITY short ID（脚本用 `openssl rand -hex 8` 生成） |

说明：

- 服务端 `listen` 为 `0.0.0.0`，两个 inbound 默认都是 443，协议不同（TCP / UDP），可以共存。
- Hysteria2 使用**自签证书**，没有 ACME / Let’s Encrypt。客户端必须开启 `insecure: true`（或等价的 `allowInsecure` / 分享链接里的 `insecure=1`）。
- 脚本会把 `REALITY_DEST` 写入 `server.env`，但当前 `write_config` 里 REALITY 的 `handshake.server` 和 `tls.server_name` 实际都使用 **`SNI`**。若两者不一致，以 `SNI` 为准。
- 客户端 VLESS 默认在本机 `127.0.0.1:2080` 提供 mixed（HTTP/SOCKS）入站；Hysteria2 在 `127.0.0.1:2081`。
- 默认 `/etc/sing-box/config.json` **不会**被这个服务使用；真正生效的是 `/cloud/service/vpnProxy/server/sing-box-config.json`。

## 开放 UDP 端口（Lightsail 防火墙）

Lightsail 控制台的防火墙独立于操作系统防火墙。即使脚本已经添加了 iptables 规则，也要在实例 **Networking** 中手动添加：

1. 保留 SSH：TCP 22
2. 自定义规则：TCP 443（来源建议限制为你的 IP；若需要任意来源则用 `0.0.0.0/0`）
3. 自定义规则：UDP 443（或你设置的 `HYSTERIA2_PORT`）

只开放 TCP 443 时，VLESS 可能可用，Hysteria2 不可用。

## 客户端连接示例

把示例里的占位符换成 `clients/` 目录下生成的真实值。不要把真实分享链接或带密码的 JSON 发到公开仓库。

### Hysteria2（sing-box）

```bash
sing-box check -c sing-box-hysteria2-client.json
sing-box run -c sing-box-hysteria2-client.json
curl -x socks5h://127.0.0.1:2081 https://ifconfig.me
```

分享链接格式：

```text
hysteria2://YOUR_PASSWORD@YOUR_SERVER_IP:443?insecure=1&sni=YOUR_SNI#sing-box-hysteria2
```

Shadowrocket 等客户端导入该链接时，必须允许不安全证书（自签）。

### VLESS + REALITY（sing-box）

```bash
sing-box check -c sing-box-vless-reality-client.json
sing-box run -c sing-box-vless-reality-client.json
curl -x socks5h://127.0.0.1:2080 https://ifconfig.me
```

分享链接格式（由脚本写出，字段与上面的 JSON 对应）：

```text
vless://YOUR_UUID@YOUR_SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=YOUR_SNI&fp=chrome&pbk=YOUR_REALITY_PUBLIC_KEY&sid=YOUR_SHORT_ID&type=tcp#sing-box-vless-reality
```

其他客户端（Shadowrocket、Mihomo/Clash Meta 等）需自身支持 REALITY 和 Hysteria2，再按同样字段填写。本仓库不附带这些第三方客户端。

## 常见问题

**Q: 这是官方 hysteria 二进制吗？**  
不是。运行的是官方 `sing-box`，用它的 `hysteria2` inbound。没有 `hysteria-server` 服务。

**Q: 为什么连不上 Hysteria2？**  
检查 Lightsail / 安全组是否放行了 **UDP** 443；客户端是否设置了 `insecure: true`；密码和 SNI 是否与服务端一致。可用 `sudo journalctl -u sing-box -n 100 --no-pager` 查看是否有 inbound 日志。

**Q: 只想开 Hysteria2，不要 VLESS？**  
当前脚本总会同时写入两个 inbound。若要只保留其中一个，需要你自行改 `deploy_vpn.sh` 里的 `write_config` 或生成后的 JSON，并重新 `sing-box check` / 重启服务。本仓库没有单独的“只安装 Hysteria2”开关。

**Q: 如何卸载？**  
脚本生成的说明中包含：

```bash
sudo systemctl disable --now sing-box
sudo rm -f /etc/systemd/system/sing-box.service
sudo rm -rf /etc/systemd/system/sing-box.service.d
sudo systemctl daemon-reload
sudo apt-get remove -y sing-box
```

以上命令 **不会** 删除 `/cloud/service/vpnProxy` 下的配置、证书和密钥，需你手动确认后再删。

**Q: 重复运行脚本会怎样？**  
若 `state/server.env` 已存在，会复用已有密钥；已有服务端配置会被复制到 `backups/`；客户端目录会被备份后重写。仍会 `systemctl restart sing-box`。

**Q: 新用户一定有免费额度吗？**  
不一定。是否免费、能用多久，以 AWS 当时的账户资格和账单页为准，本项目不保证免费额度。

## License

本项目采用 [MIT](./LICENSE) 许可证。Copyright (c) 2026 hzopc1031。
