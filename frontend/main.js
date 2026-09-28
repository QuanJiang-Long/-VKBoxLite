//=====================================================================
// main.js - Electron 主进程
// 职责：串口枚举/打开/关闭/收发，通过 IPC 暴露给渲染进程
// 渲染进程不直接接触 Node/串口，全部走 preload 暴露的 window.serial
//=====================================================================
const { app, BrowserWindow, ipcMain } = require('electron');
const path = require('path');

// serialport 在打包环境里随 app 一起分发；开发时从 node_modules 加载
// 注意：serialport v10+ 起，list() 是 SerialPort 类的静态方法，
//       v9 及更早才是模块级函数。这里两种都兼容，避免升级版本时又挂。
let SerialPort = null;      // 类（用于 new 打开串口）
let SerialPortList = null;  // list 函数（用于枚举）
try {
  const sp = require('serialport');
  if (typeof sp === 'function') {
    // v9 及更早：模块本身即类，list 是静态方法
    SerialPort = sp;
    SerialPortList = typeof sp.list === 'function' ? sp.list.bind(sp) : null;
  } else if (sp && typeof sp.SerialPort === 'function') {
    // v10+：sp.SerialPort 是类，sp.SerialPort.list 是静态方法
    SerialPort = sp.SerialPort;
    SerialPortList = typeof sp.SerialPort.list === 'function'
      ? sp.SerialPort.list.bind(sp.SerialPort) : null;
  }
  if (!SerialPortList) {
    console.error('[main] serialport 已加载但找不到 list()，版本 API 不兼容');
  }
} catch (e) {
  console.error('[main] serialport 加载失败，请在 frontend 目录执行 npm install:', e.message);
}

let win = null;
let port = null;          // 当前打开的串口实例
let rxBuffer = '';        // 行缓冲（设备协议是一行一条指令）
const LINE_END = ['\r\n', '\n'];

function createWindow() {
  win = new BrowserWindow({
    width: 1180,
    height: 760,
    minWidth: 980,
    minHeight: 640,
    autoHideMenuBar: true,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  // 需要调试时打开：
  // win.webContents.openDevTools();
}

//---------------------------------------------------------------------
// 串口相关 IPC
//---------------------------------------------------------------------
ipcMain.handle('serial:list', async () => {
  if (!SerialPortList) return { ok: false, error: 'serialport 未安装或版本不兼容' };
  try {
    const ports = await SerialPortList();
    return {
      ok: true,
      ports: ports.map(p => ({
        path: p.path,
        manufacturer: p.manufacturer || '',
        // Air780EP 的 USB 虚拟串口通常是 "USB 串行设备"
        label: p.path + (p.manufacturer ? '  (' + p.manufacturer + ')' : '')
      }))
    };
  } catch (e) {
    return { ok: false, error: String(e && e.message || e) };
  }
});

ipcMain.handle('serial:open', async (evt, opts) => {
  if (!SerialPort) return { ok: false, error: 'serialport 未安装' };
  const { path: p, baud } = opts || {};
  if (!p) return { ok: false, error: '未指定串口' };
  try {
    if (port && port.isOpen) { try { port.close(); } catch (e) {} }
    port = new SerialPort({
      path: p,
      baudRate: Number(baud) || 115200,
      dataBits: 8,
      stopBits: 1,
      parity: 'none',
      autoOpen: false
    });
    await new Promise((resolve, reject) => {
      port.open(err => err ? reject(err) : resolve());
    });
    rxBuffer = '';
    port.on('data', chunk => onData(chunk));
    port.on('error', err => send('serial:error', String(err && err.message || err)));
    port.on('close', () => send('serial:closed', null));
    return { ok: true };
  } catch (e) {
    port = null;
    return { ok: false, error: String(e && e.message || e) };
  }
});

ipcMain.handle('serial:close', async () => {
  try {
    if (port && port.isOpen) {
      await new Promise((resolve, reject) => {
        port.close(err => err ? reject(err) : resolve());
      });
    }
  } catch (e) { /* 忽略关闭异常 */ }
  port = null;
  rxBuffer = '';
  return { ok: true };
});

ipcMain.handle('serial:isOpen', async () => {
  return !!(port && port.isOpen);
});

ipcMain.handle('serial:send', async (evt, line) => {
  if (!port || !port.isOpen) return { ok: false, error: '串口未打开' };
  try {
    const payload = line.endsWith('\r\n') ? line : line + '\r\n';
    await new Promise((resolve, reject) => {
      port.write(Buffer.from(payload, 'utf8'), err => err ? reject(err) : resolve());
    });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: String(e && e.message || e) };
  }
});

//---------------------------------------------------------------------
// 接收：按行切分，推送给渲染进程
//---------------------------------------------------------------------
function onData(chunk) {
  rxBuffer += chunk.toString('utf8');
  let idx;
  // 注意：indexOfLineEnd 返回 {start,end} 对象或 null，不能直接和 -1 比较
  while ((idx = indexOfLineEnd(rxBuffer)) !== null) {
    const line = rxBuffer.slice(0, idx.start).replace(/[\r\n]+/g, '');
    rxBuffer = rxBuffer.slice(idx.end);
    if (line.length > 0) send('serial:line', line);
  }
  if (rxBuffer.length > 4096) rxBuffer = ''; // 防御：异常数据清空
}

function indexOfLineEnd(s) {
  let best = -1, end = -1;
  for (const le of LINE_END) {
    const i = s.indexOf(le);
    if (i >= 0 && (best < 0 || i < best)) { best = i; end = i + le.length; }
  }
  return best >= 0 ? { start: best, end } : null;
}

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
