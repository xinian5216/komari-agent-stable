# AGENTS.md — Komari Agent Stable 工作规则

本仓库维护 Komari Stable 的探针、安装/接管脚本和自更新供应链。Agent 运行在被监控主机上，拥有的权限
可能很高，因此协议、遗留远控拒绝路径、安装器和更新器均按安全敏感代码处理。

## 进入仓库后先读

1. `UPSTREAM.md`：上游基线与 fork 实际差异；
2. `readme.md`：参数、安装、迁移和回滚约定；
3. 按任务读取 `protocol/v2/`、`server/`、`update/`、安装脚本及对应 CI。

禁止先递归扫描全仓库；先沿任务入口定位相关文件。

## 红线

- v2 线协议冻结。已有方法和字段不能改名/删除；新增字段必须可选，旧 Server/Agent 必须能忽略。
- capability 必须反映 Agent 实际可执行能力，不能为通过 UI 门禁而虚报。
- 本 fork 永远仅监控；不得重新加入远程命令、交互终端或任意文件操作实现。旧远控协议方法只能明确拒绝。
- 官方 Agent 接管时必须原样保留 systemd 启动参数、endpoint 和 token；历史禁用参数作为 no-op 保持可解析。
- token、endpoint 和旧请求内容不得写入测试日志、Release 说明或错误回传。
- 安装、迁移、自更新必须先下载到暂存文件，验证发布方校验和后原子替换；校验缺失或不匹配时拒绝更新。
- 固定 tag 和已发布资产不可覆盖；发布重跑只能补缺，且必须验证现有资产与镜像不可变。
- 不得未经确认修改自动更新仓库、systemd 单元格式、CLI 参数语义或 Windows 服务行为。

## 高风险联动

- 改 `protocol/v2` 或 capability：同步检查 `server/` 上报、远控拒绝、Server 仓库兼容测试和 Web UI 门禁。
- 改 `install.sh` / `install.ps1` / `migrate-komari-agent.sh`：覆盖 Linux/Windows、校验和失败、启动失败回滚、
  带空格/引号参数和重复执行。
- 改 `update/`：覆盖 per-asset `.sha256`、`SHA256SUMS`、MSYS `*filename` 格式、下载失败和原子替换。
- fork 行为变化后必须同步更新 `UPSTREAM.md` 与 `readme.md`，不能继续声称“业务逻辑未改”。

## 提交前检查

```bash
go test ./... -count=1
go vet ./...
bash .github/tests/test-install-remote-control.sh
bash .github/tests/test-supply-chain.sh
bash .github/tests/test-release-guard.sh
```

涉及 Windows 的代码还需由对应 CI 验证。提交保持单一目的，禁止 force push、重写 tag 或覆盖 Release。
