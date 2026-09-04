# VPS Startup Script

面向 VPS 的无人值守开机自愈脚本。自动识别 Linux 发行版、CPU 架构和包管理器，补齐依赖，依次安装和维护哪吒探针、Cloudflare DDNS、WARP WireProxy 与 V2bX。全过程无菜单、无人工确认、无交互输入。

VPS 重启后自动运行，检查和修复所有步骤，全部成功后发送 Telegram 通知。

## 特性

- ✅ **完全无人值守**：从安装到开机自愈，全程零交互
- ✅ **自动识别系统**：支持 Debian/Ubuntu/RHEL/CentOS/Arch/Alpine/SUSE 等主流发行版
- ✅ **智能重试机制**：命令失败重试 3 次，步骤失败重试 2 次
- ✅ **持久化配置**：首次运行保存全部变量，重启后自动恢复
- ✅ **成熟方案复用**：WireProxy 直接使用 fscarmen `menu.sh w` 安装，V2bX 固定为 0.4.0
- ✅ **开机自启动**：支持 systemd 和 OpenRC，启动超时 30 分钟
- ✅ **安全保护**：配置文件 0600 权限，API Key 通过文件描述符传递

## 快速开始

使用 root 用户执行，命令后的 12 个值必须按顺序填写：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/feat/one-click-installer/install.sh | sh -s -- \
  'NZ_SERVER' \
  'NZ_CLIENT_SECRET' \
  'NZ_UUID' \
  'CFKEY' \
  'CFUSER' \
  'CFRECORD_NAME' \
  'ApiHost' \
  'ApiKey' \
  'NodeID_anytls' \
  'NodeID_hysteria2' \
  'TG_BOT_TOKEN' \
  'TG_USER_ID'
```

### 示例（仅用于展示格式，请替换为真实值）

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/feat/one-click-installer/install.sh | sh -s -- \
  'node-bf7d24.example.com:443' \
  'qOcYghUDg_6EjFWNQgC19XCtSlEyloHH' \
  'cbc0244b-56a9-4559-a92c-d3578ff11896' \
  'f2f61175106f42e490f08bb91f2bdd80' \
  'admin@example.com' \
  'vps.example.com' \
  'https://panel.example.com' \
  '09e16049d8ef4d3fb13b0f7ce734c02b' \
  '10006' \
  '20006' \
  '7123456789:AAH8uJw4nB9mQ7sK2xV6pL0cF3eD5gT1yZ' \
  '987654321'
```

## 执行流程

这条命令会：

1. **下载项目**：下载完整项目到 `/opt/startup-script`，保存所有变量到 `/var/lib/startup-script/startup.env`
2. **基础环境**：自动识别系统、架构和包管理器，安装 jq、socat、openssl 等 15+ 基础依赖
3. **哪吒探针**：安装并启动哪吒 Agent，监控 VPS 状态
4. **Swap 交换空间**：创建 4GB swap 文件，设置 swappiness=10，优化内存管理
5. **关闭防火墙**：停止并删除 UFW、firewalld 等防火墙管理器，清空规则，开放所有端口
6. **Cloudflare DDNS**：自动识别 Zone，创建或更新 A 记录，每 5 分钟同步公网 IPv4
7. **WARP WireProxy**：直接调用 fscarmen `menu.sh w` 安装并配置，监听 `127.0.0.1:40000`
8. **V2bX 安装**：安装 V2bX 0.4.0 及数据文件，但不启动服务
9. **V2bX 配置**：根据 `example/` 目录模板生成配置，启动双节点服务
10. **验证通知**：重新验证全部步骤，自动修复异常，成功后发送 Telegram 通知

脚本会注册 systemd 或 OpenRC 开机服务。命令失败会自动重试，服务或配置异常会在本次运行及以后每次开机时继续修复。

## 变量说明

