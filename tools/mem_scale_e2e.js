#!/usr/bin/env node
'use strict';
// tools/mem_scale_e2e.js
//
// 真机内存规模测试：往设备里依次导入 N 个寄存器的配置（N = 1/8/16/32/60...），
// 每存一次读两个数：
//   R:CTRACE  这次 W:CFG 的分阶段峰值（enter/gc/decoded/norm/freed/saved/done）
//   R:MEM     当前 Lua 池 used/total + 最大连续块 max
//
// 为什么要单独一条脚本：
//   - 现场最怕的是"水位看着正常，但 W:CFG 峰值已经贴到池顶"（固件注释里
//     95.8% 就 OOM）；这个数只有真机能测，模拟器的 Lua 池是 4MB。
//   - 从站接不接都不影响：W:CFG 只走命令口，不需要 485 应答。
//
// 用法:
//   node tools/mem_scale_e2e.js --port COM4 --launch
//   node tools/mem_scale_e2e.js --port COM4 --sizes 1,8,16,32,60,96,128
//
// 收尾:
//   默认测完切空闲（会清掉配置）；如果设备原本有配置，脚本先导出、结束再导回。
//   --keep-config 则保持最后一个规模不动（调试用）。

const fs = require('fs');
const os = require('os');
const path = require('path');
const { findPage, connect, makeEval, prepare, launchElectron, killTree, sleep } = require('./e2e/cdp');

function arg(name, def) {
  const i = process.argv.indexOf('--' + name);
  if (i < 0) return def;
  const v = process.argv[i + 1];
  return (v && !v.startsWith('--')) ? v : true;
}
const has = n => process.argv.includes('--' + n);

const PORT = arg('port', '');
const SIZES = String(arg('sizes', '1,8,16,32,60')).split(',').map(s => Number(s.trim())).filter(n => n > 0);
const DEBUG_PORT = Number(arg('debug-port', 9333));

if (!PORT) {
  console.error('用法: node tools/mem_scale_e2e.js --port COM4 --launch [--sizes 1,8,16,32,60]');
  process.exit(2);
}

const sleepMs = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(fn, ms, interval = 300) {
  const end = Date.now() + ms;
  let last = null;
  while (Date.now() < end) {
    last = await fn();
    if (last) return last;
    await sleepMs(interval);
  }
  return last;
}

function buildCfg(n) {
  const regs = [];
  for (let i = 0; i < n; i++) {
    regs.push({ addr: i + 1, count: 1, name: 'R' + (i + 1), alias: '规模测试点' + (i + 1), dtype: 'uint16' });
  }
  return {
    tool: 'VKBox配置工具',
    version: '1.0.2',
    exported: new Date().toISOString(),
    mode: 'manual',
    serial: { baud: 9600, databits: 8, parity: 0, stopbits: 1, slave: 1, interval_ms: 5000, timeout_ms: null, server: 'dz.voltkun.com' },
    registers: regs,
    mqtt: { host: '', port: 1883, ssl: false, user: '', pass: '', client_id: '', pub_topic: '', sub_topic: '', interval_s: 120, keep_session: false, auto: { pass: '' }, manual_on: false },
  };
}

