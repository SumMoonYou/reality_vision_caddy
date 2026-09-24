# Xray Reality + Vision + Caddy 一键部署脚本

> 一键在 Debian / Ubuntu 上部署 **Xray (Reality + Vision)** 与 **Caddy**（伪装站），实现"偷自己域名"的流量伪装方案。

[![System](https://img.shields.io/badge/system-Debian%20%7C%20Ubuntu-blue)](https://www.debian.org/)
[![Xray](https://img.shields.io/badge/Xray-Reality%20%2B%20Vision-green)](https://github.com/XTLS/Xray-core)
[![Caddy](https://img.shields.io/badge/Caddy-v2-orange)](https://caddyserver.com/)
[![License](https://img.shields.io/badge/license-MIT-lightgrey)](LICENSE)

---

## 📖 简介

本脚本在 **Debian / Ubuntu** 系统上一键完成以下部署：

- **Xray**：VLESS + Reality + Vision，监听 443 端口
- **Caddy**：监听本地 8003，提供真实 HTTPS 网站作为伪装站
- **Reality** 的 `dest` 指向 Caddy，客户端握手时看到的是真实网站的 TLS 指纹
- 自动申请 Let's Encrypt 证书（HTTP-01 验证）
- 支持**多用户管理**、**日志保留 7 天**、**伪装页 favicon**、**安装/卸载/查看状态**等全套功能

---

## ✨ 特性

| 功能 | 说明 |
|------|------|
| 🚀 一键部署 | 交互式安装，自动完成所有配置 |
| 🔐 Reality 伪装 | 偷自己域名的真实 TLS 证书，抗探测 |
| 👥 多用户管理 | 添加 / 删除 / 查看用户，独立 UUID |
| 📄 伪装站点 | 内置 HTML 页面 + 内联 SVG favicon |
| 🧹 日志保留 7 天 | journald + Xray 文件日志自动清理 |
| 🔄 重复安装检测 | 已安装时可选择覆盖 / 完全重装 |
| 🛠 安装后自检 | 服务、端口、本地 curl 三重验证 |
| 🧩 端口占用处理 | 自动停止 Nginx / Apache2 / 默认 Caddy |
| 🖥 跨发行版 | 仅支持 Debian / Ubuntu（含检测拒绝） |

---

## 📋 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Debian 11/12/13、Ubuntu 20.04/22.04/24.04 |
| 权限 | root |
| 域名 | 已解析到本机公网 IP 的域名 |
| 端口 | 80、443 未被占用 |
| 网络 | 可访问 GitHub 与 Cloudsmith（Caddy 源） |

> ⚠️ **注意**：
> - 域名必须**提前解析**到本机，否则证书申请会失败
> - **Cloudflare 代理（小黄云）需关闭**，否则 Caddy 无法完成 ACME 验证
> - 云服务器**安全组**需放行 80、443 入站

---

## 🚀 快速开始

### 1. 下载脚本

```bash
wget -O install.sh https://raw.githubusercontent.com/SunMoonWithYou/reality_vision_caddy/main/install.sh
```

### 2. 赋予执行权限

```bash
chmod +x install.sh
```

### 3. 运行

```bash
sudo ./install.sh
```

### 4. 选择菜单

```
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
```

---

## 📸 使用示例

### 安装

```
选 1

===== 参数配置 =====
请输入你的域名 (例如: example.com): your-domain.com
请输入用于 ACME 的邮箱 (例如: admin@example.com): you@example.com
请输入伪装站标题 (默认: Welcome):
请输入 Xray 监听端口 (默认 443):

[INFO] 参数已录入
[INFO] 自动生成 UUID: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
...
[INFO] 安装完成！建议 reboot 一次。
```

安装结束后会自动输出客户端参数与 VLESS 分享链接。

### 添加用户

```
选 5 → 2

用户标识 email (例如 alice@example.com，可空): alice@example.com
备注 note (可空): Alice 的手机
[INFO] 已添加用户：alice@example.com (xxxxxxxx-xxxx-...)
[INFO] Xray 已重启，用户生效
```

### 查看客户端参数

```
选 4

可用用户：
  1) default (xxxxxxxx-xxxx-...) 初始用户
  2) alice@example.com (xxxxxxxx-xxxx-...) Alice 的手机
选择用户编号 (默认 1): 2
...
vless://xxxx@your-domain.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=your-domain.com&fp=chrome&pbk=xxxx&sid=xxxx&type=tcp&headerType=none#Reality-alice@example.com
```

### 查看状态

```
选 3

===== 服务状态 =====

--- Xray ---
● xray.service - Xray Service
     Active: active (running)

--- Caddy (caddy-json) ---
● caddy-json.service - Caddy JSON Service
     Active: active (running)

--- 端口 ---
LISTEN  0.0.0.0:80     caddy
LISTEN  0.0.0.0:443    xray
LISTEN  127.0.0.1:8003 caddy

--- 版本 ---
Xray: Xray 26.x.x
Caddy: v2.x.x

--- 日志保留 ---
MaxRetentionSec=7day
SystemMaxUse=500M
```

### 卸载

```
选 2

即将卸载：
  域名      : your-domain.com
  端口      : 443
  用户数量  : 2

确认卸载？输入 yes 继续: yes

移除日志保留策略 ? [y/N]: y
删除伪装站点 /var/www/html ? [y/N]: y
删除安装信息 /etc/reality-caddy ? [y/N]: y
```

---

## 🗂 目录结构

```
/etc/reality-caddy/
├── info.txt      # 安装信息（域名、密钥、端口），权限 600
└── users.txt     # 用户列表（UUID|EMAIL|备注），权限 600

/usr/local/etc/xray/
└── config.json   # Xray 主配置（自动生成）

/etc/caddy/
└── caddy.json    # Caddy 配置

/var/www/html/
└── index.html    # 伪装站首页（含内联 favicon）

/etc/systemd/system/
├── xray.service          # Xray 服务（官方脚本生成）
└── caddy-json.service    # Caddy JSON 服务

/etc/systemd/journald.conf.d/
└── 99-retention.conf     # journald 保留 7 天

/etc/tmpfiles.d/
└── xray-log.conf         # Xray 文件日志清理规则
```

---

## 🔧 架构说明

```
客户端 ──TLS(Reality)──> Xray:443 ──转发──> Caddy:127.0.0.1:8003
                          │
                          └─ 对外表现为访问你的域名（真实 TLS 指纹）
```

- **Xray** 监听 443，处理 VLESS + Reality + Vision
- **Caddy** 监听 127.0.0.1:8003，提供真实网站内容
- **Reality 的 dest** 指向 Caddy，客户端握手时看到真实站点证书
- **Caddy 同时监听 80**，用于 ACME HTTP-01 验证 + HTTP→HTTPS 跳转

---

## 🛠 常见问题

### Q1: Caddy 启动失败，日志显示 `address already in use`

**原因**：80 或 443 被其他进程占用（Nginx、Apache、默认 Caddy）。

**解决**：脚本安装时会自动停止它们。若仍失败：

```bash
ss -tlnp | grep -E ':(80|443)'
systemctl stop nginx apache2 caddy 2>/dev/null
systemctl restart caddy-json.service
```

### Q2: 证书申请失败

**检查**：

```bash
dig +short your-domain.com          # 应返回本机公网 IP
ss -tlnp | grep ':80'               # 80 应被 Caddy 监听
journalctl -u caddy-json.service -n 50 --no-pager
```

**常见原因**：

- 域名未解析或指向错误
- Cloudflare 代理未关闭
- 云安全组未放行 80

### Q3: 节点连不上，伪装页打不开

**最大概率 Caddy 挂了**（Reality dest 不可达）。

```bash
systemctl status caddy-json.service --no-pager -l
journalctl -u caddy-json.service -n 80 --no-pager
```

若显示 `status=203/EXEC`，说明 `/usr/bin/caddy` 丢失：

```bash
apt-get install --reinstall -y caddy
```

### Q4: 如何修改域名或端口？

重新运行脚本选 **1) 安装**，选择 **1) 覆盖重装**：

- 保留 `users.txt`
- 重建 `info.txt`、`caddy.json`、`config.json`
- 密钥会重新生成（客户端需更新配置）

### Q5: 如何只更新某个用户的 UUID？

```bash
nano /etc/reality-caddy/users.txt
systemctl restart xray
```

或用菜单 `5) 用户管理` 删除旧用户 + 添加新用户。

### Q6: 日志占用磁盘过大？

脚本默认保留 7 天，可手动清理：

```bash
journalctl --vacuum-time=7d
journalctl --disk-usage
```

修改保留天数：编辑 `/etc/systemd/journald.conf.d/99-retention.conf` 里的 `MaxRetentionSec`，然后：

```bash
systemctl restart systemd-journald
```

---

## 🧪 客户端配置

安装完成后，脚本会输出以下参数：

| 参数 | 值 |
|------|-----|
| 协议 | VLESS |
| 地址 | 你的域名 |
| 端口 | 443 |
| UUID | 自动生成 |
| 流控 | xtls-rprx-vision |
| 传输 | tcp |
| 安全 | reality |
| SNI | 你的域名 |
| Fingerprint | chrome |
| PublicKey | 自动生成 |
| ShortId | 自动生成 |
| SpiderX | / |

**推荐的客户端**：

- Windows：v2rayN、Nekoray
- macOS：V2RayXS、Nekoray
- Android：v2rayNG、NekoBox
- iOS：Shadowrocket、Stash
- Linux：Nekoray、v2rayA

直接复制脚本输出的 `vless://` 分享链接导入即可。

---

## 📜 卸载

运行脚本选 **2) 卸载**，会依次询问：

- 移除日志保留策略
- 删除伪装站点 `/var/www/html`
- 删除安装信息 `/etc/reality-caddy`

彻底清理残留：

```bash
apt-get autoremove -y && apt-get clean
```

---

## 📁 仓库结构

```
.
├── README.md              # 本说明文档
├── reality_caddy.sh       # 主脚本
└── LICENSE                # MIT 许可证
```

---

## ⚠️ 免责声明

- 本脚本仅供**学习与技术研究**使用
- 请遵守你所在国家/地区的法律法规
- 使用本脚本产生的任何后果由使用者自行承担
- 请勿用于任何非法用途

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request。

1. Fork 本仓库
2. 新建分支 `git checkout -b feature/xxx`
3. 提交改动 `git commit -am 'Add xxx'`
4. 推送 `git push origin feature/xxx`
5. 提交 Pull Request

---

## 📄 许可证

[MIT License](LICENSE)

---

## 🙏 致谢

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)
- [caddyserver/caddy](https://github.com/caddyserver/caddy)
- [XTLS/Xray-install](https://github.com/XTLS/Xray-install)
- 所有为本项目提供反馈的用户

---

**⭐ 如果这个项目对你有帮助，欢迎 Star 支持！**
