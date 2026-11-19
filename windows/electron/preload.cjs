// Preload — the only bridge between the sandboxed renderer and the shell. Exposes the
// native folder picker and the title-bar overlay theme sync.
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('vigil', {
  pickFolder: () => ipcRenderer.invoke('vigil:pickFolder'),
  setTheme: (theme) => ipcRenderer.send('vigil:setTheme', theme),
})
