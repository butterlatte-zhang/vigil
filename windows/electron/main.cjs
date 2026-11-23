// Vigil for Windows — Electron thin shell.
//
// The shell owns nothing but the window: the orchestration core is a plain Node process
// (dist/main/index.js) that serves the renderer over HTTP + WebSocket. Keeping the core
// outside the Electron process means node-pty never has to be rebuilt against Electron's
// ABI and the same build can also be opened in a normal browser for debugging.

const { app, BrowserWindow, dialog, ipcMain, shell, clipboard } = require('electron')
const { spawn } = require('node:child_process')
const path = require('node:path')

let core = null
let win = null
/** @type {string | null} */
let coreUrl = null

const isDev = process.argv.includes('--dev')

function startCore() {
  return new Promise((resolve, reject) => {
    // Electron exposes a full Node runtime via ELECTRON_RUN_AS_NODE; prefer a real
    // `node` on PATH when present so shims and the core share one obvious runtime.
    const env = { ...process.env, VIGIL_LAUNCHED_BY: 'electron' }
    const args = [path.join(__dirname, '..', 'dist', 'main', 'index.js')]
    let child
    if (process.env.VIGIL_NODE_BIN) {
      child = spawn(process.env.VIGIL_NODE_BIN, args, { env, stdio: ['ignore', 'pipe', 'pipe'] })
    } else {
      child = spawn(process.execPath, args, {
        env: { ...env, ELECTRON_RUN_AS_NODE: '1' },
        stdio: ['ignore', 'pipe', 'pipe'],
      })
    }
    core = child

    let buf = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk) => {
      process.stdout.write(chunk)
      buf += chunk
      let idx
      while ((idx = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, idx).trim()
        buf = buf.slice(idx + 1)
        if (line.startsWith('VIGIL_READY ')) {
          try {
            const info = JSON.parse(line.slice('VIGIL_READY '.length))
            // The URL carries the per-process WebSocket token — loading the bare origin
            // would make the WS upgrade 401 and leave the UI stuck (silently unclickable).
            resolve(info.url ?? `http://127.0.0.1:${info.port}/`)
          } catch (e) {
            reject(e)
          }
        }
      }
    })
    child.stderr.on('data', (d) => process.stderr.write(d))
    child.on('exit', (code) => {
      core = null
      if (!app.isQuitting) app.quit()
      if (!coreUrl && code !== 0) reject(new Error(`core exited with ${code}`))
    })
    setTimeout(() => reject(new Error('core did not report ready in 20s')), 20000)
  })
}

async function createWindow() {
  coreUrl = await startCore()
  win = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 980,
    minHeight: 640,
    title: 'Vigil',
    backgroundColor: '#161719',
    show: false,
    // Self-drawn 50pt top bar (matching the macOS app); native Windows caption buttons
    // are drawn by the overlay at the right edge, and the title bar colour follows the
    // resolved Vigil theme via the preload bridge.
    titleBarStyle: 'hidden',
    ...(process.platform === 'win32'
      ? { titleBarOverlay: { color: '#202126', symbolColor: 'rgba(255,255,255,0.93)', height: 50 } }
      : {}),
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  })
  win.once('ready-to-show', () => win.show())
  ipcMain.handle('vigil:pickFolder', async () => {
    const result = await dialog.showOpenDialog(win, {
      properties: ['openDirectory', 'createDirectory'],
      title: 'Add project',
    })
    return result.canceled ? null : result.filePaths[0] ?? null
  })
  ipcMain.handle('vigil:readClipboard', () => clipboard.readText())
  ipcMain.handle('vigil:writeClipboard', (_event, text) => {
    clipboard.writeText(typeof text === 'string' ? text : '')
  })
  ipcMain.on('vigil:setTheme', (_event, theme) => {
    if (!win || process.platform !== 'win32') return
    const dark = theme !== 'light'
    try {
      win.setTitleBarOverlay({
        color: dark ? '#202126' : '#F4F4F6',
        symbolColor: dark ? 'rgba(255,255,255,0.93)' : 'rgba(0,0,0,0.88)',
        height: 50,
      })
    } catch {
      // older Electron: overlay chrome simply keeps its launch colour
    }
  })
  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url)
    return { action: 'deny' }
  })
  await win.loadURL(coreUrl)
  if (isDev) win.webContents.openDevTools({ mode: 'detach' })
}

app.on('before-quit', () => {
  app.isQuitting = true
  if (core) core.kill()
})

app.whenReady().then(createWindow).catch((err) => {
  console.error(err)
  app.quit()
})

app.on('window-all-closed', () => app.quit())
app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})
