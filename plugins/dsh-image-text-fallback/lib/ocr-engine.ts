/**
 * OCR Engine - 基于 onnxruntime-node 的 OCR 引擎
 * 
 * 使用 PaddleOCR v4 模型,支持文字检测+识别
 * 模型文件自动下载到 ~/.dsh/models/ocr/
 */

import { join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);

/** 模型版本 */
const MODEL_VERSION = '2.0.0';

/** 模型下载 URL */
const MODEL_URLS = {
  det: 'https://github.com/RapidAI/RapidOCR/releases/download/v1.4.4/ch_PP-OCRv4_det_infer.onnx',
  rec: 'https://github.com/RapidAI/RapidOCR/releases/download/v1.4.4/ch_PP-OCRv4_rec_infer.onnx',
};

/** OCR 配置 */
export interface OcrConfig {
  modelDir?: string;
  timeoutMs?: number;
}

/** OCR 结果 */
export interface OcrResult {
  ok: boolean;
  text?: string;
  confidence?: number;
  lines?: Array<{
    text: string;
    confidence: number;
    box?: number[][];
  }>;
  error?: string;
  engine?: string;
  elapsed_ms?: number;
}

/**
 * OCR 引擎类
 */
export class OcrEngine {
  private modelDir: string;
  private timeoutMs: number;
  private initialized = false;

  constructor(config: OcrConfig = {}) {
    this.modelDir = config.modelDir || join(homedir(), '.dsh', 'models', 'ocr');
    this.timeoutMs = config.timeoutMs || 120000;
  }

  /**
   * 初始化:检查/下载模型
   */
  async init(): Promise<void> {
    if (this.initialized) return;

    // 确保模型目录存在
    if (!existsSync(this.modelDir)) {
      mkdirSync(this.modelDir, { recursive: true });
    }

    // 检查模型是否需要下载
    const versionFile = join(this.modelDir, '.version');
    if (!existsSync(versionFile) || readFileSync(versionFile, 'utf8') !== MODEL_VERSION) {
      await this.downloadModels();
      writeFileSync(versionFile, MODEL_VERSION);
    }

    this.initialized = true;
  }

  /**
   * 下载模型文件
   */
  private async downloadModels(): Promise<void> {
    console.log('[OCR] 下载模型文件...');
    
    for (const [name, url] of Object.entries(MODEL_URLS)) {
      const targetPath = join(this.modelDir, `${name}.onnx`);
      if (!existsSync(targetPath)) {
        console.log(`[OCR] 下载 ${name} 模型...`);
        await execFileAsync('curl', ['-L', '-o', targetPath, url], {
          timeout: 60000,
        });
      }
    }
    
    console.log('[OCR] 模型下载完成');
  }

  /**
   * 执行 OCR 识别
   */
  async recognize(imagePath: string): Promise<OcrResult> {
    await this.init();

    const startTime = Date.now();

    try {
      // 使用 Python ocr.py 执行(过渡方案,后续用 TS 重写)
      const { stdout } = await execFileAsync(
        join(homedir(), '.ocr-tool', 'venv', 'bin', 'python'),
        [join(homedir(), '.ocr-tool', 'ocr.py'), imagePath, '--mode', 'json', '--profile', 'balanced'],
        { timeout: this.timeoutMs, maxBuffer: 64 * 1024 * 1024 }
      );

      const result = JSON.parse(stdout.trim());
      const elapsed = Date.now() - startTime;

      return {
        ok: result.ok,
        text: result.result,
        confidence: result.confidence,
        engine: result.metadata?.engine,
        elapsed_ms: elapsed,
      };
    } catch (error) {
      return {
        ok: false,
        error: String(error),
        engine: 'exception',
        elapsed_ms: Date.now() - startTime,
      };
    }
  }

  /**
   * 检查是否可用
   */
  async check(): Promise<{ available: boolean; error?: string }> {
    try {
      await this.init();
      
      // 检查 Python 和 ocr.py
      const pythonPath = join(homedir(), '.ocr-tool', 'venv', 'bin', 'python');
      const ocrScript = join(homedir(), '.ocr-tool', 'ocr.py');
      
      if (!existsSync(pythonPath)) {
        return { available: false, error: 'Python venv 未安装' };
      }
      if (!existsSync(ocrScript)) {
        return { available: false, error: 'ocr.py 未安装' };
      }

      return { available: true };
    } catch (error) {
      return { available: false, error: String(error) };
    }
  }
}

export default OcrEngine;
