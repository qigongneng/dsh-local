import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { join } from 'node:path'

const profileDirectory = process.argv[2]
if (!profileDirectory) process.exit(0)

const runtimeDirectory = process.argv[3]

const marketDirectory = join(profileDirectory, 'node_modules', 'dshmarket')
const manifestFile = join(marketDirectory, 'package.json')

let marketVersion = 'unknown'
if (existsSync(manifestFile)) {
  try {
    marketVersion = JSON.parse(readFileSync(manifestFile, 'utf8')).version ?? marketVersion
  } catch {}
}

// dsh-market <= 1.39 classifies themes only by the catalog display identity
// (`plugin.name`). A catalog entry may publish under a different npm identity
// (`plugin.npm`), such as dsh-bloom-theme -> @kubor/dsh-bloom-theme. Its UI
// correctly matches the installed package, but /use-skin rejects that same
// package as "not an installed theme". Patch only the exact upstream line;
// once upstream ships the equivalent fix this becomes a no-op.
const compatibilityPatches = [
  {
    file: join(marketDirectory, 'lib', 'themes.js'),
    before: 'const themeNames = new Set(themeEntries.map(p => p.name));',
    after: "const themeNames = new Set(themeEntries.flatMap(p => [p.name, typeof p.npm === 'string' ? p.npm : '']).filter(Boolean));",
  },
  {
    file: join(marketDirectory, 'src', 'themes.ts'),
    before: 'const themeNames = new Set(themeEntries.map(p => p.name))',
    after: "const themeNames = new Set(themeEntries.flatMap(p => [p.name, typeof p.npm === 'string' ? p.npm : '']).filter(Boolean))",
  },
  {
    file: join(marketDirectory, 'lib', 'routes.js'),
    before: '                    pendingRollbacks.clear();\n                    const activated = await themes.activateTheme(name);',
    after: '                    pendingRollbacks.clear();\n                    for (const rowId of rowIdsForPackage(host, activeProfileDir, name))\n                        await enableRow(userPatchPath, rowId);\n                    const activated = await themes.activateTheme(name);',
  },
  {
    file: join(marketDirectory, 'src', 'routes.ts'),
    before: '          pendingRollbacks.clear()\n          const activated = await themes.activateTheme(name)',
    after: '          pendingRollbacks.clear()\n          for (const rowId of rowIdsForPackage(host, activeProfileDir, name)) {\n            await enableRow(userPatchPath, rowId)\n          }\n          const activated = await themes.activateTheme(name)',
  },
]

let changed = false
for (const patch of compatibilityPatches) {
  if (!existsSync(patch.file)) continue
  const source = readFileSync(patch.file, 'utf8')
  if (source.includes(patch.after)) continue
  if (!source.includes(patch.before)) {
    process.stderr.write(`DSH Local: dsh-market ${marketVersion} theme compatibility signature changed; leaving ${patch.file} untouched\n`)
    continue
  }
  const temporary = `${patch.file}.dsh-local-${process.pid}.tmp`
  writeFileSync(temporary, source.replace(patch.before, patch.after), { mode: 0o644 })
  renameSync(temporary, patch.file)
  changed = true
}

if (changed) {
  process.stderr.write(`DSH Local: applied npm-identity theme compatibility to dsh-market ${marketVersion}\n`)
}

// Mineradio 2.3.5 was built for Harness 0.1.1-rc.2. In 0.1.2-alpha.4 the
// React-free store engine moved, without a behavioral change to defineStore,
// from @deepseek-ai/dsh-client-runtime/client to the dedicated
// @deepseek-ai/dsh-client-store package. The old runtime row no longer exists
// in the browser module graph, so the otherwise valid theme fails while its
// factory is materialized. Apply the narrow migration only when the running
// Harness actually carries the new store package. Exact signatures keep this
// a no-op as soon as the theme publishes an upstream-compatible bundle.
function runtimeProvidesClientStore() {
  if (!runtimeDirectory) return false

  // Source builds (including DSH Local on macOS) keep the package in the
  // workspace. npm installations (the normal Windows layout) hoist it next
  // to @deepseek-ai/dsh, or occasionally below the runtime package itself.
  // Check exact package locations first, then ask Node's resolver from the
  // runtime package. This is a capability check, not a version comparison.
  const candidates = [
    join(runtimeDirectory, 'packages', 'client', 'store', 'package.json'),
    join(runtimeDirectory, 'node_modules', '@deepseek-ai', 'dsh-client-store', 'package.json'),
    join(runtimeDirectory, '..', 'dsh-client-store', 'package.json'),
  ]
  if (candidates.some(candidate => existsSync(candidate))) return true

  const runtimeManifest = join(runtimeDirectory, 'package.json')
  if (!existsSync(runtimeManifest)) return false
  try {
    const requireFromRuntime = createRequire(runtimeManifest)
    requireFromRuntime.resolve('@deepseek-ai/dsh-client-store')
    return true
  } catch {
    return false
  }
}

const mineradioDirectory = join(profileDirectory, 'node_modules', 'dsh-theme-mineradio')
const mineradioManifest = join(mineradioDirectory, 'package.json')
const mineradioClient = join(mineradioDirectory, 'lib', 'client.js')

if (runtimeProvidesClientStore() && existsSync(mineradioManifest) && existsSync(mineradioClient)) {
  let themeVersion = 'unknown'
  try {
    themeVersion = JSON.parse(readFileSync(mineradioManifest, 'utf8')).version ?? themeVersion
  } catch {}

  const themePatches = [
    {
      file: mineradioClient,
      before: 'require("@deepseek-ai/dsh-client-runtime/client")',
      after: 'require("@deepseek-ai/dsh-client-store")',
    },
    {
      file: mineradioManifest,
      before: '        "@deepseek-ai/dsh-client-runtime",\n        "@deepseek-ai/dsh-client-locale",',
      after: '        "@deepseek-ai/dsh-client-store",\n        "@deepseek-ai/dsh-client-locale",',
    },
  ]

  let themeChanged = false
  for (const patch of themePatches) {
    const source = readFileSync(patch.file, 'utf8')
    if (source.includes(patch.after)) continue
    if (!source.includes(patch.before)) {
      process.stderr.write(`DSH Local: Mineradio ${themeVersion} compatibility signature changed; leaving ${patch.file} untouched\n`)
      continue
    }
    const occurrences = source.split(patch.before).length - 1
    if (occurrences !== 1) {
      process.stderr.write(`DSH Local: Mineradio ${themeVersion} compatibility expected one signature in ${patch.file}, found ${occurrences}; leaving it untouched\n`)
      continue
    }
    const temporary = `${patch.file}.dsh-local-${process.pid}.tmp`
    writeFileSync(temporary, source.replace(patch.before, patch.after), { mode: 0o644 })
    renameSync(temporary, patch.file)
    themeChanged = true
  }

  if (themeChanged) {
    process.stderr.write(`DSH Local: migrated Mineradio ${themeVersion} store dependency for the current Harness runtime\n`)
  }
}
