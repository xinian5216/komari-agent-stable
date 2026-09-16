# komari-agent

## 配置方式

agent 参数可以通过命令行参数、环境变量或 JSON 配置文件传入。

最小启动示例：

```bash
./komari-agent --endpoint "https://example.com" --token "your-token"
```

使用环境变量：

```bash
export AGENT_ENDPOINT="https://example.com"
export AGENT_TOKEN="your-token"
./komari-agent
```

使用 JSON 配置文件：

```bash
./komari-agent --config ./config.json
```

`config.json` 示例：

```json
{
  "endpoint": "https://example.com",
  "token": "your-token",
  "interval": 3,
  "disable_auto_update": false,
  "disable_web_ssh": false,
  "ignore_unsafe_cert": false
}
```

配置优先级从低到高为：默认值、命令行参数、环境变量、JSON 配置文件。

常用配置项：

表中支持版本表示该参数本身首次在发布 tag 中出现；环境变量和 JSON 配置文件方式从 `1.1.33` 起支持，早于最早 tag 的参数记为 `0.0.9`。

| JSON 字段 | 环境变量 | 命令行参数 | 说明 | 支持版本 |
| --- | --- | --- | --- | --- |
| `endpoint` | `AGENT_ENDPOINT` | `--endpoint`, `-e` | 面板地址 | `0.0.9` |
| `token` | `AGENT_TOKEN` | `--token`, `-t` | agent token | `0.0.9` |
| `interval` | `AGENT_INTERVAL` | `--interval`, `-i` | 数据采集间隔，单位秒 | `0.0.9` |
| `disable_auto_update` | `AGENT_DISABLE_AUTO_UPDATE` | `--disable-auto-update` | 禁用自动更新 | `0.0.9` |
| `disable_web_ssh` | `AGENT_DISABLE_WEB_SSH` | `--disable-web-ssh` | 禁用远程控制 | `0.0.9` |
| `ignore_unsafe_cert` | `AGENT_IGNORE_UNSAFE_CERT` | `--ignore-unsafe-cert`, `-u` | 忽略不安全证书 | `0.0.9` |
| `include_nics` | `AGENT_INCLUDE_NICS` | `--include-nics` | 仅统计指定网卡，逗号分隔 | `0.0.22` |
| `exclude_nics` | `AGENT_EXCLUDE_NICS` | `--exclude-nics` | 排除指定网卡，逗号分隔 | `0.0.22` |
| `include_mountpoints` | `AGENT_INCLUDE_MOUNTPOINTS` | `--include-mountpoint` | 仅统计指定挂载点，分号分隔 | `0.1.0` |
| `month_rotate` | `AGENT_MONTH_ROTATE` | `--month-rotate` | 流量统计每月重置日期，`0` 为禁用 | `0.1.0` |
| `auto_discovery_key` | `AGENT_AUTO_DISCOVERY_KEY` | `--auto-discovery` | 自动发现密钥 | `1.0.40` |
| `custom_dns` | `AGENT_CUSTOM_DNS` | `--custom-dns` | 自定义 DNS 服务器 | `1.0.80` |
| `enable_gpu` | `AGENT_ENABLE_GPU` | `--gpu` | 启用详细 GPU 监控 | `1.0.80` |
| `disable_compression` | `AGENT_DISABLE_COMPRESSION` | `--disable-compression` | 禁用 v2 传输压缩 | `1.2.10` |
| `prefer_ip_version` | `AGENT_PREFER_IP_VERSION` | `--prefer-ip-version` | 优先使用 IP 版本，可选 `4` 或 `6` | 未发布 |

完整参数可运行：

```bash
./komari-agent --help
```

详见 `cmd/flags/flags.go` 及 `cmd/root.go`

## 安装 / 迁移 / 更新（本 fork）

本仓库（`xinian5216/komari-agent-stable`）是 Komari Agent 的社区维护稳定分支。
安装、自更新与 Release 下载**全部指向本仓库**，协议仍为官方 v2，向后兼容。

### 全新安装

```bash
curl -fsSL https://raw.githubusercontent.com/xinian5216/komari-agent-stable/stable/install.sh | sudo bash -s -- -e <ENDPOINT> -t <TOKEN>
```

### 从官方 Agent 迁移（保留节点与 token）

主控升级不会改变已安装 Agent 的自更新来源，因此既有节点需执行一次迁移：

```bash
curl -fsSL https://raw.githubusercontent.com/xinian5216/komari-agent-stable/stable/migrate-komari-agent.sh | sudo bash -s -- -y
```

脚本会：读取现有 systemd 单元里的全部启动参数（endpoint / token / interval 等）并原样保留 →
备份旧二进制 → 下载并校验新二进制 → 替换 → 重启 → 打印日志中的 `Github Repo:` 行确认来源已切换。

**不需要重新添加节点、不需要重新生成 token、不会丢失历史数据。**

查看当前状态（只读）：

```bash
bash migrate-komari-agent.sh --status
```

### 回滚

```bash
sudo systemctl stop komari-agent
sudo cp /opt/komari/agent.backup.<时间戳> /opt/komari/agent
sudo systemctl start komari-agent
```