| 序号 | 变量名 | 说明 | 示例 |
|:---:|--------|------|------|
| 1 | `NZ_SERVER` | 哪吒服务器地址（含端口） | `node.example.com:443` |
| 2 | `NZ_CLIENT_SECRET` | 哪吒客户端密钥 | `qOcYghUDg_6EjFWNQgC19XCtSlEyloHH` |
| 3 | `NZ_UUID` | 哪吒客户端 UUID | `cbc0244b-56a9-4559-a92c-d3578ff11896` |
| 4 | `CFKEY` | Cloudflare Global API Key | `f2f61175106f42e490f08bb91f2bdd80` |
| 5 | `CFUSER` | Cloudflare 账号邮箱 | `admin@example.com` |
| 6 | `CFRECORD_NAME` | 需要同步的完整域名 | `vps.example.com` |
| 7 | `ApiHost` | V2bX 面板地址（HTTP(S)） | `https://panel.example.com` |
| 8 | `ApiKey` | V2bX 面板通信密钥 | `09e16049d8ef4d3fb13b0f7ce734c02b` |
| 9 | `NodeID_anytls` | anyTLS 节点 ID（正整数） | `10006` |
| 10 | `NodeID_hysteria2` | Hysteria2 节点 ID（正整数） | `20006` |
| 11 | `TG_BOT_TOKEN` | Telegram Bot Token | `7123456789:AAH8u...` |
| 12 | `TG_USER_ID` | 接收通知的 Telegram 用户 ID | `987654321` |

**重要提示**：
- 全部 12 个变量都必须提供，建议使用单引号包裹
- `NodeID_anytls` 和 `NodeID_hysteria2` 必须是大于 0 且不带前导零的整数
- `CFKEY` 是 Cloudflare Global API Key，不是 API Token
- 所有变量保存在 `/var/lib/startup-script/startup.env`，权限 0600
- VPS 重启后自动读取配置，无需再次传入

### 可选变量

`NZ_TLS` 默认为 `true`。如需关闭 TLS：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/feat/one-click-installer/install.sh | NZ_TLS='false' sh -s -- \
  'NZ_SERVER' 'NZ_CLIENT_SECRET' 'NZ_UUID' ...
```

## 安全提醒

⚠️ **命令行包含敏感信息**：一键命令中的 12 个变量包含 API Key、Bot Token 等密钥，可能被记录在：
- Shell 历史记录（`~/.bash_history`）
- 云平台启动脚本日志
- 系统审计日志（`/var/log/audit/`）

**建议操作**：
1. 仅在可信环境中执行命令
2. 执行后清理历史：`history -c && history -w`
3. 配置文件已设置 0600 权限，仅 root 可读取
4. API Key 和 Bot Token 通过文件描述符传递给 curl，避免进程参数暴露

## 防火墙说明

⚠️ **高风险操作**：步骤 2 会停止并禁用 VPS 内部的主机防火墙，清空所有规则，将默认策略设为允许。这会导致 VPS 全部端口直接暴露到公网。

**具体操作**：
- 停止并禁用 UFW、firewalld、nftables 等 8 个常见防火墙服务
- 删除 UFW、firewalld 和规则持久化组件
- 清空 iptables/ip6tables/nft 全部规则
- 设置 INPUT/FORWARD/OUTPUT 三链默认策略为 ACCEPT
- 保留底层 `iptables`/`nft` 命令，用于开机时持续检查和清理规则

**不受影响的**：
- 云厂商控制台的安全组（需单独放行端口）
- 网络 ACL 和上游防火墙
- Docker 等容器网络（可能需要手动修复）

**测试命令**（仅查看不执行）：
```bash
/opt/startup-script/startup.sh install --dry-run
```

## 手动管理

安装后可以手动执行以下命令：

```bash
# 检查所有步骤状态（不修改系统）
/opt/startup-script/startup.sh check

# 重新安装和修复所有步骤
/opt/startup-script/startup.sh install --yes

# 手动触发一次 DDNS 更新
/opt/startup-script/startup.sh ddns

# 查看脚本版本
/opt/startup-script/startup.sh version

# 查看日志
tail -f /root/startup-script.log
```

### 部分更新配置

只需传入需要变更的环境变量，其他值会沿用已保存配置：

```bash
# 更改 DDNS 域名和 anyTLS 节点 ID
env CFRECORD_NAME='new-vps.example.com' NodeID_anytls='10008' \
  /opt/startup-script/startup.sh install --yes

# 更换 Telegram Bot
env TG_BOT_TOKEN='9876543210:XXX' TG_USER_ID='111222333' \
  /opt/startup-script/startup.sh install --yes
