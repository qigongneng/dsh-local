# dsh-host-history-lite

> English: [README.md](./README.md)


[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) `dsh web` 的 host 端插件：
在历史记录离开服务器之前压缩 payload——把已完结 step 的 `assistant/chunk` delta 折叠掉，
只保留最终 `assistant/message`、首个可见 token delta 和 usage chunk，大幅缩减长流式会话的
`session.history` / `subagent.history` 响应体积。

## 功能

- 注册精确路由 `/api/session.history` 和 `/api/subagent.history`（优先于通用 `/api` 前缀路由）；
- 已完结 step：丢弃冗余 chunk（text/reasoning/tool delta、block 起止、finish）；
- 未完结/被打断的 step：保留全部 chunk，保证部分渲染和轨迹视图完整；
- 不触碰实时流式推送，只影响回放已记录事件的历史 RPC。

## 要求

- `dsh web`（Harness 0.1 系列），运行时需要 `ctx.webServer` 与 `ctx.apiProxy` 服务（随 `dsh web` 自带）。

## 安装

### `dsh plugin add`（推荐）

本包声明了 `dsh.bundle`，安装后自动挂载为 profile 配置层：

```sh
# 本地目录 / tarball
dsh plugin --profile web add ./dsh-host-history-lite
dsh plugin --profile web add ./dsh-host-history-lite-0.1.0.tgz

# npm / git（git 安装需要 prepare 脚本 + 首次 add 的 allowBuilds）
dsh plugin --profile web add dsh-host-history-lite
```

重启 `dsh web` 后生效。

### 手动 patch

把 `cordis.patch.yml` 追加到 profile 的 `cordis.patch.yml`（或 `dsh web --patch ./cordis.patch.yml`），
并确保包可被 loader 解析（`dsh plugin add` 之外也可软链到 `$DSH_HOME/profiles/node_modules/`）。

## 开发

```sh
pnpm install      # 首次（prepare 自动构建）
pnpm build        # tsdown → lib/index.js
pnpm typecheck    # tsc --noEmit（仅 src；tests 由 vitest 转译运行）
pnpm test         # vitest run（纯函数测试）
```

开发循环：改 `src/` → `pnpm build` → 重启 `dsh web`（host 端插件无 HMR 热更新，需重启）。

## 工作原理

- `slimHistoryEvents`（纯函数，单元测试覆盖）：先收集已有最终 `assistant/message` 的
  `turn:step`，再逐条过滤 chunk；
- `historyRoute`：读 body → 转 WHATWG Request → 调 `toFetchHandler(ctx.apiProxy)` 代理 →
  对 `result.ok` 的 events 数组做瘦身 → 原样回写；
- `ctx.webServer.register({ kind: 'exact', path })` 注册精确路由，`ctx.effect()` 提供 disposer。

## 已知限制

- 只处理 `assistant/chunk` / `assistant/message` 事件族；其他事件类型原样透传；
- 依赖内置事件结构的字段名（`turn`/`step`/`chunk.type`），上游协议演进需同步适配；
- 运行时依赖 `@deepseek-ai/dsh-host-apiproxy` 的 `toFetchHandler`（`dependencies` 声明，外部解析）。

## License

MIT