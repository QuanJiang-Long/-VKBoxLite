'use strict';
// tools/e2e/journey.js
//
// 前端全流程跑测 —— 真机(COMx) 与 LuatOS PC 模拟器(sim://) 共用同一份步骤。
//
// 判定原则（现场看结果时很重要）:
//   FAIL = 软件链路该过没过（串口打不开、指令不应答、配置存不下、导出/导入坏了）
//   SKIP = 依赖外部条件，条件不满足属正常，不是固件坏了:
//          - R:VAL 要有 485 从站应答
//          - sniff 推断要有总线流量
//          - R:MQTT 要有 4G + 平台可达
//   加 --expect-slave / --expect-net 可以把对应 SKIP 升级成 FAIL（产线验收用）。
//
// 所有 UI 操作都走真实 DOM（点按钮、填弹窗、拦文件选择框），不直接改内部状态，
// 这样测到的才是用户点得出来的那条路。只有 R:MEM / R:NET / R:MQTT 三条
// 没有界面入口的探针指令直接走 sendCmd（见各步骤注释）。

const fs = require('fs');
const path = require('path');

class Skip extends Error {}

const sleep = ms => new Promise(r => setTimeout(r, ms));

async function waitFor(fn, ms, interval = 250) {
  const end = Date.now() + ms;
  let last = null;
  while (Date.now() < end) {
    last = await fn();
    if (last) return last;
    await sleep(interval);
  }
  return last;
}

/**
 * @param {object} ctx
 * @param {(expr:string)=>Promise<any>} ctx.ev  页面内求值（见 cdp.makeEval）
 * @param {object} ctx.client                   CDP 连接（要 waitEvent / send）
 * @param {object} ctx.cfg
 *   target        要选的串口值: 'COM32' 或 'sim://127.0.0.1:18921/uart31'
 *   label         打印用名字（真机/模拟器）
 *   real          是否真机（影响超时与强校验）
 *   downloadDir   导出落盘目录（必须是脚本能读到的本地目录）
 *   writeCfg      是否真的写设备配置（false = 只读巡检）
 *   restore       切 idle 后是否把导出的配置导回去（保护现场设备）
 *   expectSlave   没有实时值时算 FAIL 而不是 SKIP
 *   expectNet     MQTT 未就绪算 FAIL 而不是 SKIP
 *   minMaxBlock   R:MEM 连续块下限（默认 2048）
 * @returns {{results:Array, notes:string[]}}
 */
