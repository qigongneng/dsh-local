# DSH History Lite Local

这是为本机官方 DSH `0.1.1-rc.2` 适配的保守型历史回放压缩插件。

它只影响 `session.history` 和 `subagent.history` 的 HTTP 历史回放：已完成步骤中，可由最终 `assistant/message` 重建的流式增量会被折叠；实时生成、磁盘会话文件、最终消息、用量信息、未完成步骤和未知事件类型不会被修改。

实现参考：<https://github.com/GithungDang/dsh-host-history-lite> `v0.1.0` (`c1c9e074656d32bed225ea4d7c757e451d5c7b90`)。本地版额外保留未知 chunk 类型，并修正空 tool-call delta 被误判为首 token 的边界情况。

安装：

```sh
dsh plugin --profile web add /Users/qigongneng/Application/CODE/DSH-Local-Official/plugins/dsh-host-history-lite-local
```

卸载：

```sh
dsh plugin --profile web remove dsh-host-history-lite-local
```

插件使用 DSH Host 的内部接口。每次官方 DSH 版本更新后，应先运行测试和历史接口冒烟测试；发现不兼容时可直接卸载，磁盘会话数据不受影响。