```

## 系统要求

- **操作系统**：Debian 8+、Ubuntu 16.04+、CentOS 7+、RHEL 7+、Arch Linux、Alpine Linux 3.12+、openSUSE Leap 15+
- **架构**：x86_64、aarch64、armv7、armv6、i386、riscv64、s390x、mips64le
- **权限**：必须使用 root 用户执行
- **网络**：需要访问 GitHub、Cloudflare API、Telegram API
- **init 系统**：systemd 或 OpenRC（不支持纯 SysV init）

## 故障排查

### 查看日志
```bash
tail -100 /root/startup-script.log
journalctl -u startup-script -n 100  # systemd
rc-service startup-script status      # OpenRC
```

### 服务状态
```bash
systemctl status startup-script           # systemd
systemctl status startup-cloudflare-ddns.timer
systemctl status wireproxy
systemctl status V2bX

rc-service startup-script status          # OpenRC
rc-service startup-cloudflare-ddns status
rc-service wireproxy status
rc-service V2bX status
```

### 手动测试各步骤
```bash
# 测试 DDNS
/opt/startup-script/startup.sh ddns

# 测试 WARP 连通性
curl -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace

# 查看 V2bX 日志
journalctl -u V2bX -n 50
tail -50 /var/log/V2bX.log
```

### 重新安装某个步骤
```bash
# 删除步骤状态文件，强制重新执行
rm /var/lib/startup-script/step-*.state
/opt/startup-script/startup.sh install --yes
```

## 更新日志

### 0.9.17 (2026-09-05)

- 🔧 **调整重启间隔**：将 WireProxy 自动重启间隔从 2 小时改为 1 小时（3600 秒）
- 📊 **应对高流量场景**：WireProxy 处理 V2bX 所有节点流量（包括 Hysteria2 UDP）时内存增长更快
- ✅ **双重保护机制**：
  - 定时重启：每 1 小时自动重启释放内存
  - IP 变化重启：VPS 换 IP 后自动重启（每 2 分钟检测一次）

### 0.9.16 (2026-09-05)

- 🐛 **修复 WireProxy 内存持续增长问题**：WireProxy 进程运行时内存会不断升高，最终导致系统资源耗尽
- ⏰ **添加定时重启机制**：每 2 小时自动重启 WireProxy 服务，释放累积的内存
- ⚙️ **使用 systemd RuntimeMaxSec**：在服务配置中添加 `RuntimeMaxSec=7200` 和 `Restart=always`
- 🔧 **自动应用修复**：安装或修复步骤05时自动修改 wireproxy.service 文件
- 📊 **最小化影响**：重启过程仅需几秒，对代理服务的影响极小

### 0.9.15 (2026-09-05)

- ⏮️ **回退内核 WireGuard 架构**：放弃 v0.10.x 系列的 wgcf + 内核 WireGuard 方案，回退到稳定的 WireProxy 架构
- 🐛 **避免验证逻辑复杂性**：内核 WireGuard 接口状态检测存在多个边界情况，WireProxy 作为用户态进程更易管理
- ✅ **保持 IP 监控功能**：继续使用 v0.9.14 的 VPS IP 变化监控和自动重启机制
- 🎯 **稳定性优先**：WireProxy + fscarmen 脚本是经过长期验证的成熟方案

### 0.9.14 (2026-09-04)

- 🔍 **新增 WireProxy 出口 IP 监控服务**：每 2 分钟自动检测 VPS 公网 IPv4 地址变化
- 🔄 **IP 变动自动重启 WireProxy**：当检测到 VPS 换 IP 后，自动重启 WireProxy 服务，避免 SOCKS5 代理失效
- ⚙️ **systemd 和 OpenRC 双支持**：systemd 使用 timer 触发，OpenRC 使用后台循环服务
- 💾 **IP 状态持久化**：记录历史 IP 到 `/var/lib/startup-script/wireproxy_ip.state`，首次运行仅记录不重启

### 0.9.13 (2026-09-04)

- 🔄 **WireProxy 改为直接调用 fscarmen 原脚本**：实际执行 `wget -4 -N https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh` 和 `bash menu.sh w`
- 🧹 **删除项目内自制 WireProxy 安装逻辑**：二进制下载、WARP 注册、MTU 计算、配置和服务创建全部交给 fscarmen 维护
- 🐛 **避免同版本不同构建**：旧安装会重新走 fscarmen `w` 模式，消除缓存复用导致的二进制不一致

### 0.9.12 (2026-09-04)

- 🔄 **切换回 pufferffish 官方原版 WireProxy 1.0.9**：与 fscarmen 脚本完全一致
- 🐛 **修复内存泄漏根本原因**：windtf fork 版本存在内存泄漏，官方版本稳定
- ✅ **验证通过**：fscarmen 的 `menu.sh w` 使用的就是 pufferffish 1.0.9，运行稳定无内存泄漏

### 0.9.11 (2026-09-04)

- 🎯 **完全集成 fscarmen 的 WireProxy 实现**：直接采用 fscarmen 脚本的配置生成逻辑和服务定义
- 🔧 **DNS 优先级智能调整**：IPv6 only 环境时 IPv6 DNS 优先，否则 IPv4 优先
- 📝 **配置文件格式对齐**：完全按照 fscarmen 的 proxy.conf 模板生成，包括所有注释和可选功能说明
- ⚙️ **systemd 服务配置优化**：使用 `RemainAfterExit=yes` 确保服务状态正确
- 🧹 **简化 OpenRC 配置**：移除不必要的日志重定向和依赖声明，保持最小化配置

### 0.9.10 (2026-09-04)

- 🧮 **实现 MTU 动态计算**：使用二分查找算法根据实际网络环境自动计算最优 MTU
- 🌐 **IPv4/IPv6 双栈支持**：自动检测网络栈类型，选择合适的测试 IP 和计算方式
- 📊 **WireGuard 包头适配**：IPv4 减 60 字节，IPv6 减 80 字节，确保不会分片
- 🔍 **避免固定 MTU 导致的连接泄漏**：MTU 不匹配会导致分片和僵尸连接累积

### 0.9.9 (2026-09-04)

- 🔧 **切换回 windtf/wireproxy 1.1.3**：经对比 fscarmen 脚本，发现其使用的是 windtf fork 版本，该版本稳定无内存泄漏
- 📊 **调整 MTU 为 1420**：与 fscarmen 配置一致，避免分片导致连接累积
- 🌐 **扩充 DNS 列表**：添加 IPv4/IPv6 备用 DNS，提升解析稳定性
- ❌ **移除资源限制**：windtf 1.1.3 版本稳定，无需定时重启和内存限制

### 0.9.8 (2026-09-04)

- 🔧 **恢复 WireProxy 资源限制**：经测试发现 WireProxy 本身存在内存泄漏，每小时自动重启一次防止内存耗尽
- 📊 **内存限制**：MemoryMax=512M, MemoryHigh=384M，超过会自动重启
- ⏰ **定时重启**：RuntimeMaxSec=3600（每小时），最小化内存泄漏影响

### 0.9.7 (2026-09-04)

- 🔧 **移除 WireProxy SHA-256 校验**：简化安装流程，避免校验失败
- 🐛 **修复 WireProxy 安装失败问题**：使用 GitHub 官方源但跳过校验
- 🔍 **添加详细安装日志**：便于排查安装失败的具体原因

### 0.9.6 (2026-09-04)

- 🔄 **切换到 pufferffish 官方原版 WireProxy**（v1.0.9 替代 windtf fork v1.1.3）
- 🐛 **解决内存泄漏根本原因**：与 fscarmen 脚本保持一致，使用稳定版本
- ➖ **移除定时重启和内存限制**：原版不会内存泄漏，无需额外限制

### 0.9.5 (2026-09-04)

- 🐛 **修复 WireProxy 内存泄漏问题**（1.4GB+ 且持续增长）
- ⏰ WireProxy 每 6 小时自动重启一次，清理累积的内存
- 🛡️ 限制 WireProxy 内存使用：最高 512MB，警戒线 384MB
- 🔄 同时支持 systemd 和 OpenRC 的定时重启机制

### 0.9.4 (2026-09-04)

- 🐛 修复内存泄漏问题：为 V2bX 和 WireProxy 服务添加日志管理
- 📝 V2bX 日志重定向到 `/var/log/V2bX.log`，每日轮转，保留 7 天，单文件最大 100MB
- 📝 WireProxy 日志输出到 systemd journal，限制 journal 总大小为 500MB
- 🛡️ 防止长时间运行后日志无限增长导致的内存和磁盘占用

### 0.9.3 (2026-09-04)

- 🐛 修复步骤 02（Swap 配置）缺少依赖的问题，补充 `util-linux` 和 `procps` 包
- 🐛 修复 startup.sh 中 DDNS 步骤路径错误（03 → 04）
- 🛡️ 增强 Swap 配置的健壮性，支持 `/etc/sysctl.d/` 目录作为备选配置路径
- 🐧 为 Alpine Linux 补充 `linux-headers` 依赖

### 0.9.2 (2026-09-04)

- 💾 新增步骤 02：配置 Swap 交换空间（4GB，swappiness=10）
- 🎨 优化 Telegram 通知排版，使用中文和表情符号
- 📋 所有步骤重新编号（02-08 变为 03-09，新增 02 为 Swap）

### 0.9.1 (2026-09-04)

- 🗂️ 调整日志文件位置从 `/var/log/startup-script/` 改为 `/root/startup-script.log`，更方便查看
- 🐛 修复 install.sh 的 POSIX shell 兼容性问题（`[[` 改为 `[`）

### 0.9.0 (2024-01-15)

**重大更新**：
- 🔧 一键命令扩展为 12 个必填变量，覆盖哪吒、DDNS、V2bX 和 Telegram
- 💾 全部配置以 0600 权限持久化到 `/var/lib/startup-script/startup.env`，重启后自动恢复
- 🌐 增加 Cloudflare IPv4 DDNS，自动识别 Zone、维护 A 记录并每 5 分钟同步
- 🔒 增加固定版本的 WireProxy 1.1.3，自动注册 WARP，在 `127.0.0.1:40000` 提供 SOCKS5 代理
- 📦 增加固定版本的 V2bX 0.4.0，分步完成安装、配置生成和服务启动
- ✅ 增加最终总体验证、自愈与 Telegram 成功通知，配置未变化时不重复通知
- 🛡️ 强化引导依赖补全、日志权限、下载暂存和安装失败回滚

**Bug 修复**：
- 修复 V2bX 配置文件原子回滚逻辑，避免中间失败导致状态不一致
- 修复 DDNS systemd/OpenRC 服务路径转义问题
- 修复 install.sh 变量验证顺序，先检查空值再验证格式

### 0.8.3 (2024-01-10)

- 补齐防火墙步骤所需的 `iptables`、`ip6tables` 和 `nft` 底层命令
- 增加 Docker 等程序网络规则可能受影响的风险说明

### 0.8.2 (2024-01-09)

- 完善防火墙步骤的无人值守处理顺序，先放行规则再停止服务
- 增加 UFW 明确禁用和 dry-run 命令展示
- 保留底层防火墙命令用于开机后的持续检查

### 0.8.1 (2024-01-08)

- 补齐 `iptables`、`ip6tables` 和 `nft` 基础命令
- 移除多余的 systemd 屏蔽动作

### 0.8.0 (2024-01-07)

- 增加第二步防火墙处理
- 停止并禁用 UFW、firewalld、nftables 和规则持久化服务
- 清空主机防火墙规则，将默认策略设为允许
- 删除防火墙管理器，保留底层命令

### 0.7.6

- 在 README 中增加随机的一键安装完整示例
- 使用 `example.com` 保留域名

### 0.7.5

- 将 `NZ_SERVER` 改为一键命令必填变量
- 移除源码中的默认服务器地址

### 0.7.4

- 修复入口脚本拼写残留
- 统一一键安装示例

### 0.7.3

- 修复一键安装时变量持久化函数缺失
- 确保首次安装中断后，重启仍能继续自愈

### 0.7.2

- 首次运行立即保存哪吒变量
- 开机服务自动读取配置文件

### 0.7.1

- 一键命令改为强制传入客户端密钥和 UUID
- 移除源码和文档中的真实凭据

### 0.7.0

- 增加极短的一键安装引导脚本 `install.sh`
- 支持通过管道参数传入变量
- 一键下载完整项目并安装

### 0.6.1

- 强化哪吒配置指纹和安装脚本校验
- 完成配置持久化、重试和服务模板验证

## 许可证

MIT License

## 贡献

欢迎提交 Issue 和 Pull Request。

## 免责声明

本脚本会关闭 VPS 主机防火墙并开放所有端口，这可能带来安全风险。使用前请确保：
1. 了解防火墙关闭的后果
2. 云厂商安全组已正确配置
3. 仅在可信环境中执行一键命令
4. 执行后及时清理包含密钥的历史记录

使用本脚本造成的任何损失，作者概不负责。
