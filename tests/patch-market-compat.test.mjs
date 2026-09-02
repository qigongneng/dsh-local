import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const projectRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const helper = join(projectRoot, 'scripts', 'patch-market-compat.mjs')

function writeFixture(file, contents) {
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, contents)
}

test('patches market and Mineradio in a Windows-style npm layout', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-local-windows-'))
  const profile = join(root, '.dsh', 'profiles', 'web')
  const runtime = join(root, 'AppData', 'Roaming', 'npm', 'node_modules', '@deepseek-ai', 'dsh')
  const market = join(profile, 'node_modules', 'dshmarket')
  const mineradio = join(profile, 'node_modules', 'dsh-theme-mineradio')

  writeFixture(join(runtime, 'package.json'), '{"name":"@deepseek-ai/dsh","version":"0.1.2-alpha.4"}')
  writeFixture(join(runtime, '..', 'dsh-client-store', 'package.json'), '{"name":"@deepseek-ai/dsh-client-store"}')
  writeFixture(join(market, 'package.json'), '{"name":"dshmarket","version":"1.39.0"}')
  writeFixture(join(market, 'lib', 'themes.js'), 'const themeNames = new Set(themeEntries.map(p => p.name));')
  writeFixture(join(market, 'lib', 'routes.js'), '                    pendingRollbacks.clear();\n                    const activated = await themes.activateTheme(name);')
  writeFixture(join(mineradio, 'package.json'), '{\n  "name": "dsh-theme-mineradio",\n  "version": "2.3.5",\n  "dsh": {\n    "inject": [\n        "@deepseek-ai/dsh-client-runtime",\n        "@deepseek-ai/dsh-client-locale",\n        "@deepseek-ai/dsh-client-ui"\n    ]\n  }\n}')
  writeFixture(join(mineradio, 'lib', 'client.js'), 'const store = require("@deepseek-ai/dsh-client-runtime/client")')

  execFileSync(process.execPath, [helper, profile, runtime])

  assert.match(readFileSync(join(market, 'lib', 'themes.js'), 'utf8'), /p\.npm/)
  assert.match(readFileSync(join(market, 'lib', 'routes.js'), 'utf8'), /enableRow/)
  assert.match(readFileSync(join(mineradio, 'lib', 'client.js'), 'utf8'), /dsh-client-store/)
  assert.match(readFileSync(join(mineradio, 'package.json'), 'utf8'), /dsh-client-store/)

  // Every replacement is idempotent, so running at each startup is safe.
  const before = readFileSync(join(mineradio, 'lib', 'client.js'), 'utf8')
  execFileSync(process.execPath, [helper, profile, runtime])
  assert.equal(readFileSync(join(mineradio, 'lib', 'client.js'), 'utf8'), before)
})

test('does not migrate Mineradio when the runtime lacks the new store', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-local-legacy-'))
  const profile = join(root, '.dsh', 'profiles', 'web')
  const runtime = join(root, 'npm', 'node_modules', '@deepseek-ai', 'dsh')
  const market = join(profile, 'node_modules', 'dshmarket')
  const mineradio = join(profile, 'node_modules', 'dsh-theme-mineradio')
  const legacyRequire = 'require("@deepseek-ai/dsh-client-runtime/client")'

  writeFixture(join(runtime, 'package.json'), '{"name":"@deepseek-ai/dsh","version":"0.1.1-rc.2"}')
  writeFixture(join(market, 'package.json'), '{"name":"dshmarket","version":"1.39.0"}')
  writeFixture(join(mineradio, 'package.json'), '{"name":"dsh-theme-mineradio","version":"2.3.5"}')
  writeFixture(join(mineradio, 'lib', 'client.js'), legacyRequire)

  execFileSync(process.execPath, [helper, profile, runtime])
  assert.equal(readFileSync(join(mineradio, 'lib', 'client.js'), 'utf8'), legacyRequire)
})

test('can migrate Mineradio even when dshmarket is not installed', () => {
  const root = mkdtempSync(join(tmpdir(), 'dsh-local-theme-only-'))
  const profile = join(root, '.dsh', 'profiles', 'web')
  const runtime = join(root, 'npm', 'node_modules', '@deepseek-ai', 'dsh')
  const mineradio = join(profile, 'node_modules', 'dsh-theme-mineradio')

  writeFixture(join(runtime, 'package.json'), '{"name":"@deepseek-ai/dsh","version":"0.1.2-alpha.4"}')
  writeFixture(join(runtime, '..', 'dsh-client-store', 'package.json'), '{"name":"@deepseek-ai/dsh-client-store"}')
  writeFixture(join(mineradio, 'package.json'), '{\n  "name": "dsh-theme-mineradio",\n  "version": "2.3.5",\n  "dsh": {\n    "inject": [\n        "@deepseek-ai/dsh-client-runtime",\n        "@deepseek-ai/dsh-client-locale",\n        "@deepseek-ai/dsh-client-ui"\n    ]\n  }\n}')
  writeFixture(join(mineradio, 'lib', 'client.js'), 'require("@deepseek-ai/dsh-client-runtime/client")')

  execFileSync(process.execPath, [helper, profile, runtime])
  assert.match(readFileSync(join(mineradio, 'lib', 'client.js'), 'utf8'), /dsh-client-store/)
})
