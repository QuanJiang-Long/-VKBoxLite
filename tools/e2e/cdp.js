'use strict';
// tools/e2e/cdp.js
//
// 极简 Chrome DevTools Protocol 客户端（零依赖, Node >= 22 —— 自带全局 WebSocket）。
//
// 为什么不引 Playwright/WebDriverIO:
//   - 要测的是【用户真正看到的那个 Electron 界面】, 只需要连上
//     --remote-debugging-port, 用 Runtime.evaluate 点按钮/读 DOM 即可;
//   - 现场机器可能没法装 node_modules 之外的浏览器二进制, 少一个依赖少一类失败。
//
// 提供: findPage / connect / makeEval / prepare / launchElectron / killTree / sleep

const http = require('http');
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const sleep = ms => new Promise(r => setTimeout(r, ms));

function httpGetJson(url, timeout = 3000) {
  return new Promise((resolve, reject) => {
    const req = http.get(url, res => {
      const chunks = [];
      res.on('data', c => chunks.push(c));
      res.on('end', () => {
        try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8'))); }
        catch (e) { reject(new Error('返回不是 JSON: ' + url)); }
      });
    });
    req.setTimeout(timeout, () => req.destroy(new Error('HTTP 超时: ' + url)));
    req.on('error', reject);
  });
}

// 等页面出现。Electron 冷启动 + 渲染首帧可能需要几秒, 这里最多等 waitMs。
async function findPage(debugPort, waitMs = 20000) {
  const end = Date.now() + waitMs;
  let lastErr = null;
  while (Date.now() < end) {
    try {
      const list = await httpGetJson('http://127.0.0.1:' + debugPort + '/json/list', 2000);
      const page = (list || []).find(t => t.type === 'page' && /index\.html/.test(t.url || ''));
      if (page && page.webSocketDebuggerUrl) return page;
    } catch (e) {
      lastErr = e;
    }
    await sleep(300);
  }
  throw new Error('找不到 Electron 页面 (端口 ' + debugPort + ')'
    + (lastErr ? ' — ' + lastErr.message : ' — 应用是否用 --remote-debugging-port 启动?'));
}

function connect(wsUrl) {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(wsUrl);
    const pending = new Map();
    const listeners = new Map();
    let seq = 0;
    ws.onopen = () => resolve({
      send(method, params) {
        return new Promise((res, rej) => {
          const id = ++seq;
          pending.set(id, { res, rej });
          ws.send(JSON.stringify({ id, method, params: params || {} }));
        });
      },
      on(method, fn) { listeners.set(method, fn); },
      waitEvent(method, ms = 8000) {
        return new Promise((res, rej) => {
          const t = setTimeout(() => {
            listeners.delete(method);
            rej(new Error('等待事件超时: ' + method));
          }, ms);
          listeners.set(method, m => {
            clearTimeout(t);
            listeners.delete(method);
            res(m.params);
          });
        });
      },
      close: () => ws.close(),
    });
    ws.onerror = () => reject(new Error('WebSocket 连接失败: ' + wsUrl));
    ws.onmessage = ev => {
      const msg = JSON.parse(ev.data);
      if (msg.id && pending.has(msg.id)) {
        const p = pending.get(msg.id);
        pending.delete(msg.id);
        if (msg.error) p.rej(new Error(JSON.stringify(msg.error)));
        else p.res(msg.result);
        return;
      }
      const fn = listeners.get(msg.method);
      if (fn) fn(msg);
    };
  });
}

// 把 Runtime.evaluate 包成 async 函数: 传进来的 expr 里可以直接 await。
function makeEval(client) {
  return async function ev(expr) {
    const r = await client.send('Runtime.evaluate', {
      expression: '(async function(){' + expr + '})()',
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
    });
    if (r.exceptionDetails) {
      const d = r.exceptionDetails;
      const desc = (d.exception && d.exception.description) || '';
      throw new Error('页面异常: ' + (d.text || '') + ' ' + desc.slice(0, 400));
    }
    return r.result && r.result.value;
  };
}

