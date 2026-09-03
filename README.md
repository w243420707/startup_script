# VPS Startup Script

面向 VPS 的无人值守开机自愈脚本，支持自动识别 Linux 发行版、CPU 架构和包管理器，并自动安装及修复哪吒探针。

## 一键安装

使用 root 用户执行，三个参数依次填写服务器地址、客户端密钥和 UUID：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | sh -s -- '服务器地址:端口' '客户端密钥' 'UUID'
```

这条命令会：

1. 下载完整项目到 `/opt/startup-script`
2. 安装并启动哪吒探针
3. 注册 VPS 开机自动执行的自愈服务
4. 保存哪吒配置，后续开机无需再次输入变量

`NZ_TLS` 默认启用：

```text
NZ_TLS=true
```

如需关闭 TLS，可以额外附加环境变量：

```bash
curl -fsSL https://raw.githubusercontent.com/w243420707/startup_script/main/install.sh | NZ_TLS='false' sh -s -- '服务器地址:端口' '客户端密钥' 'UUID'
```

## 变量说明

```text
第一个位置参数：NZ_SERVER（哪吒服务器地址，包含端口）
第二个位置参数：NZ_CLIENT_SECRET（哪吒客户端密钥）
第三个位置参数：NZ_UUID（哪吒客户端 UUID）
```

三个参数都必须提供，值建议使用单引号包起来。

## 手动管理

```bash
/opt/startup-script/startup.sh check
/opt/startup-script/startup.sh install --yes
/opt/startup-script/startup.sh version
```

修改服务器地址、密钥或 UUID：

```bash
env NZ_SERVER='新的服务器地址:端口' NZ_CLIENT_SECRET='新的客户端密钥' NZ_UUID='新的UUID' /opt/startup-script/startup.sh install --yes
```

## 更新日志

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