(async () => {
  const repoRoot = path.resolve(__dirname, '..');
  const workDir = path.join(os.tmpdir(), 'vkbox_mem_scale');
  fs.mkdirSync(workDir, { recursive: true });

  let child = null, client = null, exitCode = 0;
  const cleanup = () => { try { if (client) client.close(); } catch (e) {} if (child && !has('keep')) killTree(child.pid); };
  process.on('SIGINT', () => { cleanup(); process.exit(130); });

  try {
    if (has('launch')) {
      child = launchElectron(repoRoot, { debugPort: DEBUG_PORT, env: { VKBOX_DOWNLOAD_DIR: workDir } });
      await sleepMs(600);
    }
    const page = await findPage(DEBUG_PORT, 25000);
    client = await connect(page.webSocketDebuggerUrl);
    const ev = makeEval(client);
    await prepare(client, DEBUG_PORT, { downloadDir: workDir });

    const click = sel => ev('const e=document.querySelector(' + JSON.stringify(sel) + '); if(!e) return false; e.click(); return true;');
    const ui = () => ev(`
      const g = id => { const e = document.getElementById(id); return e ? (e.textContent || '') : ''; };
      return { mode: (typeof S !== 'undefined') ? S.mode : null, open: (typeof S !== 'undefined') ? !!S.open : null,
        stMsg: g('stMsg'), toast: g('toast'), stPort: g('stPort') };`);

    const autoConfirm = async (waitMs = 8000) => {
      const deadline = Date.now() + waitMs;
      let clicks = 0, lastSeen = 0;
      while (Date.now() < deadline) {
        const shown = await ev(`
          const m = document.getElementById('modalConfirm');
          if (!m) return false;
          const cs = getComputedStyle(m);
          return cs.display !== 'none' && cs.visibility !== 'hidden' && cs.opacity !== '0';`);
        if (shown) { await ev("document.getElementById('cfYes').click(); return 1"); clicks++; lastSeen = Date.now(); await sleepMs(350); }
        else { if (clicks && Date.now() - lastSeen > 1200) break; await sleepMs(150); }
      }
      return clicks;
    };

    const cmd = (line, expect, timeout) => ev(`
      for (let i = 0; i < 60 && (typeof S !== 'undefined') && S.pending; i++) await new Promise(r => setTimeout(r, 100));
      try {
        const r = await sendCmd(${JSON.stringify(line)}, ${JSON.stringify(expect)}, ${timeout || 8000});
        return { ok: true, raw: String(r.raw || ''), data: r.data };
      } catch (e) { return { ok: false, err: String((e && e.message) || e) }; }`);

    // ---- 打开串口 + 进 manual ----
    await sleepMs(800);
    const opened = await ev(`
      const s = document.getElementById('comSel');
      const btn = document.getElementById('btnOpen');
      if (!s || !btn) return false;
      const want = ${JSON.stringify(PORT)}.toUpperCase();
      const o = Array.from(s.options).find(x => String(x.value).toUpperCase() === want
        || String(x.textContent || '').toUpperCase().indexOf(want) >= 0);
      if (!o) return false;
      s.value = o.value; s.dispatchEvent(new Event('change')); btn.click(); return true;`);
    if (!opened) throw new Error('串口列表里没有 ' + PORT);
    await waitFor(async () => ((await ui()).open ? true : null), 12000);
    if (!(await ui()).open) throw new Error('打不开 ' + PORT + ': ' + (await ui()).stMsg);

    if ((await ui()).mode !== 'manual') {
      await ev("document.querySelector('.tab-item[data-tab=\"tabMode\"]').click(); return 1");
      await sleepMs(400);
      await click('#mcPoll');
      await autoConfirm(10000);
      await waitFor(async () => ((await ui()).mode === 'manual' ? true : null), 15000);
      if ((await ui()).mode !== 'manual') throw new Error('切不到 manual: ' + (await ui()).stMsg);
    }

    // 导入按钮在顶部工具栏，但用户实际是在「手动配置」页操作；
    // 脚本也走这条路径（顺带验证 renderRegTable(pre, true) 的强刷修复）。
    await ev("const t = document.querySelector('.tab-item[data-tab=\"tabManual\"]'); if (t) t.click(); return 1");
    await sleepMs(600);

    // ---- 记录原始配置（有就导出来，结束时还原）----
    const rowsNow = () => ev("const t=document.getElementById('mParamTbody'); return t?t.querySelectorAll('.c-addr').length:-1");
    const originalRows = await rowsNow();
    let originalJson = null;
    if (originalRows > 0) {
      const cur = await cmd('R:CFG', 'CFG', 10000);
      if (cur.ok && cur.data) {
        originalJson = path.join(workDir, 'original.json');
        fs.writeFileSync(originalJson, JSON.stringify(cur.data.cfg || cur.data, null, 2), 'utf8');
      }
    }
    console.log('[准备] 设备原有寄存器: ' + originalRows + (originalJson ? '（已导出原配置）' : ''));

    const importFile = async (file) => {
      await client.send('Page.setInterceptFileChooserDialog', { enabled: true });
      const evtP = client.waitEvent('Page.fileChooserOpened', 8000);
      await click('#btnImport');
      const evt = await evtP;
      if (!evt || !evt.backendNodeId) throw new Error('没拿到文件选择框');
      await client.send('DOM.setFileInputFiles', { files: [file], backendNodeId: evt.backendNodeId });
      await sleepMs(1000);
      await autoConfirm(6000);
    };

    const results = [];
    for (const n of SIZES) {
      const label = '[N=' + n + ']';
      const file = path.join(workDir, 'cfg-' + n + '.json');
      fs.writeFileSync(file, JSON.stringify(buildCfg(n), null, 2), 'utf8');
      const t0 = Date.now();
      let ok = true, err = '';
      try {
        // 先把状态栏清掉：上一轮留下的"配置已保存"会让完成判定立刻命中，
        // 结果读到的是上一轮的行数和峰值（之前 N=8/16/32/60 都测出 rows=1 就是这个坑）。
        await ev("if (typeof status === 'function') status(" + JSON.stringify('正在导入 ' + n + ' 点配置…')
          + ", true); const t = document.getElementById('toast'); if (t) t.textContent = ''; return 1;");
        await importFile(file);
        const done = await waitFor(async () => {
          const u = await ui();
          if (/失败|超时|腾不出/.test(u.stMsg + u.toast)) return { bad: u };
          if (/配置已保存/.test(u.stMsg)) return { good: u };
          return null;
        }, 90000, 400);
        if (!done || done.bad) {
          ok = false;
          err = (done ? (done.bad.stMsg + ' / ' + done.bad.toast) : '等待保存超时');
        }
      } catch (e) { ok = false; err = String(e.message || e); }

      // 不管成功失败都读一次（失败的现场更需要）
      const trace = await cmd('R:CTRACE', 'CTRACE', 8000);
      await sleepMs(400);
      const mem = await cmd('R:MEM', 'MEM', 10000);
      const rows = await rowsNow();

      // 读回校验: "存进去了" != "读得回来"。
      //   2026-11-18 真机 32 点: W:CFINISH 回 OK, 但 R:CFG 在池子见底时被
      //   jencode 兜底成 RET:CFG={} —— 前端显示 0 行, 用户以为配置丢了。
      //   只测"保存成功"会把可用上限算高, 所以这里单独读一次设备。
      let readBack = null, readBackErr = '';
      try {
        const rb = await cmd('R:CFG', 'CFG', 20000);
        if (!rb.ok) readBackErr = String(rb.err || '读取失败');
        else {
          const d = rb.data || {};
          const g = d.cfg && d.cfg.regs;
          readBack = Array.isArray(g) ? g.length : Object.keys(g || {}).length;
        }
      } catch (e) { readBackErr = String(e.message || e); }

      const rec = { n, ok, rows, ms: Date.now() - t0, err, readBack, readBackErr };
      // 行数对不上就是没真正导入（脚本判定问题），不能当 PASS
      if (ok && rows !== n) {
        rec.ok = false;
        rec.err = '导入后表格只有 ' + rows + ' 行（期望 ' + n + '）';
        ok = false;
      }
      // 设备读不回来 = 这份配置现场用不了(前端刷新一次就显示 0 行, 再保存还会清空)
      if (ok && readBack !== n) {
        rec.ok = false;
        rec.err = '保存成功但读回失败: ' + (readBack == null
          ? (readBackErr || '设备没给出配置')
          : ('只有 ' + readBack + ' 行（期望 ' + n + '）'));
        ok = false;
      }
      if (trace.ok) {
        const stages = [];
        String(trace.raw).replace(/RET:CTRACE=/g, ' | ').split('|').forEach(seg => {
          const m = /^\s*(enter|gc|decoded|norm|freed|saved|done)\s+(\d+)\/(\d+)\s*$/.exec(seg);
          if (m) stages.push({ s: m[1], used: Number(m[2]), total: Number(m[3]) });
        });
        if (stages.length) {
          const peak = stages.reduce((a, b) => (b.used > a.used ? b : a), stages[0]);
          rec.peak = peak.used;
          rec.pool = peak.total;
          rec.peakPct = Math.round(peak.used / peak.total * 100);
          rec.peakStage = peak.s;
          rec.rawTrace = trace.raw;
        }
      }
      if (mem.ok) {
        const m = /lua:(\d+)\/(\d+)/.exec(mem.raw);
        const mx = /max:(\d+)/.exec(mem.raw);
        const sys = /sys:(\d+)\/(\d+)K/.exec(mem.raw);
        if (m) { rec.luaUsed = Number(m[1]); rec.luaTotal = Number(m[2]); rec.luaPct = Math.round(rec.luaUsed / rec.luaTotal * 100); }
        if (mx) rec.maxBlock = Number(mx[1]);
        if (sys) rec.sysPct = Math.round(Number(sys[1]) / Number(sys[2]) * 100);
        rec.rawMem = mem.raw;
      }

      results.push(rec);
      const warn = (rec.luaPct != null && rec.luaPct >= 95) ? '  ⚠ 池子只剩 ' + Math.round((rec.luaTotal - rec.luaUsed) / 1024) + 'KB' : '';
      console.log(label + (ok ? ' OK  ' : ' FAIL')
        + '  rows=' + rec.rows
        + (rec.readBack != null ? '  读回=' + rec.readBack : '  读回=--')
        + (rec.peak != null ? '  W:CFG峰值=' + rec.peak + '/' + rec.pool + ' (' + rec.peakPct + '% @' + rec.peakStage + ')' : '  W:CFG峰值=--')
        + (rec.luaUsed != null ? '  Lua=' + rec.luaUsed + '/' + rec.luaTotal + ' (' + rec.luaPct + '%)' : '')
        + (rec.maxBlock != null ? '  max=' + rec.maxBlock : '')
        + warn
        + (ok ? '' : '  :: ' + err.slice(0, 200))
        + '  (' + rec.ms + 'ms)');

      // 失败就停：设备可能停在半提交状态，继续测会把结论搅乱
      if (!ok) break;
    }

    // ---- 汇总 ----
    console.log('');
    console.log('===== 内存规模结果 =====');
    console.log('  N    W:CFG峰值(占池)      Lua水位    最大连续块  读回      结果');
    for (const r of results) {
      const peak = r.peak != null ? (r.peak + '/' + r.pool + ' ' + r.peakPct + '%') : '--';
      const lua = r.luaUsed != null ? (r.luaPct + '%') : '--';
      const rb = (r.readBack == null ? '--' : String(r.readBack + ' 行'));
      console.log('  ' + String(r.n).padEnd(4) + ' ' + peak.padEnd(20) + ' ' + lua.padEnd(10) + ' '
        + String(r.maxBlock != null ? r.maxBlock : '--').padEnd(11) + rb.padEnd(9)
        + (r.ok ? 'PASS' : 'FAIL'));
    }
    const best = results.filter(r => r.ok).pop();
    if (best && best.peakPct != null) {
      console.log('');
      console.log('参考: ' + best.n + ' 点配置 W:CFG 峰值 ' + best.peakPct + '%，余量 '
        + (best.pool - best.peak) + 'B（>=95% 视为 OOM 风险）');
    }
    if (results.some(r => !r.ok)) {
      const bad = results.find(r => !r.ok);
      console.log('最早失败规模: ' + bad.n + ' 点 —— ' + bad.err);
      exitCode = 1;
    }

    // ---- 收尾 ----
    if (!has('keep-config')) {
      if (originalJson) {
        console.log('[收尾] 导回原配置 …');
        await ev("if (typeof status === 'function') status('正在还原原配置…', true); const t=document.getElementById('toast'); if(t) t.textContent=''; return 1");
        await importFile(originalJson);
        const back = await waitFor(async () => {
          const u = await ui();
          if (/失败|腾不出|超时/.test(u.stMsg)) return { bad: u };
          return /配置已保存/.test(u.stMsg) ? { good: u } : null;
        }, 90000, 500);
        if (!back || back.bad) {
          console.log('[收尾] ⚠ 原配置没还原回去：' + (back ? (back.bad.stMsg || '') : '超时')
            + ' —— 设备里现在是测试配置，请手工处理');
          exitCode = 1;
        } else {
          console.log('[收尾] 原配置已还原');
        }
      } else {
        console.log('[收尾] 切回空闲并清空测试配置 …');
        await ev("document.querySelector('.tab-item[data-tab=\"tabMode\"]').click(); return 1");
        await sleepMs(300);
        await click('#mcIdle');
        await autoConfirm(8000);
        const idleOk = await waitFor(async () => ((await ui()).mode === 'idle' ? true : null), 15000);
        if (!idleOk) {
          console.log('[收尾] ⚠ 没切回空闲（当前 ' + (await ui()).mode + '），配置可能还留在设备里');
          exitCode = 1;
        }
      }
    }
    console.log('[收尾] 关闭串口');
    await click('#btnOpen');
    await sleepMs(500);

    if (client.errors && client.errors.length) {
      const errs = client.errors.filter(s => !/Electron Security Warning|Content-Security-Policy/i.test(s));
      if (errs.length) { console.log('[页面错误] ' + errs.slice(0, 5).join(' | ')); exitCode = 1; }
    }
  } catch (e) {
    console.error('[脚本错误] ' + (e && e.message ? e.message : e));
    exitCode = 2;
  } finally {
    cleanup();
  }
  process.exit(exitCode);
})();
