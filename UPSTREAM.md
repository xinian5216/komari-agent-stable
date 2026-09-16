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

**唯一目的：建立本 fork 自己的安装、更新与 Release 来源。业务逻辑与 v2 协议行为不变。**

1. `install.sh` / `install.ps1`：owner/repo 集中为脚本顶部的 `REPO_OWNER` / `REPO_NAME` /
   `GITHUB_API_BASE` / `GITHUB_RELEASE_BASE`（可用环境变量覆盖），并把所有 GitHub API 与
   Release 下载地址从上游仓库切换到本 fork 的 `xinian5216/komari-agent-stable`。
2. `update/update.go`：Agent 自更新的默认仓库 slug 由 `komari-monitor/komari-agent`
   改为 `xinian5216/komari-agent-stable`（仍可用 `-ldflags` 覆盖）。
3. 删除 `.github/workflows/generate-release-notes.yml`（依赖 `OPENAI_API_KEY`，
   本 fork 的发版说明由人工维护）。以普通提交删除，**保留 git 历史**。

## 4. 明确不改动的部分

- **v2 协议与线上行为**：`protocol/`、`server/`、`ws/`、`terminal/`、`monitoring/` 等业务代码未改；
  Agent 仍按官方 v2 协议与 Komari 服务端通信，服务端与旧 Agent 的兼容性不变。
- Go module path 仍为 `github.com/komari-monitor/komari-agent`（改 module path 会波及全仓库
  import 并破坏与上游的对照关系）。
- `LICENSE`、版权声明、上游署名链接。

## 5. 溯源方法

```bash
git diff upstream-baseline --stat     # 全部差异
git diff upstream-baseline -- <path>  # 单文件差异
```
