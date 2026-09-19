# UPSTREAM.md — 上游来源与本 fork 关系（komari-agent-stable）

> 溯源记录：任何时候都能据此判断"哪些是原项目代码，哪些是 Komari Stable 的改动"。

## 1. 原项目

| 项 | 值 |
| --- | --- |
| Original Project | **Komari Agent**（Komari 的监控探针，Go 实现） |
| Original Repository | https://github.com/komari-monitor/komari-agent |
| Original License | 见仓库内 `LICENSE`（原样保留，未做任何改动） |
| Copyright / Credits | 归原作者与贡献者所有；上游署名与链接保留 |

## 2. Fork 基线

| 项 | 值 |
| --- | --- |
| Fork 日期 | 2026-09-16 |
| 基线 ref | upstream tag `1.5.10` |
| 基线 commit | `9e532e0429cd049571e35cf344654181879b33c7` |
| 维护分支 | `stable`（本仓库默认分支） |
| 只读镜像分支 | `upstream-baseline`（= 上述基线 commit，**永不修改**） |
| 固定 tag | `v1.5.10-stable.0` |
| 维护者 | `xinian5216` |

## 3. 本 fork 的改动（相对上游基线）

初始目的为建立本 fork 自己的安装、更新与 Release 来源；后续在不破坏 v2 兼容性的前提下，将 Agent
收敛为纯监控探针，并加入能力上报和供应链校验。所有新增协议字段均为可选字段。

1. `install.sh` / `install.ps1`：owner/repo 集中为脚本顶部的 `REPO_OWNER` / `REPO_NAME` /
   `GITHUB_API_BASE` / `GITHUB_RELEASE_BASE`（可用环境变量覆盖），并把所有 GitHub API 与
   Release 下载地址从上游仓库切换到本 fork 的 `xinian5216/komari-agent-stable`。
2. `update/update.go`：Agent 自更新的默认仓库 slug 由 `komari-monitor/komari-agent`
   改为 `xinian5216/komari-agent-stable`（仍可用 `-ldflags` 覆盖）。
3. 删除 `.github/workflows/generate-release-notes.yml`（依赖 `OPENAI_API_KEY`，
   本 fork 的发版说明由人工维护）。以普通提交删除，**保留 git 历史**。
4. 新增官方 Agent 原地接管脚本：保留 endpoint、token 与全部 systemd 参数，备份旧二进制后切换到
   本 fork，并支持状态检查与回滚。
5. 安装、迁移和自更新加入发布校验和验证；缺失或不匹配时 fail closed，并兼容单资产 `.sha256` 与
   `SHA256SUMS`。
6. 删除通用命令执行、PTY/Web 终端、任意文件管理与传输实现；`agent.exec`、`agent.terminal.request`、
   `agent.file` 只保留协议标识并 fail closed，发布二进制不再编译这些能力。
7. `--disable-web-ssh`、`--disable-remote-control` 和 `AGENT_DISABLE_WEB_SSH` 暂留一个发布周期作为隐藏
   no-op，保证旧 systemd/Windows 服务原地升级后仍能启动；安装器不再提供启用远控的选择。
8. v2 `agent.report` 新增可选的 `capabilities` / `privilege_level` 上报，且 capability 永远仅包含
   `ping`、`message`、`event`；
   旧端忽略新字段时保持兼容。
9. Release / Docker / Snapshot 加入不可变资产守卫、校验和、真实迁移测试及供应链硬门禁。

## 4. 兼容性边界

- **v2 既有协议不变**：已有方法和字段未改名或删除；新增 capability 字段可选，旧 Server/Agent 可忽略。
- 遗留远控方法名只用于识别并拒绝旧 Server 请求，不代表实现或 capability 仍然存在。
- 监控数据语义、采集周期、节点 token 与 endpoint 格式保持不变。
- Go module path 仍为 `github.com/komari-monitor/komari-agent`（改 module path 会波及全仓库
  import 并破坏与上游的对照关系）。
- `LICENSE`、版权声明、上游署名链接。

## 5. 溯源方法

```bash
git diff upstream-baseline --stat     # 全部差异
git diff upstream-baseline -- <path>  # 单文件差异
```
