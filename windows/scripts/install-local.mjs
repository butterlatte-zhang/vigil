#!/usr/bin/env node
// Install the freshly packaged build over %LOCALAPPDATA%\Programs\Vigil.
//
// `npm run install:local` runs `package:win` first, so release/Vigil-win32-x64 is current.
// This script stops the running installed app (the dev shell is electron.exe, not
// Vigil.exe, so it is left alone), swaps the directory in as a transaction — the old copy
// is only a backup until the new files are all in place — and relaunches it.
//
// User data lives outside the install directory (~/.config/vigil and %APPDATA%\Vigil) and
// is never touched.

import fs from 'node:fs'
import path from 'node:path'
import { execFileSync, spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const EXE = 'Vigil.exe'
const winRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const src = path.join(winRoot, 'release', 'Vigil-win32-x64')
const programs = path.join(process.env.LOCALAPPDATA ?? '', 'Programs')
const dst = path.join(programs, 'Vigil')
const bak = path.join(programs, 'Vigil.bak-install')

if (process.platform !== 'win32') {
  console.error('install:local only supports Windows')
  process.exit(1)
}
if (!process.env.LOCALAPPDATA) {
  console.error('LOCALAPPDATA is not set')
  process.exit(1)
}
if (!fs.existsSync(path.join(src, EXE))) {
  console.error(`no build at ${src} — run \`npm run package:win\` first`)
  process.exit(1)
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

async function retry(what, fn, attempts = 10, delay = 500) {
  let last
  for (let i = 0; i < attempts; i++) {
    try {
      return fn()
    } catch (err) {
      last = err
      await sleep(delay)
    }
  }
  throw new Error(`${what} failed: ${last?.message ?? last}`)
}

// 1. Stop the installed app so its files unlock. taskkill exits non-zero when no
//    matching process exists, which is fine.
try {
  execFileSync('taskkill', ['/IM', EXE, '/F', '/T'], { stdio: 'ignore' })
  console.log(`stopped running ${EXE}`)
} catch {
  console.log(`${EXE} was not running`)
}
await sleep(1000)

// 2. Move the current install aside, copy the new build in, and only then drop the
//    backup. If anything fails, put the old install back.
const hadOld = fs.existsSync(dst)
if (hadOld) {
  if (fs.existsSync(bak)) await retry('removing stale backup', () => fs.rmSync(bak, { recursive: true, force: true }))
  await retry('moving the old install aside', () => fs.renameSync(dst, bak))
  console.log(`old install moved to ${bak}`)
}

try {
  await retry('copying the new build', () => fs.cpSync(src, dst, { recursive: true, dereference: true }), 3, 1000)
} catch (err) {
  if (hadOld) {
    fs.rmSync(dst, { recursive: true, force: true })
    fs.renameSync(bak, dst)
    console.log('copy failed — the previous install was restored')
  }
  throw err
}

if (hadOld) {
  await retry('removing the backup', () => fs.rmSync(bak, { recursive: true, force: true }))
  console.log('backup removed')
}

// 3. Relaunch detached so this script can exit.
const exe = path.join(dst, EXE)
spawn(exe, [], { detached: true, stdio: 'ignore' }).unref()
console.log(`launched ${exe}`)
