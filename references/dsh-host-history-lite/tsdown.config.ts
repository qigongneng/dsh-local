/**
 * Standalone build for dsh-host-history-lite.
 *
 * A plain Node ESM bundle for the dsh loader: package main `lib/index.js`.
 * The runtime dependency `@deepseek-ai/dsh-host-apiproxy` stays external
 * (tsdown's default for package dependencies) and resolves from node_modules
 * at load time; cordis and webserver appear only as type imports and are
 * erased.
 */
import { defineConfig } from 'tsdown'

export default defineConfig([
  {
    name: 'dsh-host-history-lite',
    entry: 'src/index.ts',
    outDir: 'lib',
    format: ['esm'],
    platform: 'node',
    target: 'es2024',
    fixedExtension: false,
    dts: false,
    clean: false,
  },
])
