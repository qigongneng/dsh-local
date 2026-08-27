import type { Context } from "@deepseek-ai/cordis";

/** dsh-image-text-fallback 插件配置 */
export interface Config {
  /** 是否启用,默认 true */
  enabled: boolean;
  /** ocr.py 脚本路径 */
  ocrScript: string;
  /** ocr.py venv Python 路径 */
  venvPython: string;
  /** 单次 OCR 超时(ms) */
  timeoutMs: number;
  /** 最大并发 OCR 数 */
  maxConcurrent: number;
  /** 内容哈希缓存上限 */
  cacheCap: number;
  /** 显式强制纯文本的 provider 名单(默认空 = 自动识别) */
  textOnlyProviders: string[];
}

export const name: "image-text-fallback";

export const inject: readonly ["llm", "attachments"];

export const Config: import("@deepseek-ai/schemastery").default<Config>;

export function apply(ctx: Context, config: Config): void;
