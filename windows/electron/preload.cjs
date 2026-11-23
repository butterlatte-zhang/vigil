// Preload — the only bridge between the sandboxed renderer and the shell. Exposes the
// native folder picker and the title-bar overlay theme sync.
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('vigil', {
  pickFolder: () => ipcRenderer.invoke('vigil:pickFolder'),
  setTheme: (theme) => ipcRenderer.send('vigil:setTheme', theme),
  // Terminal copy/paste goes through the shell's own clipboard so it never depends on
  // Chromium's clipboard permission prompts.
  readClipboard: () => ipcRenderer.invoke('vigil:readClipboard'),
  writeClipboard: (text) => ipcRenderer.invoke('vigil:writeClipboard', text),
})
