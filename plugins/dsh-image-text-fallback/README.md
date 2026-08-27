# dsh-image-text-fallback

DeepSeek Harness 插件:图片自动降级(OCR 转文本)。

纯文本路由(如 deepseek-official)遇到 image 块时,自动调用本地
[ocr.py](ocr.py 由 `~/.ocr-tool` 提供)把图片转成文本块替换,避免
适配器抛 `UNSUPPORTED_CONTENT`;真正支持 image 输入的视觉模型原样放行。

## 工作原理

两层拦截,基于 Cordis 事件/服务包装:

1. **模型能力上报放行** — 包装 `llm.resolveModelInfo`:凡 `inputModalities`
   不含 "image" 的纯文本路由,能力上报为 `undefined`(unknown),放行 host
   的图片提交检查(`Model does not support image input`)——否则带图消息在
   提交时就被拒绝,根本到不了请求边界。
2. **请求前图片转译** — 包装 `llm.prepareCall/stream`:请求前扫描
   `options.messages` 中的 image 块(含 tool-result 内嵌、按 attachmentId
   去重、小并发保护),调 `ocr.py --mode json --both` 转成
   `【图片内容】` 文本块替换。

特性:

- **内容哈希缓存**(进程内):同一图片字节只 OCR 一次(默认 cap 200)。
- **自愈重试**:默认档失败自动升级 `--profile accurate`(强制 PaddleOCR-VL)。
- **交叉验证回退**:ocr.py 短文本交叉验证要求 VLM 复核但不可用时,返回
  OCR 快速通道结果并加 ⚠ 标注。
- **可操作失败占位**:区分「图中无可转录文字」「本地视觉服务异常」。

## 安装

确认依赖可用:

```bash
npm install   # 或 pnpm install / bun install
```

本地 `node_modules` 只需 `@deepseek-ai/schemastery`(运行时由 profile 的
peerDependencies 提供 `@deepseek-ai/cordis`)。

## 配置

通过 cordis 插件配置注入,默认值:

| 字段 | 默认 | 说明 |
|---|---|---|
| `enabled` | `true` | 是否启用 |
| `ocrScript` | `~/.ocr-tool/ocr.py` | ocr.py 脚本路径 |
| `venvPython` | `~/.ocr-tool/venv/bin/python` | ocr.py 依赖的 venv Python |
| `timeoutMs` | `120000` | 单次 OCR 超时 |
| `maxConcurrent` | `2` | 最大并发 OCR 数(1–8) |
| `cacheCap` | `200` | 内容哈希缓存上限(1–1000) |
| `textOnlyProviders` | `[]` | 显式强制纯文本的 provider(默认空 = 按模型自动识别) |

## 开发

```bash
npm test       # 运行测试(node --test)
```

源码在 `lib/index.js`,类型声明在 `lib/types/index.d.ts`。

## 维护提示

- 改插件后需**重启对应环境**(`dsh web` 或重启 Oh-DSH Desktop)才生效。
- 视觉路由(inputModalities 含 "image")不受本插件影响。

## 官方规范参考

- [打包与安装插件](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/publish.md) — Bundle/Profile 机制
- [插件配置](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/basic/config.md) — Config schema 定义
- [Cordis 入门](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-primer.zh.md) — 核心概念与事件模式