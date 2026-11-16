//=====================================================================
// main.js - Electron 主进程
// 职责：串口枚举/打开/关闭/收发，通过 IPC 暴露给渲染进程
// 渲染进程不直接接触 Node/串口，全部走 preload 暴露的 window.serial
//=====================================================================
const { app, BrowserWindow, ipcMain, session } = require('electron');
const path = require('path');
// 流式 UTF-8 解码器 (2026-10 修乱码): 串口来的字节要【按流】解码, 不能一块一块
// 单独 toString('utf8') —— 一个汉字的 3 个字节经常跨 chunk 边界, 分开解码会
// 把一个字变成 2~3 个替换符(乱码)。StringDecoder 会把不完整的尾巴缓存住,
// 下一块来时补齐。现象: 设备回的中文错误串(平台拒绝连接…)偶发坏一个字
const { StringDecoder } = require('string_decoder');

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
let utf8Decoder = new StringDecoder('utf8');  // 跨 chunk 的多字节字符靠它续上
const LINE_END = ['\r\n', '\n'];

//---------------------------------------------------------------------
// 模拟器联调通道 (LuatOS PC 模拟器 --webc Web Console)
//---------------------------------------------------------------------
// 官方 V2039 PC 模拟器是裁剪版：不读 pcconf.json → UART-UDP 用不了，
// 唯一对外的字节通道是 `--webc=<port>` 起的 Web Console：
//   POST /api/uart31/inject {direction:"rx", encoding:"utf8", payload}  // 灌进设备 RX
//   GET  /api/uart31/console → items[] (direction: rx|tx, payload_hex: "\xNN.." 转义文本)
// 这里把它包成伪串口 "sim://127.0.0.1:<port>/uart31"：枚举里多一项，
// 打开/关闭/收发与真串口走同一套 IPC，渲染层无需任何改动。
// 注意：模拟器侧 uart31 需由固件占用（仓库里 sw 默认命令口是 VUART_0=32，
// 32 在模拟器里被 GNSS mock 占用，联调前需在临时目录把 prov/cmd 的 UART_ID 改成 31）。
const http = require('http');
const SIM_PORT = Number(process.env.VKBOX_SIM_WEBC || 18921);
const SIM_POLL_MS = 40;
let sim = null;           // 模拟器会话 { timer, cursor, lastTs, chain }

function simReq(method, urlPath, body) {
  return new Promise((resolve, reject) => {
    const payload = body ? Buffer.from(JSON.stringify(body), 'utf8') : null;
    const req = http.request({
      host: '127.0.0.1', port: SIM_PORT, path: urlPath, method,
      headers: payload ? { 'Content-Type': 'application/json', 'Content-Length': payload.length } : {},
      timeout: 1500
    }, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        const txt = Buffer.concat(chunks).toString('utf8');
        if (res.statusCode !== 200) return reject(new Error('HTTP ' + res.statusCode + ' ' + txt.slice(0, 160)));
        try { resolve(JSON.parse(txt)); } catch (e) { reject(new Error('bad json: ' + txt.slice(0, 120))); }
      });
    });
    req.on('timeout', () => req.destroy(new Error('timeout')));
    req.on('error', reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// payload_hex 是 "\x52\x45..." 这样的转义文本，不是原始字节
function simHexToBuffer(hex) {
  if (!hex) return Buffer.alloc(0);
  const out = [];
  const re = /\\x([0-9A-Fa-f]{2})/g;
  let m;
  while ((m = re.exec(hex)) !== null) out.push(parseInt(m[1], 16));
  return Buffer.from(out);
}

async function simProbe() {
  try { const r = await simReq('GET', '/api/health'); return !!(r && r.ok); } catch (e) { return false; }
}

function simStop() {
  if (sim && sim.timer) clearTimeout(sim.timer);
  sim = null;
}

async function simStart() {
  simStop();
  // 注意：Web Console 的 history 是【64 条环形缓冲】，满了以后 items.length
  // 恒定为 64、头部旧项被挤掉 —— 所以不能用数组长度当游标（会导致永远读不到新项）。
  // 这里改用「ts_ms + 同毫秒内已消费计数」推进：ts 单调不减，同 ts 的多片按序补发。
  sim = { timer: null, lastTs: 0, lastTsCount: 0, chain: Promise.resolve() };
  // 打开时先把游标对齐到当前队尾（必须 await：否则首条指令的回包可能被当历史吞掉）
  try {
    const r = await simReq('GET', '/api/uart31/console');
    const items = (r && Array.isArray(r.items)) ? r.items : [];
    if (items.length) {
      const tail = items[items.length - 1] || {};
      sim.lastTs = Number(tail.ts_ms) || 0;
      sim.lastTsCount = items.filter(it => (Number(it.ts_ms) || 0) === sim.lastTs).length;
    }
  } catch (e) { /* 探测失败时从 0 开始，最多重放当前历史 */ }
  const tick = async () => {
    if (!sim) return;
    try {
      const r = await simReq('GET', '/api/uart31/console');
      if (!sim) return;
      sim.fail = 0;
      const items = Array.isArray(r.items) ? r.items : [];
      let seenSame = 0;
      for (let i = 0; i < items.length; i++) {
        const it = items[i] || {};
        const ts = Number(it.ts_ms) || 0;
        if (ts < sim.lastTs) continue;            // 已被挤掉的旧项 / 已消费
        if (ts === sim.lastTs) {
          seenSame++;
          if (seenSame <= sim.lastTsCount) continue;  // 同毫秒内已消费过的分片
          sim.lastTsCount = seenSame;
        } else {
          sim.lastTs = ts;
          sim.lastTsCount = 1;
          seenSame = 1;
        }
        if (it.direction !== 'tx') continue;      // rx 是自己注入的，不回灌
        const buf = simHexToBuffer(it.payload_hex);
        if (buf.length) onData(buf);
      }
    } catch (e) {
      // 模拟器被杀/重启：连续约 1.6s 不可达就当作"串口拔出"，让 UI 回到未连接状态，
      // 否则界面会一直显示已连接、发指令却石沉大海。
      if (sim) {
        sim.fail = (sim.fail || 0) + 1;
        if (sim.fail >= 40) {
          simStop();
          send('serial:closed', null);
          return;
        }
      }
    }
    if (sim) sim.timer = setTimeout(tick, SIM_POLL_MS);
  };
  tick();
}

function simSend(line) {
  if (!sim) return Promise.resolve({ ok: false, error: '模拟器通道未打开' });
  const payload = line.endsWith('\r\n') ? line : line + '\r\n';
  // 单次注入长度保守分片（500 字符/片，按码点切，避免切坏中文）；
  // 固件 prov 侧本来就会把分片拼回整行（rx_parts）。
  const chars = Array.from(payload);
  const parts = [];
  for (let i = 0; i < chars.length; i += 500) parts.push(chars.slice(i, i + 500).join(''));
  sim.chain = sim.chain.then(async () => {
    for (const p of parts) {
      await simReq('POST', '/api/uart31/inject', { direction: 'rx', encoding: 'utf8', payload: p });
    }
  }).catch(() => {});
  return sim.chain.then(() => ({ ok: true }), e => ({ ok: false, error: String(e && e.message || e) }));
}

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
  // F12 切换 DevTools (Electron 默认没绑, 这里加上)
  // webContents.devToolsOpened 跟踪当前状态, 按 F12 时切换
  let devToolsOpen = false;
  win.webContents.on('devtools-opened', () => { devToolsOpen = true; });
  win.webContents.on('devtools-closed', () => { devToolsOpen = false; });
  win.webContents.on('before-input-event', (event, input) => {
    if (input.key === 'F12' && input.type === 'keyDown') {
      if (devToolsOpen) win.webContents.closeDevTools();
      else win.webContents.openDevTools();
    }
  });
}

