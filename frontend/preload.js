//=====================================================================
// preload.js - 桥接层：只暴露最小必要的串口 API 给渲染进程
//=====================================================================
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('serial', {
  list: () => ipcRenderer.invoke('serial:list'),
  open: (opts) => ipcRenderer.invoke('serial:open', opts),
  close: () => ipcRenderer.invoke('serial:close'),
  isOpen: () => ipcRenderer.invoke('serial:isOpen'),
  send: (line) => ipcRenderer.invoke('serial:send', line),
  onLine: (cb) => {
    const h = (evt, line) => cb(line);
    ipcRenderer.on('serial:line', h);
    return () => ipcRenderer.removeListener('serial:line', h);
  },
  onError: (cb) => {
    const h = (evt, msg) => cb(msg);
    ipcRenderer.on('serial:error', h);
    return () => ipcRenderer.removeListener('serial:error', h);
  },
  onClosed: (cb) => {
    const h = () => cb();
    ipcRenderer.on('serial:closed', h);
    return () => ipcRenderer.removeListener('serial:closed', h);
  }
});
