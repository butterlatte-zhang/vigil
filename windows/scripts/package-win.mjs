#!/usr/bin/env node
// Vigil for Windows — self-contained packaging (no installer framework).
//
// Produces release/Vigil-win32-x64/Vigil.exe with the Electron runtime, the core
// (dist/main), the renderer (dist/renderer), the shims (bin) and only the runtime
// node_modules the core actually loads (node-pty, @xterm/headless, ws). No asar: the
// PTY native module and the shims must be real files on disk.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const release = path.join(root, 'release')
const out = path.join(release, 'Vigil-win32-x64')
const electronDist = path.join(root, 'node_modules', 'electron', 'dist')
const appDir = path.join(out, 'resources', 'app')

function copy(src, dst, filter) {
  fs.cpSync(src, dst, {
    recursive: true,
    dereference: true,
    filter: filter ? (s, d) => filter(s) : undefined,
  })
}

function copyPackage(name, include) {
  const src = path.join(root, 'node_modules', name)
  const dst = path.join(appDir, 'node_modules', name)
  for (const entry of include) {
    const from = path.join(src, entry)
    if (!fs.existsSync(from)) continue
    copy(from, path.join(dst, entry), (p) => !p.endsWith('.pdb'))
  }
}

if (!fs.existsSync(path.join(root, 'dist', 'main', 'index.js'))) {
  console.error('dist/main is missing — run `npm run build` first.')
  process.exit(1)
}
if (!fs.existsSync(electronDist)) {
  console.error('electron/dist is missing — run `npm install` first.')
  process.exit(1)
}

fs.rmSync(out, { recursive: true, force: true })
fs.mkdirSync(appDir, { recursive: true })

// Electron runtime.
copy(electronDist, out)
const electronExe = path.join(out, 'electron.exe')
const appExe = path.join(out, 'Vigil.exe')
if (fs.existsSync(electronExe)) fs.renameSync(electronExe, appExe)

// Our app.
copy(path.join(root, 'dist'), path.join(appDir, 'dist'))
copy(path.join(root, 'bin'), path.join(appDir, 'bin'))
copy(path.join(root, 'electron'), path.join(appDir, 'electron'))
fs.mkdirSync(path.join(appDir, 'assets'), { recursive: true })
if (fs.existsSync(path.join(root, 'assets', 'icon.ico'))) {
  fs.copyFileSync(path.join(root, 'assets', 'icon.ico'), path.join(appDir, 'assets', 'icon.ico'))
}
fs.writeFileSync(
  path.join(appDir, 'package.json'),
  JSON.stringify(
    {
      name: 'vigil',
      productName: 'Vigil',
      version: JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')).version,
      private: true,
      type: 'module',
      main: 'electron/main.cjs',
    },
    null,
    2,
  ) + '\n',
)

// Runtime dependencies actually required by the core (the renderer is bundled).
copyPackage('node-pty', ['package.json', 'lib', 'build/Release', 'prebuilds/win32-x64', 'typings'])
copyPackage('@xterm/headless', ['package.json', 'lib-headless', 'typings'])
copyPackage('ws', ['package.json', 'index.js', 'wrapper.mjs', 'lib'])

console.log(`Packaged: ${appExe}`)