async function runJourney(ctx) {
  const { ev, client, cfg } = ctx;
  const results = [];
  const notes = [];
  let originalRows = -1;        // 测试前设备上有几个寄存器（决定要不要还原）
  const note = m => notes.push(m);
  const click = sel => ev('const e=document.querySelector(' + JSON.stringify(sel)
    + '); if(!e) return false; e.click(); return true;');

  const ui = () => ev(`
    const g = id => { const e = document.getElementById(id); return e ? (e.textContent || '') : ''; };
    const v = id => { const e = document.getElementById(id); return e ? (e.value || '') : ''; };
    return {
      mock: (typeof S !== 'undefined') ? !!S.mock : null,
      open: (typeof S !== 'undefined') ? !!S.open : null,
      mode: (typeof S !== 'undefined') ? S.mode : null,
      stPort: g('stPort'), stMsg: g('stMsg'), stMode: g('stMode'), toast: g('toast'),
      sn: v('fSn'), imei: v('fImei'), iccid: v('fIccid'), csq: v('fCsq'),
      ver: v('fVer'), proj: v('fProj'), url: v('fUrl'),
    }`);

  // 自定义确认框（#modalConfirm）出现就点「确定」，直到连续 1.5s 没有新弹窗。
  // 注意 modalConfirm 是 position:fixed，offsetParent 恒为 null，不能用来判可见。
  const autoConfirm = async (waitMs = 8000) => {
    const deadline = Date.now() + waitMs;
    let clicks = 0, lastSeen = 0;
    while (Date.now() < deadline) {
      const shown = await ev(`
        const m = document.getElementById('modalConfirm');
        if (!m) return false;
        const cs = getComputedStyle(m);
        return cs.display !== 'none' && cs.visibility !== 'hidden' && cs.opacity !== '0';`);
      if (shown) {
        await ev("document.getElementById('cfYes').click(); return 1");
        clicks++;
        lastSeen = Date.now();
        await sleep(350);
      } else {
        if (clicks && Date.now() - lastSeen > 1500) break;
        await sleep(150);
      }
    }
    return clicks;
  };

  // 直接发一条设备指令: 先等上一条落地，避免被"单未决指令"保护瞬拒。
  const cmd = (line, expect, timeout) => ev(`
    for (let i = 0; i < 50 && (typeof S !== 'undefined') && S.pending; i++) {
      await new Promise(r => setTimeout(r, 100));
    }
    try {
      const r = await sendCmd(${JSON.stringify(line)}, ${JSON.stringify(expect)}, ${timeout || 8000});
      return { ok: true, raw: String(r.raw || ''), data: r.data };
    } catch (e) {
      return { ok: false, err: String((e && e.message) || e) };
    }`);

  const waitMode = (want, ms) => waitFor(async () => {
    const m = await ev("return (typeof S !== 'undefined') ? S.mode : null;");
    return m === want ? want : null;
  }, ms, 250);

  const manualRows = () => ev(
    "const t = document.getElementById('mParamTbody'); return t ? t.querySelectorAll('.c-addr').length : -1;");

  const switchTo = async (cardSel, mode, promptMs, waitMs) => {
    const cur = await ev("return (typeof S !== 'undefined') ? S.mode : null;");
    if (cur === mode) return { ok: true, already: true, modals: 0, u: await ui() };
    await ev("document.querySelector('.tab-item[data-tab=\"tabMode\"]').click(); return 1");
    await sleep(300);
    await click(cardSel);
    const modals = await autoConfirm(promptMs);
    const ok = await waitMode(mode, waitMs);
    const u = await ui();
    return { ok, modals, u };
  };

  const step = async (name, fn) => {
    const t0 = Date.now();
    try {
      const info = await fn();
      results.push({ name, status: 'PASS', info, ms: Date.now() - t0 });
    } catch (e) {
      if (e instanceof Skip) results.push({ name, status: 'SKIP', info: e.message, ms: Date.now() - t0 });
      else results.push({ name, status: 'FAIL', info: String((e && e.message) || e), ms: Date.now() - t0 });
    }
  };

  // ---------------------------------------------------------------- 0 页面
  await step('0 页面就绪', async () => {
    await sleep(800);
    const u = await ui();
    if (u.mock === null) throw new Error('页面里没有 S 状态（前端没加载完？）');
    if (u.mock) throw new Error('页面处于 mock 预览模式（window.serial 不在），测不到真实链路');
    return { target: cfg.target, label: cfg.label };
  });

  // ---------------------------------------------------------------- 1 枚举
  await step('1 枚举串口（应能看到 ' + cfg.target + '）', async () => {
    await click('#btnRefresh');
    // refreshPorts() 是异步的: 点完刷新它还会重建下拉框。必须等列表"稳定"
    // 再往下走, 否则下一步刚选好的口会被这一次重建清空。
    let prevSig = '';
    let prev = null;
    const list = await waitFor(async () => {
      const l = await ev(`
        const s = document.getElementById('comSel');
        if (!s) return null;
        return Array.from(s.options).map(o => ({ v: o.value, t: o.textContent || '' }));`);
      if (!l || l.length <= 1) { prevSig = ''; return null; }
      const sig = JSON.stringify(l);
      const stable = (sig === prevSig);
      prevSig = sig;
      prev = l;
      if (!stable) return null;    // 还在变, 再等一轮
      const want = String(cfg.target).toUpperCase();
      const hit = l.find(o => String(o.v).toUpperCase() === want
        || String(o.v).toUpperCase().indexOf(want) === 0
        || String(o.t).toUpperCase().indexOf(want) >= 0);
      return hit ? l : null;
    }, 8000, 350);
    if (!list) {
      const l = await ev(`
        const s = document.getElementById('comSel');
        return s ? Array.from(s.options).map(o => o.value).filter(Boolean) : [];`);
      throw new Error('串口列表里没有 ' + cfg.target + '，当前可选: ' + (l.join(', ') || '(空)'));
    }
    return list;
  });

  // ---------------------------------------------------------------- 2 打开
  await step('2 打开串口', async () => {
    // 选口和点"打开"放在同一次求值里: 中间不留窗口给 refreshPorts 重建下拉框。
    const doOpen = () => ev(`
      const s = document.getElementById('comSel');
      const btn = document.getElementById('btnOpen');
      if (!s || !btn) return null;
      const want = ${JSON.stringify(cfg.target)}.toUpperCase();
      const o = Array.from(s.options).find(x => String(x.value).toUpperCase() === want
        || String(x.value).toUpperCase().indexOf(want) === 0
        || String(x.textContent || '').toUpperCase().indexOf(want) >= 0);
      if (!o) return null;
      s.value = o.value;
      s.dispatchEvent(new Event('change'));
      btn.click();
      return { value: o.value, label: o.textContent || '' };`);
    const picked = await doOpen();
    if (!picked) throw new Error('下拉框里没找到 ' + cfg.target);
    let ok = await waitFor(async () => {
      const s = await ev("return (typeof S !== 'undefined') ? !!S.open : false;");
      return s ? true : null;
    }, cfg.real ? 12000 : 8000, 300);
    if (!ok) {
      // 再给一次机会: 有时下拉框刚被重建, 第一次点的值丢了
      await sleep(600);
      await doOpen();
      ok = await waitFor(async () => {
        const s = await ev("return (typeof S !== 'undefined') ? !!S.open : false;");
        return s ? true : null;
      }, 8000, 300);
    }
    const u = await ui();
    if (!ok) throw new Error('打开失败: ' + u.stMsg + ' / ' + u.toast + '（端口被其它程序占用？）');
    return { picked: picked.value, stPort: u.stPort };
  });

  // ---------------------------------------------------------------- 3 信息
  await step('3 读设备信息', async () => {
    await click('#btnReadInfo');
    const u = await waitFor(async () => {
      const x = await ui();
      return x.sn ? x : null;
    }, cfg.real ? 12000 : 8000, 400);
    if (!u) {
      const x = await ui();
      // SN 空是真机上很常见的一种"设备没做完产线工序": 固件能跑, R:INFO 也答,
      // 但 sn_state=empty、前端 SN 栏空、MQTT 的 clientId 会变成 "nil"。
      // 这里的报错要直接告诉现场怎么补, 而不是只说"没读到"。
      const st = await ev(`
        try { const r = await sendCmd('R:SN', 'SN', 4000); return String(r.raw || ''); }
        catch (e) { return 'ERR ' + e.message; }`);
      if (/EMPTY/.test(st)) {
        throw new Error('SN 未烧录（R:SN=EMPTY）。设备能采集, 但平台侧身份会变成 "nil";'
          + ' 产线需要用 W:SN=<SN> 烧写后再测 MQTT/平台');
      }
      throw new Error('SN 没读到: ' + x.stMsg + '（R:SN 应答: ' + st + '）');
    }
    if (cfg.real) {
      if (u.sn.trim().length < 8) throw new Error('SN 异常: ' + u.sn);
      if (!u.imei) note('IMEI 为空 —— 模组未注网/未插卡时会这样, 不影响 485 链路');
    }
    return { sn: u.sn, imei: u.imei, iccid: u.iccid, csq: u.csq, ver: u.ver, proj: u.proj };
  });

  // ---------------------------------------------------------------- 4 模式
  await step('4 读运行模式', async () => {
    await ev("document.querySelector('.tab-item[data-tab=\"tabMode\"]').click(); return 1");
    await sleep(300);
    await click('#btnModeRefresh');
    const ok = await waitFor(async () => {
      const s = await ev("const e = document.getElementById('stMode'); return e ? e.textContent.trim() : '';");
      return s ? s : null;
    }, 6000, 300);
    const u = await ui();
    if (!ok) throw new Error('模式状态没读出来: ' + u.stMsg);
    return { mode: u.mode, stMode: u.stMode };
  });

  // ---------------------------------------------------------------- 5 manual
  await step('5 切 manual（轮询）', async () => {
    const cur = await ev("return S.mode;");
    if (cur === 'manual') return { already: true, mode: 'manual' };
    // 只读巡检不切档：从 platform 切 manual 会问"清空 ds_pull"，
    // 从 manual 切走也会问"清空 ds_poll"，都会改设备上的槽位。
    if (cfg.readOnly) throw new Skip('--read-only：不切档（当前 ' + cur + '）');
    const r = await switchTo('#mcPoll', 'manual', 10000, cfg.real ? 15000 : 12000);
    if (!r.ok) throw new Error('模式没切到 manual（弹窗 ' + r.modals + ' 次）: ' + r.u.stMsg + ' / ' + r.u.toast);
    return { mode: r.u.mode, modals: r.modals };
  });

  // ---------------------------------------------------------------- 6 读配置
  await step('6 读 485 配置', async () => {
    await ev("document.querySelector('.tab-item[data-tab=\"tabManual\"]').click(); return 1");
    await sleep(300);
    // 不能等 S.cfgRead_m: 那个标记只在"首次激活 tab"时置 true, 手动点
    // 「读取配置」不会动它。按状态栏文案判更可靠。
    const before = (await ui()).stMsg;
    await click('#btnReadCfg');
    const done = await waitFor(async () => {
      const u = await ui();
      if (/失败/.test(u.stMsg) && u.stMsg !== before) return { bad: u };
      if (/配置已读取/.test(u.stMsg)) return { good: u };
      return null;
    }, cfg.real ? 15000 : 8000, 300);
    if (!done || done.bad) {
      const u = done ? done.bad : await ui();
      throw new Error('配置没读到: ' + u.stMsg + ' / ' + u.toast);
    }
    const baud = await ev("const e = document.getElementById('selBaud'); return e ? e.value : '';");
    const rows = await manualRows();
    if (originalRows < 0) originalRows = rows;   // 第一次读到即"测试前状态"
    return { baud, rows, stMsg: (await ui()).stMsg };
  });

  // ---------------------------------------------------------------- 7 测试点
  await step('7 准备测试寄存器', async () => {
    if (cfg.readOnly) throw new Skip('--read-only：不新增寄存器');
    const before = await manualRows();
    if (before > 0) return { reused: before, note: '沿用设备上已有配置，不写入测试点' };
    await click('#btnAddReg');
    await sleep(500);
    await ev(`
      document.getElementById('regAddr').value = '1';
      const t = document.getElementById('regType');
      if (t) { t.value = 'uint16'; if (typeof onRegTypeChange === 'function') onRegTypeChange(); }
      document.getElementById('regId').value = 'A1';
      document.getElementById('regAlias').value = '联调测试点';
      document.getElementById('regCount').value = '1';
      return 1;`);
    await ev("confirmAddReg(); return 1");
    await sleep(800);
    const after = await manualRows();
    if (after <= 0) throw new Error('添加寄存器失败（表格仍为空）');
    return { added: after };
  });

  // ---------------------------------------------------------------- 8 存配置
  await step('8 保存配置（W:CFG）', async () => {
    if (!cfg.writeCfg) throw new Skip('--no-write：跳过写设备');
    await click('#btnSaveCfg');
    await autoConfirm(8000);
    const ok = await waitFor(async () => {
      const u = await ui();
      if (/失败|超时/.test(u.stMsg + u.toast)) return { bad: u };
      if (/成功/.test(u.stMsg) || /保存成功/.test(u.toast)) return { good: u };
      return null;
    }, cfg.real ? 40000 : 15000, 400);
    if (!ok || ok.bad) {
      const u = ok ? ok.bad : await ui();
      throw new Error('保存失败: ' + u.stMsg + ' / ' + u.toast);
    }
    return { stMsg: ok.good.stMsg, toast: ok.good.toast };
  });

  // -------------------------------------------------------------- 8b 峰值内存
  // R:CTRACE 是固件给 W:CFG 留的分阶段采样（enter/freed/norm/saved/done 各一次
  // rtos.meminfo("lua")）。真机上最有价值的指标就是这里：水位看着正常，
  // 但 W:CFG 峰值可能已经贴到池顶（固件注释里 95.8% 就会 OOM）。
  await step('8b W:CFG 分阶段内存（R:CTRACE）', async () => {
    if (cfg.readOnly || !cfg.writeCfg) throw new Skip('本轮没写 W:CFG，没有采样');
    const r = await cmd('R:CTRACE', 'CTRACE', 8000);
    await sleep(400);   // 这条会回两行(#2/#1)，留点时间吃完
    if (!r.ok) throw new Skip('R:CTRACE 没有应答（该固件可能没开 TR）: ' + r.err);
    if (/empty/i.test(r.raw)) throw new Skip('设备没记录到 W:CFG 采样: ' + r.raw);
    const stages = [];
    String(r.raw).replace(/RET:CTRACE=/g, ' | ').split('|').forEach(seg => {
      const m = /^\s*(enter|freed|norm|saved|done)\s+(\d+)\/(\d+)\s*$/.exec(seg);
      if (m) stages.push({ stage: m[1], used: Number(m[2]), total: Number(m[3]) });
    });
    if (!stages.length) throw new Skip('R:CTRACE 格式不认识: ' + r.raw.slice(0, 200));
    const peak = stages.reduce((a, b) => (b.used > a.used ? b : a), stages[0]);
    const pct = peak.total ? Math.round(peak.used / peak.total * 100) : 0;
    if (pct >= 95) {
      throw new Error('W:CFG 峰值已用 ' + pct + '%（' + peak.stage + ' ' + peak.used + '/'
        + peak.total + '），距 OOM 只剩 ' + (peak.total - peak.used) + 'B: ' + r.raw.slice(0, 300));
    }
    if (pct >= 90) note('W:CFG 峰值 ' + pct + '%（' + peak.stage + '），大配置再加点就要 OOM 了');
    return { peak: peak.stage + ' ' + peak.used + '/' + peak.total, pct, stages };
  });

  // ---------------------------------------------------------------- 9 导出
  let exportedFile = null;
  await step('9 导出配置 JSON', async () => {
    if (cfg.readOnly && (await ev("return S.mode;")) !== 'manual') {
      throw new Skip('--read-only 且不在 manual：导出依赖读到的配置，先跳过');
    }
    fs.mkdirSync(cfg.downloadDir, { recursive: true });
    const t0 = Date.now();
    await click('#btnExport');
    const picked = await waitFor(async () => {
      const r = await ev(`
        const b = document.querySelector('button[data-fmt="json"]');
        if (!b) return false;
        b.click();
        return true;`);
      return r ? true : null;
    }, 5000, 300);
    if (!picked) throw new Error('没出现导出格式弹窗');
    const file = await waitFor(() => {
      let names = [];
      try { names = fs.readdirSync(cfg.downloadDir); } catch (e) { return null; }
      const hit = names.filter(n => /\.json$/i.test(n))
        .map(n => path.join(cfg.downloadDir, n))
        .filter(p => { try { return fs.statSync(p).mtimeMs >= t0 - 2000; } catch (e) { return false; } })
        .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
      return hit || null;
    }, 15000, 300);
    if (!file) {
      throw new Error('导出目录里没出现新 JSON: ' + cfg.downloadDir
        + '（应用不是用 VKBOX_DOWNLOAD_DIR 启动时，会弹原生保存框挡住自动化）');
    }
    let data;
    try { data = JSON.parse(fs.readFileSync(file, 'utf8')); }
    catch (e) { throw new Error('导出的 JSON 解析失败: ' + e.message); }
    const regs = (data.registers || data.regs || []).length;
    if (!regs) throw new Error('导出的 JSON 里没有寄存器: ' + path.basename(file));
    exportedFile = file;
    return { file: path.basename(file), registers: regs, mqttHost: (data.mqtt && data.mqtt.host) || '' };
  });

  // ---------------------------------------------------------------- 10 导入
  await step('10 导入配置（回环）', async () => {
    if (cfg.readOnly) throw new Skip('--read-only：不导入（会写设备）');
    if (!exportedFile) throw new Skip('上一步没导出成功，无从导入');
    const expectRows = await manualRows();
    await client.send('Page.setInterceptFileChooserDialog', { enabled: true });
    const evtP = client.waitEvent('Page.fileChooserOpened', 8000);
    await click('#btnImport');
    const evt = await evtP;
    if (!evt || !evt.backendNodeId) throw new Error('没拿到文件选择框（原生对话框没被拦截？）');
    await client.send('DOM.setFileInputFiles', { files: [exportedFile], backendNodeId: evt.backendNodeId });
    await sleep(1200);
    await autoConfirm(6000);
    const u = await waitFor(async () => {
      const x = await ui();
      if (/失败|无效|错误/.test(x.toast + x.stMsg)) return { bad: x };
      if (/已导入|已保存/.test(x.toast + x.stMsg)) return { good: x };
      return null;
    }, 15000, 400);
    if (!u || u.bad) {
      const x = u ? u.bad : await ui();
      throw new Error('导入失败: ' + x.toast + ' / ' + x.stMsg);
    }
    const rows = await manualRows();
    if (expectRows >= 0 && rows !== expectRows) {
      note('导入后寄存器行数 ' + rows + ' ≠ 导入前 ' + expectRows + '（可接受，但要留意）');
    }
    return { rows, toast: u.good.toast };
  });

  // ---------------------------------------------------------------- 11 实时值
  await step('11 读实时值（需 485 从站）', async () => {
    await ev("document.querySelector('.tab-item[data-tab=\"tabManual\"]').click(); return 1");
    await sleep(300);
    await click('#btnReadVal');
    await sleep(6000);
    const vals = await ev(`
      const t = document.getElementById('mParamTbody');
      if (!t) return [];
      return Array.from(t.querySelectorAll('.c-val')).map(e => e.value).filter(v => v !== '');`);
    const u = await ui();
    if (!vals.length) {
      const why = '没读到实时值（' + (u.stMsg || u.toast)
        + '）—— 485 从站未接/未上电/从站地址与配置不符都会这样';
      if (cfg.expectSlave) throw new Error(why);
      throw new Skip(why);
    }
    return { values: vals.slice(0, 8), stMsg: u.stMsg };
  });

  // ---------------------------------------------------------------- 12 内存
  // 没有界面入口的探针，直接走 sendCmd（这条就是给排障用的）。
  await step('12 内存连续块（R:MEM）', async () => {
    const r = await cmd('R:MEM', 'MEM', 12000);
    if (!r.ok) throw new Error('R:MEM 失败: ' + r.err);
    const max = Number((/max:(\d+)/.exec(r.raw) || [])[1] || 0);
    const fail = Number((/fail:(\d+)/.exec(r.raw) || [])[1] || 0);
    const lua = /lua:(\d+)\/(\d+)/.exec(r.raw);
    if (!max) throw new Error('R:MEM 应答看不懂: ' + r.raw);
    if (max < cfg.minMaxBlock) {
      throw new Error('最大连续块只有 ' + max + 'B < 下限 ' + cfg.minMaxBlock
        + 'B（W:CFG 大包会写不进去）: ' + r.raw);
    }
    const info = { max, fail, raw: r.raw };
    if (lua) {
      const used = Number(lua[1]), total = Number(lua[2]);
      info.lua = used + '/' + total;
      if (total) {
        info.luaPct = Math.round(used / total * 100);
        if (info.luaPct >= 90) note('⚠ Lua 池已用 ' + info.luaPct + '%（接近红线，长时间跑要盯）');
      }
    }
    return info;
  });

  // ---------------------------------------------------------------- 13 网络
  await step('13 4G 网络快照（R:NET）', async () => {
    const r = await cmd('R:NET', 'NET', 10000);
    if (!r.ok) throw new Skip('R:NET 没有应答（该固件未开 mobile？）: ' + r.err);
    // 应答形如 iccid:...;imsi:...;status:1;csq:22;ip:10.x.x.x
    const kv = {};
    String(r.raw).replace(/^RET:NET=/, '').split(';').forEach(p => {
      const i = p.indexOf(':');
      if (i > 0) kv[p.slice(0, i).trim()] = p.slice(i + 1).trim();
    });
    const online = String(kv.status) === '1' && kv.ip && kv.ip !== '-';
    if (!online) {
      const why = '未注网/无 IP（status=' + kv.status + ', ip=' + kv.ip + ', csq=' + kv.csq + '）';
      if (cfg.expectNet) throw new Error(why);
      throw new Skip(why);
    }
    return { status: kv.status, csq: kv.csq, ip: kv.ip, iccid: kv.iccid };
  });

  // ---------------------------------------------------------------- 14 MQTT
  await step('14 MQTT 就绪（R:MQTT）', async () => {
    const r = await cmd('R:MQTT', 'MQTT', 10000);
    if (!r.ok) throw new Skip('R:MQTT 没有应答: ' + r.err);
    const d = (r.data && typeof r.data === 'object') ? r.data : {};
    const st = (d.stat && typeof d.stat === 'object') ? d.stat : {};
    // ⚠️ ready 只表示"配置齐全、能连"(mqttcfg.effective: ready = profile ~= nil),
    // 不代表连上了。判断在线必须看 stat.connected, 否则无卡设备也会报 PASS。
    const connected = st.connected === true;
    if (!connected) {
      const parts = [];
      parts.push(d.ready === true ? '配置齐全' : '配置不全');
      parts.push('want_run=' + (st.want_run === true));
      if (st.failed) parts.push('failed=' + st.failed);
      if (st.backoff) parts.push('backoff=' + st.backoff);
      if (d.err) parts.push('err=' + d.err);
      const why = 'MQTT 未连接（' + parts.join(', ') + '）'
        + (st.want_run === true ? ' —— 已要求连接但没连上' : ' —— 当前没要求连接')
        + '；无卡/未注网/平台不可达时正常';
      if (cfg.expectNet && st.want_run === true) throw new Error(why);
      throw new Skip(why);
    }
    return { connected: true, pub: st.pub, sub: st.sub };
  });

  // ---------------------------------------------------------------- 15 sniff
  await step('15 切 sniff + 推断（需总线流量）', async () => {
    if (cfg.readOnly) throw new Skip('--read-only：不切 sniff（切档会问是否清空 ds_poll）');
    const r = await switchTo('#mcSniff', 'sniff', 12000, cfg.real ? 25000 : 20000);
    if (!r.ok) throw new Error('模式没切到 sniff（弹窗 ' + r.modals + ' 次）: ' + r.u.stMsg);
    await ev("document.querySelector('.tab-item[data-tab=\"tabSniff\"]').click(); return 1");
    await sleep(400);
    await click('#btnInfer');
    // ⚠️ S.infer 是个对象（regs/slaves/stat/total...，固定 10 个键），
    // 不能用 Object.keys(S.infer).length 判"推断到东西了" —— 没有总线流量时
    // 它照样有 10 个键。要看 total（本轮推断到的点数）。
    const info = await waitFor(async () => {
      const d = await ev(`
        if (typeof S === 'undefined' || !S.infer) return { total: 0, rows: 0, stat: {} };
        return {
          total: Number(S.infer.total || 0),
          rows: (S.infer.regs || []).length,
          stat: S.infer.stat || {},
        };`);
      return (d && d.total > 0) ? d : null;
    }, 25000, 500);
    const u = await ui();
    if (!info) {
      const d = await ev(`
        if (typeof S === 'undefined' || !S.infer) return null;
        return { total: Number(S.infer.total || 0), stat: S.infer.stat || {} };`);
      throw new Skip('推断表为空（' + (u.stMsg || u.toast)
        + (d ? '；total=' + d.total + ', stat=' + JSON.stringify(d.stat).slice(0, 160) : '')
        + '）—— 总线上没有报文时正常，接上从站/让主站跑起来再测');
    }
    return { inferred: info.total, rows: info.rows, stMsg: u.stMsg };
  });

  // ---------------------------------------------------------------- 16 idle
  await step('16 切回 idle（并确认配置已复位）', async () => {
    if (cfg.readOnly) throw new Skip('--read-only：不切空闲（切到空闲会复位用户配置）');
    const before = await ev("return (typeof S !== 'undefined') ? S.mode : null;");
    if (before === 'idle') {
      throw new Skip('设备本来就在 idle（前面没切到其它档），这一步验证不了"切档复位"');
    }
    const r = await switchTo('#mcIdle', 'idle', 8000, cfg.real ? 15000 : 10000);
    if (!r.ok) throw new Error('模式没切回 idle: ' + r.u.stMsg + ' / ' + r.u.toast);
    const c = await cmd('R:CFG', 'CFG', 10000);
    const raw = c.ok ? c.raw : '(读失败: ' + c.err + ')';
    // 注意不能只看应答里有没有 {} —— 复位后的默认配置里 regs 本来就是 {}，
    // 要按"寄存器表是否为空"判。
    let cleared = false;
    if (c.ok && c.data && typeof c.data === 'object') {
      const regs = (c.data.cfg && c.data.cfg.regs) || c.data.regs;
      cleared = !regs || (Array.isArray(regs) ? regs.length === 0 : Object.keys(regs).length === 0);
    }
    if (!cleared) note('切 idle 后 R:CFG 里还有寄存器，设备可能没能清空: ' + raw);
    return { mode: 'idle', stMsg: r.u.stMsg, cfgAfterIdle: raw, cleared };
  });

  // ---------------------------------------------------------------- 17 还原
  await step('17 还原现场配置', async () => {
    if (!cfg.restore) throw new Skip('--no-restore：不还原（设备保持空闲/空配置）');
    // 设备原本就是空配置时,"还原"没有意义 —— 反而会把联调用的测试点写回去。
    // 这种设备测完就该是空闲 + 空配置, 直接跳过。
    if (originalRows === 0) throw new Skip('设备原本没有配置（0 个寄存器），保持空闲即可，不写入测试点');
    if (!exportedFile) throw new Skip('没有可还原的导出文件');
    const r = await switchTo('#mcPoll', 'manual', 10000, cfg.real ? 15000 : 12000);
    if (!r.ok) throw new Error('切回 manual 失败: ' + r.u.stMsg);
    await ev("document.querySelector('.tab-item[data-tab=\"tabManual\"]').click(); return 1");
    await sleep(400);
    await client.send('Page.setInterceptFileChooserDialog', { enabled: true });
    const evtP = client.waitEvent('Page.fileChooserOpened', 8000);
    await click('#btnImport');
    const evt = await evtP;
    if (!evt || !evt.backendNodeId) throw new Error('没拿到文件选择框');
    await client.send('DOM.setFileInputFiles', { files: [exportedFile], backendNodeId: evt.backendNodeId });
    await sleep(1200);
    await autoConfirm(6000);
    const u = await waitFor(async () => {
      const x = await ui();
      if (/失败|无效|错误/.test(x.toast + x.stMsg)) return { bad: x };
      if (/已导入|已保存|成功/.test(x.toast + x.stMsg)) return { good: x };
      return null;
    }, 20000, 400);
    if (!u || u.bad) {
      const x = u ? u.bad : await ui();
      throw new Error('还原失败: ' + x.toast + ' / ' + x.stMsg);
    }
    return { rows: await manualRows(), toast: u.good.toast };
  });

  // ---------------------------------------------------------------- 18 断连
  await step('18 关闭串口', async () => {
    await click('#btnOpen');   // 同一个按钮: 打开/关闭 切换
    const ok = await waitFor(async () => {
      const s = await ev("return (typeof S !== 'undefined') ? !!S.open : true;");
      return !s ? true : null;
    }, 8000, 250);
    const u = await ui();
    if (!ok) throw new Error('串口没关掉: ' + u.stPort);
    return { stPort: u.stPort, stMsg: u.stMsg };
  });

  // ---------------------------------------------------------------- 19 错误
  await step('19 页面错误汇总', async () => {
    const errs = (client.errors || []).filter(s => !/Electron Security Warning|Content-Security-Policy/i.test(s));
    if (errs.length) throw new Error('页面有 ' + errs.length + ' 条错误/警告: ' + errs.slice(0, 5).join(' | '));
    return { errors: 0 };
  });

  return { results, notes };
}

module.exports = { runJourney, Skip, sleep, waitFor };