// 打开运行时事件收集 + 下载目录接管。
// 下载很关键: 不接管的话导出会弹【原生保存框】, 自动化会一直卡在那儿。
async function prepare(client, debugPort, opts = {}) {
  const errors = [];
  client.on('Runtime.exceptionThrown', m => {
    const d = m.params.exceptionDetails || {};
    errors.push('EXCEPTION ' + (d.text || '') + ' '
      + (((d.exception && d.exception.description) || '').slice(0, 300)));
  });
  client.on('Runtime.consoleAPICalled', m => {
    if (m.params.type !== 'error' && m.params.type !== 'warning') return;
    const text = (m.params.args || [])
      .map(a => (a.value !== undefined ? String(a.value) : (a.description || ''))).join(' ');
    errors.push(m.params.type.toUpperCase() + ' ' + text.slice(0, 300));
  });
  client.on('Log.entryAdded', m => {
    const e = m.params.entry || {};
    if (e.level !== 'error' && e.level !== 'warning') return;
    errors.push((e.level || '').toUpperCase() + ' ' + String(e.text || '').slice(0, 300));
  });

  await client.send('Runtime.enable');
  await client.send('Log.enable');
  await client.send('Page.enable');
  await client.send('DOM.enable').catch(() => {});

  // 页面级设置下载目录(attach 到已有应用时也生效, 但 will-download 优先级更高)
  if (opts.downloadDir) {
    fs.mkdirSync(opts.downloadDir, { recursive: true });
    await client.send('Browser.setDownloadBehavior', {
      behavior: 'allow', downloadPath: opts.downloadDir, eventsEnabled: true,
    }).catch(() => {});
    // 再拿 browser 级 WS 设一次: page session 上的设置不一定覆盖全局下载
    try {
      const ver = await httpGetJson('http://127.0.0.1:' + debugPort + '/json/version', 2000);
      const bws = new WebSocket(ver.webSocketDebuggerUrl);
      await new Promise((res, rej) => { bws.onopen = res; bws.onerror = rej; });
      bws.send(JSON.stringify({
        id: 1, method: 'Browser.setDownloadBehavior',
        params: { behavior: 'allow', downloadPath: opts.downloadDir, eventsEnabled: true },
      }));
      await sleep(200);
      try { bws.close(); } catch (e) {}
    } catch (e) { /* 浏览器级端点不可用就只靠页面级 */ }
  }
  client.errors = errors;
}

// 启动 Electron 前端(带调试端口), 返回子进程。
// 用 --launch 时脚本自己拉起应用, 好处是能把 VKBOX_DOWNLOAD_DIR /
// VKBOX_SIM_WEBC 这些环境变量一次设对, 省掉"忘了设环境变量"的冤枉路。
function launchElectron(repoRoot, opts = {}) {
  const frontendDir = path.join(repoRoot, 'frontend');
  const exe = opts.electronPath
    || path.join(frontendDir, 'node_modules', 'electron', 'dist',
      process.platform === 'win32' ? 'electron.exe' : 'electron');
  if (!fs.existsSync(exe)) {
    throw new Error('找不到 Electron 可执行文件: ' + exe + '\n先跑一次 npm install (frontend/)');
  }
  const args = ['--remote-debugging-port=' + (opts.debugPort || 9333), '.'];
  const child = spawn(exe, args, {
    cwd: frontendDir,
    env: Object.assign({}, process.env, opts.env || {}),
    stdio: ['ignore', 'ignore', 'ignore'],
    windowsHide: false,
  });
  child.on('error', e => { child.__launchError = e; });
  return child;
}

// Electron 在 Windows 上会再拉 renderer/gpu 子进程, 只 kill 父进程会留一堆僵尸。
function killTree(pid) {
  if (!pid) return;
  try {
    if (process.platform === 'win32') {
      spawnSync('taskkill', ['/PID', String(pid), '/T', '/F'], { stdio: 'ignore' });
    } else {
      process.kill(-pid, 'SIGKILL');
    }
  } catch (e) { /* 已经退了 */ }
}

module.exports = { sleep, httpGetJson, findPage, connect, makeEval, prepare, launchElectron, killTree };
