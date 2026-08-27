# dsh-host-history-lite

A host-side plugin for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) `dsh web` that slims down `session.history` / `subagent.history` responses before they leave the server.

For long streaming sessions, it folds finalized `assistant/chunk` deltas from completed steps into the final `assistant/message`, keeping the first visible token delta and usage chunk. This dramatically reduces history payload sizes without touching realtime streaming.

> 中文版说明见 [README.zh.md](./README.zh.md)

## Features

- Registers exact routes `/api/session.history` and `/api/subagent.history` (takes priority over the generic `/api` prefix route).
- Completed steps: drops redundant chunks (text / reasoning / tool deltas, block start/stop, finish).
- Unfinished / interrupted steps: keeps all chunks, so partial rendering and trajectory views remain complete.
- Does not touch realtime streaming; only affects history RPCs that replay recorded events.

## Requirements

- `dsh web` (Harness 0.1 series)
- Runtime services `ctx.webServer` and `ctx.apiProxy` (shipped with `dsh web`)

## Installation

This package declares a `dsh.bundle`, so it is mounted as a profile layer automatically by `dsh plugin add`.

### `dsh plugin add` (recommended)

```sh
# From npm
dsh plugin --profile web add dsh-host-history-lite

# Or from GitHub
dsh plugin --profile web add github:GithungDang/dsh-host-history-lite#v0.1.0

# Or local directory / tarball
dsh plugin --profile web add ./dsh-host-history-lite
dsh plugin --profile web add ./dsh-host-history-lite-0.1.0.tgz
```

Restart `dsh web` after installation.

### Manual patch

Append `cordis.patch.yml` to your profile’s `cordis.patch.yml` (or use `dsh web --patch ./cordis.patch.yml`), and make sure the package is resolvable by the loader (e.g. symlinked into `$DSH_HOME/profiles/node_modules/`).

## Development

```sh
pnpm install      # first run; prepare builds automatically
pnpm build        # tsdown → lib/index.js
pnpm typecheck    # tsc --noEmit
pnpm test         # vitest run (pure-function tests)
```

Development loop: edit `src/` → `pnpm build` → restart `dsh web` (host-side plugins have no HMR).

## How it works

- `slimHistoryEvents` (pure function, covered by unit tests): first collects `turn:step` values that already have a final `assistant/message`, then filters chunks step by step.
- `historyRoute`: reads the request body → converts to a WHATWG `Request` → proxies through `toFetchHandler(ctx.apiProxy)` → slims the events array when the response is OK → writes back.
- `ctx.webServer.register({ kind: 'exact', path })` registers the exact routes, and `ctx.effect()` provides disposal.

## Known limitations

- Only handles the `assistant/chunk` / `assistant/message` event families; all other event types pass through untouched.
- Depends on internal event field names (`turn` / `step` / `chunk.type`); upstream protocol evolution requires adaptation.
- Runtime dependency: `@deepseek-ai/dsh-host-apiproxy` (declared in `dependencies`).

## License

MIT
