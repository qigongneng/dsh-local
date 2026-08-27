# DSH Local 长会话性能修复验证

日期：2026-08-27  
官方运行时：`0.1.1-rc.2`  
测试会话：`session-a709d9b3-35d1-4bdb-964a-0b5bb83cb783`（4 轮、43 步）

## 结论

已安装本地兼容插件 `dsh-host-history-lite-local`。它仅压缩已完成步骤的 HTTP 历史回放，不修改实时生成与磁盘会话源数据。

| 指标 | 修复前 | 修复后 | 变化 |
|---|---:|---:|---:|
| 历史事件 | 19,734 | 360 | -98.18% |
| HTTP 响应 | 4,237,032 B | 837,525 B | -80.23% |
| 最终 assistant 消息 | 42 | 42 | 不变 |
| 冷启动到可交互 | — | 2.24 s | 正常 |
| 对话/轨迹切换 | — | 0.62 s / 1.18 s | 正常 |

修复后的事件数组与对修复前事件执行保守压缩算法的结果完全一致；42 条最终消息、`projections` 和 `hasMore` 均逐项相等。

磁盘源会话修复前后 SHA-256 均为：

```text
298bd5178ad04efb3b0114426db6349b7aeeaa13facca56ee84fb53c1dd376cf
```

插件 6 组单元测试、隔离 Host 启动测试、HTTP 路由测试和生产依赖审计均通过；依赖审计未发现已知漏洞。

## 官方更新兼容

更新器会先在隔离 `DSH_HOME` 中将插件加载到候选官方版本，并通过 `session.history` 路由响应头确认生效：

- 兼容：记录该官方版本并继续启用插件。
- 不兼容：仍更新官方核心，只对该版本禁用 `history-lite-local`，避免桌面端启动失败。

该保护分支已用模拟未验证版本完成实测。

## 路径与回退

- 插件源码：`/Users/qigongneng/Application/CODE/DSH-Local-Official/plugins/dsh-host-history-lite-local`
- 参考源码：`/Users/qigongneng/Application/CODE/DSH-Local-Official/references/dsh-host-history-lite`
- 修复前数据备份：`/Users/qigongneng/Library/Application Support/DSHLocalOfficial/backups/dsh-20260827-before-history-lite`
- 修复前桌面壳：`/Users/qigongneng/Library/Application Support/DSHLocalOfficial/backups/DSH Local-before-history-lite-20260827.app`

卸载性能层：

```sh
/Users/qigongneng/Application/CODE/DSH-Local-Official/scripts/uninstall-history-lite.sh
```

卸载后重启 DSH Local 生效。会话源数据不需要迁移或恢复。

## 参考

- DSH 官方仓库社区讨论：<https://github.com/deepseek-ai/deepseek-harness/discussions/2669>
- 相似插件：<https://github.com/GithungDang/dsh-host-history-lite>
