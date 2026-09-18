# Security Policy — Komari Agent Stable

本仓库维护 Komari Stable 使用的 Agent。安全问题请优先通过本仓库
[Private Security Advisory](https://github.com/xinian5216/komari-agent-stable/security/advisories/new)
私密报告，不要先建立公开 Issue。

## 范围

重点包括：

- 来自 Server 的命令、终端、文件与任务请求；
- Agent 以 root、Administrator 或 SYSTEM 运行时的权限提升影响；
- WebSocket/RPC 认证、节点 Token 与更新通道；
- 安装、迁移、自更新、校验和与 Release 供应链；
- 采集器导致的本地文件泄露、崩溃或资源耗尽；
- Go 依赖中的代码可达漏洞。

报告请包含受影响版本、操作系统、启动参数（删除 Token）、最小复现、影响和可能的缓解方式。
不要提交真实节点 Token、面板地址、私钥或可直接滥用的 PoC。

跨 Server/Web/Agent 的问题由
[Komari Stable 安全响应流程](https://github.com/xinian5216/komari-stable/blob/stable/SECURITY_RESPONSE.md)
统一协调。本项目为志愿维护，不承诺商业 SLA，但 P0/P1 会优先处理。