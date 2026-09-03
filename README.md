# VPS Startup Script

面向 VPS 的无人值守开机自愈脚本。它会自动识别 Linux 发行版、CPU 架构和包管理器，补齐依赖，并依次安装和维护哪吒探针、Cloudflare DDNS、WARP WireProxy 与 V2bX。全过程不显示菜单，也不要求人工确认。

## 一键安装

使用 root 用户执行。命令后的 12 个值必须按顺序填写：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | sh -s -- 'NZ_SERVER' 'NZ_CLIENT_SECRET' 'NZ_UUID' 'CFKEY' 'CFUSER' 'CFRECORD_NAME' 'ApiHost' 'ApiKey' 'NodeID_anytls' 'NodeID_hysteria2' 'TG_BOT_TOKEN' 'TG_USER_ID'
```

随机示例（仅用于展示格式，不能用于真实部署）：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | sh -s -- 'node-bf7d24.example.com:443' 'qOcYghUDg_6EjFWNQgC19XCtSlEyloHH' 'cbc0244b-56a9-4559-a92c-d3578ff11896' 'f2f61175106f42e490f08bb91f2bdd80' 'admin@example.com' 'vps.example.com' 'https://panel.example.com' '09e16049d8ef4d3fb13b0f7ce734c02b' '10006' '20006' '7123456789:AAH8uJw4nB9mQ7sK2xV6pL0cF3eD5gT1yZ' '987654321'
```

这条命令会：

1. 下载完整项目到 /opt/startup-script，并保存所有变量。
2. 自动识别系统、架构和包管理器，安装缺失的基础依赖。
3. 安装并检查哪吒探针。
4. 关闭并删除 VPS 内部防火墙管理器，开放所有端口。
5. 自动识别 Cloudflare Zone，创建或更新指定的 A 记录，并每 5 分钟同步一次。
6. 安装 WireProxy 1.1.3，自动注册 WARP，并监听 127.0.0.1:40000。
7. 安装 V2bX 0.4.0，根据 example 目录中的模板生成配置并启动服务。
8. 重新验证前面全部步骤，自动修复异常，全部成功后发送一次 Telegram 通知。

脚本会注册 systemd 或 OpenRC 开机服务。命令失败会自动重试，服务或配置异常会在本次运行及以后开机时继续修复。

`NZ_TLS` 默认启用：

```text
NZ_TLS=true
```