//---------------------------------------------------------------------
// 串口相关 IPC
//---------------------------------------------------------------------
ipcMain.handle('serial:list', async () => {
  let ports = [];
  let err = null;
  if (SerialPortList) {
    try { ports = await SerialPortList(); } catch (e) { err = e; }
  } else {
    err = new Error('serialport 未安装或版本不兼容');
  }
  // 模拟器在跑就多挂一个伪串口（真实串口枚举失败也照样能联调）
  const list = ports.map(p => ({
    path: p.path,
    manufacturer: p.manufacturer || '',
    // Air780EP 的 USB 虚拟串口通常是 "USB 串行设备"
    label: p.path + (p.manufacturer ? '  (' + p.manufacturer + ')' : '')
  }));
  if (await simProbe()) {
    list.push({
      path: 'sim://127.0.0.1:' + SIM_PORT + '/uart31',
      manufacturer: 'LuatOS PC',
      label: '模拟器 UART31 (127.0.0.1:' + SIM_PORT + ')'
    });
  }
  if (!list.length && err) return { ok: false, error: String(err && err.message || err) };
  return { ok: true, ports: list };
});

ipcMain.handle('serial:open', async (evt, opts) => {
  const { path: p, baud } = opts || {};
  if (!p) return { ok: false, error: '未指定串口' };
  // 模拟器伪串口：走 Web Console 通道，不碰 serialport
  if (p.startsWith('sim://')) {
    if (port && port.isOpen) { try { port.close(); } catch (e) {} }
    port = null;
    rxBuffer = '';
    utf8Decoder = new StringDecoder('utf8');
    if (!(await simProbe())) return { ok: false, error: '模拟器 Web Console 不可达（--webc=' + SIM_PORT + '）' };
    await simStart();
    return { ok: true };
  }
  if (!SerialPort) return { ok: false, error: 'serialport 未安装' };
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
    utf8Decoder = new StringDecoder('utf8');
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
  simStop();
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
  return !!(sim || (port && port.isOpen));
});

ipcMain.handle('serial:send', async (evt, line) => {
  if (sim) return simSend(String(line == null ? '' : line));
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
  // ⚠️ 必须用流式解码: chunk.toString('utf8') 会把跨块的中文字切坏(乱码)
  rxBuffer += utf8Decoder.write(chunk);
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

// 自动化/联调: 设置 VKBOX_DOWNLOAD_DIR 后，「导出配置」直接落盘、
// 不弹系统保存对话框（无人值守跑 E2E 时对话框会卡住整个流程）。
// 不设这个环境变量时行为完全不变（仍由用户选目录）。
if (process.env.VKBOX_DOWNLOAD_DIR) {
  app.whenReady().then(() => {
    const fs = require('fs');
    const dir = process.env.VKBOX_DOWNLOAD_DIR;
    try { fs.mkdirSync(dir, { recursive: true }); } catch (e) {}
    session.defaultSession.on('will-download', (evt, item) => {
      try { item.setSavePath(path.join(dir, item.getFilename())); } catch (e) {}
    });
  });
}

app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
app.on('activate', () => { if (BrowserWindow.getAllWindows().length === 0) createWindow(); });