如需关闭 TLS，可以额外附加环境变量：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | NZ_TLS='false' sh -s -- 'NZ_SERVER' 'NZ_CLIENT_SECRET' 'NZ_UUID' 'CFKEY' 'CFUSER' 'CFRECORD_NAME' 'ApiHost' 'ApiKey' 'NodeID_anytls' 'NodeID_hysteria2' 'TG_BOT_TOKEN' 'TG_USER_ID'
```

## 变量说明

```text
1. NZ_SERVER：哪吒服务器地址，包含端口
2. NZ_CLIENT_SECRET：哪吒客户端密钥
3. NZ_UUID：哪吒客户端 UUID
4. CFKEY：Cloudflare Global API Key
5. CFUSER：Cloudflare 账号邮箱
6. CFRECORD_NAME：需要同步的完整域名，例如 vps.example.com
7. ApiHost：V2bX 面板 HTTP(S) 地址
8. ApiKey：V2bX 面板通信密钥
9. NodeID_anytls：anyTLS 节点 ID，必须是大于 0 且不带前导零的整数
10. NodeID_hysteria2：Hysteria2 节点 ID，必须是大于 0 且不带前导零的整数
11. TG_BOT_TOKEN：Telegram Bot Token
12. TG_USER_ID：接收通知的 Telegram 用户或群组 ID
```

全部参数都必须提供，值建议使用单引号包起来。第 12 个值也可通过 TG_CHAT_ID 或 TG_USERID 环境变量提供。Cloudflare 当前使用 Global API Key 认证，不是限制范围的 API Token。

所有变量会写入 /var/lib/startup-script/startup.env，文件权限为 0600，开机自愈时无需再次传入。由于一键命令本身包含密钥，它可能被保存在 shell 历史、云平台启动脚本记录或系统审计日志中；请只在可信环境中执行，并按需清理相关历史记录。

## 防火墙说明

第二步会停止并禁用常见的 UFW、firewalld、nftables 和规则持久化服务，清空主机防火墙规则，并将 IPv4/IPv6 默认策略设为允许。UFW、firewalld、旧防火墙和规则持久化组件会被删除；底层 `iptables`/`nft` 命令会保留，供每次开机重新检查和清理规则。`install --dry-run` 只显示这些操作，不会修改系统。

这是高风险操作，执行后 VPS 的全部端口可能直接暴露到公网。脚本只处理 VPS 内的主机防火墙；云厂商控制台的安全组、网络 ACL 和上游防火墙不受本脚本控制，需要在云平台控制台单独放行。

## 手动管理

```bash
/opt/startup-script/startup.sh check
/opt/startup-script/startup.sh install --yes
/opt/startup-script/startup.sh ddns
/opt/startup-script/startup.sh version
```

修改配置时，只传入需要变更的环境变量即可，其他值会沿用已保存配置。例如：

```bash
env CFRECORD_NAME='new-vps.example.com' NodeID_anytls='10008' /opt/startup-script/startup.sh install --yes
```

## 更新日志

### 0.9.0

- 一键命令扩展为 12 个必填值，并将全部配置以 0600 权限持久化，重启后自动恢复
- 增加 Cloudflare IPv4 DDNS，自动识别 Zone、维护 A 记录并每 5 分钟同步
- 增加固定版本及校验和验证的 WireProxy 1.1.3，在 127.0.0.1:40000 提供 WARP SOCKS5
- 增加固定版本及校验和验证的 V2bX 0.4.0，分步完成安装、配置生成和服务启动
- 增加最终总体验证、自愈与 Telegram 成功通知，配置未变化时不重复通知
- 强化引导依赖补全、日志权限、下载暂存和安装失败回滚

### 0.8.3

- 补齐防火墙步骤所需的 `iptables`、`ip6tables` 和 `nft` 底层命令
- 增加 Docker 等程序网络规则可能受影响的风险说明

### 0.8.2

- 完善防火墙步骤的无人值守处理顺序，先放行规则再停止服务
- 增加 UFW 明确禁用和 dry-run 命令展示
- 保留底层防火墙命令用于开机后的持续检查，不再保留多余的 systemd 屏蔽配置

### 0.8.1

- 补齐 `iptables`、`ip6tables` 和 `nft` 基础命令，保证开机时可以持续检查和清理规则
- 移除多余的 systemd 屏蔽动作，避免留下无用的服务残留配置

### 0.8.0

- 增加第二步防火墙处理
- 停止并禁用常见的 UFW、firewalld、nftables 和规则持久化服务，清空主机防火墙规则，将 IPv4/IPv6 默认策略设为允许
- 删除 UFW、firewalld、旧防火墙和规则持久化组件。底层 `iptables`/`nft` 命令会保留，供每次开机重新检查和清理规则
- 增加防火墙风险和云厂商安全组说明

### 0.7.6

- 在 README 中增加随机的一键安装完整示例
- 使用 `example.com` 保留域名，避免示例被误用于真实连接

### 0.7.5

- 将 `NZ_SERVER` 改为一键命令必填变量
- 一键命令调整为服务器地址、客户端密钥、UUID 三个位置参数
- 移除源码中的默认服务器地址，避免不同环境误连固定服务端

### 0.7.4

- 修复入口脚本拼写残留导致无法启动的问题
- 统一一键安装示例为最短的 `curl | sh -s -- 客户端密钥 UUID`
- 确认变量会保存到 VPS，开机自愈时无需再次传入

### 0.7.3

- 修复一键安装时变量持久化函数缺失的问题
- 统一最短一键命令为 `curl | sh -s -- 客户端密钥 UUID`
- 确保首次安装中断后，重启仍能读取已保存变量继续自愈

### 0.7.2

- 将一键命令统一为 `curl | sh -s -- 客户端密钥 UUID`
- 首次运行立即保存哪吒变量，安装中断后重启仍可继续自愈
- 开机服务无需再次传入密钥，自动读取受限配置文件

### 0.7.1

- 一键命令改为强制传入客户端密钥和 UUID
- 支持通过两个位置参数附加变量，缩短一键命令
- 首次执行时立即保存变量，安装中断后重启仍可继续自愈
- 移除源码和文档中的真实凭据，避免发布到 GitHub
- 缺少必要变量时立即退出并显示正确用法

### 0.7.0

- 增加极短的一键安装引导脚本 `install.sh`
- 支持通过管道参数传入 `NZ_CLIENT_SECRET` 和 `NZ_UUID`
- 一键下载完整项目并安装到 `/opt/startup-script`
- 增加 GitHub 项目使用说明

### 0.6.1

- 强化哪吒配置指纹和安装脚本校验
- 完成配置持久化、重试和服务模板验证
