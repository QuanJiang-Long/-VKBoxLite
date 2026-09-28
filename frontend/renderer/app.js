//=====================================================================
// app.js - 渲染进程业务逻辑
// 依赖：protocol.js（Protocol 全局）、window.serial（preload 暴露）
// 浏览器预览模式：无 window.serial 时自动启用 mock，不影响界面联调
//
// 页面分工：
//   首页       —— 运行状态总览 + 快速操作
//   运行模式   —— poll / sniff / idle 互斥切换 + 开机默认模式
//   poll模式   —— 485 串口参数 + 寄存器表 + MQTT 连接与上报
//   sniff模式  —— 解译帧实时视图 + 轮询表推断 + 总线诊断
//=====================================================================

//---------------------------------------------------------------------
// 全局状态
//---------------------------------------------------------------------
const S = {
  port: '',            // 当前串口路径
  open: false,         // 串口是否已打开
  busy: false,         // 是否有指令在等待应答
  pending: null,       // { cmd, resolve, timer, settle } 当前等待的应答
  cfg: null,           // 设备返回的 poll 配置（含 regs）
  regs: [],            // 寄存器表 [{addr,count,name,dtype,byteOrder,wordOrder}]
  mode: 'idle',        // 当前 485 运行模式（始终跟随设备，不被用户选择污染）
  modeStat: null,      // R:MODE 返回的完整状态
  modePending: null,   // 用户已选但设备尚未确认的模式；null = 无待应用选择
  modeSwitching: false,// 是否正在切换模式（防连点）
  stat: null,          // R:STAT 的完整负载 {mode,data,guard,store,mqtt} 五段平级。
                       // ⚠️ 不能只存 r.data.mode：data/guard/store 三段会被丢掉，
                       //    首页"看门狗/数据点数/本地落盘"会永远显示未启用/--。
  mqtt: null,          // R:MQTT 返回的状态
  sniffCfg: null,      // R:SNIFFCFG 返回的配置
  frames: [],          // 最近解译帧
  infer: null,         // R:INFER 返回的推断结果
  mock: !window.serial // 浏览器预览模式
};

const $ = id => document.getElementById(id);

//---------------------------------------------------------------------
// 采集停滞判定阈值（秒）。
// 必须与设备端 lua/core/config.lua 的 cfg.STALL_LIMIT_S 保持一致。
// ⚠️ stall 是"距上次采集活动的秒数"，不是布尔值。idle / sniff 模式下
//    本来就没有采集活动（guard.alive() 只在 poll 轮询/写事务里被调），
//    stall 会从开机起单调增长。若按"非 0 即停滞"判断，这两种模式下
//    必然误报红色"停滞!"，而看门狗其实一直在正常喂狗。
//    只有真正超过设备端阈值才算停滞。
//---------------------------------------------------------------------
const STALL_LIMIT_S = 120;

// 把 guard.status() 的 stall 归一成"是否停滞"
//   @param g          guard 段（可能整段缺失）
//   @param collecting 当前是否正在轮询采集（poll.running）
//   @return { stalled, stall }  stalled=是否停滞, stall=秒数(取不到记 0)
// ⚠️ 两个条件必须同时满足才算停滞：
//    1) 正在轮询 —— idle/sniff 模式下 guard.alive() 没人调，stall 从开机
//       起单调增长，超过阈值是必然的，那是"没在采集"而不是"采集卡死"；
//    2) stall 超过设备端阈值 STALL_LIMIT_S。
function wdtStalled(g, collecting) {
  const stall = (g && typeof g.stall === 'number') ? g.stall : 0;
  if (!collecting) return { stalled: false, stall: stall };
  return { stalled: stall > STALL_LIMIT_S, stall: stall };
}

const el = new Proxy({
  comSel: $('comSel'), btnRefresh: $('btnRefresh'), btnOpen: $('btnOpen'),
  btnImport: $('btnImport'), btnExport: $('btnExport'), btnReadInfo: $('btnReadInfo'),
  fSn: $('fSn'), fImei: $('fImei'), fIccid: $('fIccid'), fCsq: $('fCsq'),
  fVer: $('fVer'), fProj: $('fProj'), fUrl: $('fUrl'),
  btnReadCfg: $('btnReadCfg'), btnSaveCfg: $('btnSaveCfg'),
  selBaud: $('selBaud'), inpRound: $('inpRound'),
  inpSlave: $('inpSlave'), inpTimeout: $('inpTimeout'),
  btnReadVal: $('btnReadVal'), btnAddReg: $('btnAddReg'), paramTbody: $('paramTbody'),
  stPort: $('stPort'), stDev: $('stDev'), stSn: $('stSn'), stMode: $('stMode'),
  stMqtt: $('stMqtt'), stMsg: $('stMsg'), toast: $('toast'),
  // 运行模式页
  btnModeRefresh: $('btnModeRefresh'),
  selBootMode: $('selBootMode'), btnSaveBoot: $('btnSaveBoot'),
  // 首页
  btnHomeRefresh: $('btnHomeRefresh'), homeKv: $('homeKv'),
  swStoreOn: $('swStoreOn'), btnStoreSave: $('btnStoreSave'),
  btnQuickPoll: $('btnQuickPoll'), btnQuickSniff: $('btnQuickSniff'),
  btnQuickStop: $('btnQuickStop'), btnQuickReport: $('btnQuickReport'), btnQuickRst: $('btnQuickRst'),
  // MQTT 页
  btnMqttRefresh: $('btnMqttRefresh'), btnMqttSave: $('btnMqttSave'),
  btnMqttReport: $('btnMqttReport'), btnMqttReset: $('btnMqttReset'),
  mqHost: $('mqHost'), mqPort: $('mqPort'), mqSsl: $('mqSsl'), mqUser: $('mqUser'),
  mqPass: $('mqPass'), mqClientId: $('mqClientId'),
  mqPub: $('mqPub'), mqSub: $('mqSub'), mqInterval: $('mqInterval'),
  mqAllowNoSn: $('mqAllowNoSn'),
  // MQTT 会话管理：select（离线自动销毁=0 / 持久会话=1），不是开关
  mqKeepSession: $('mqKeepSession'),
  // 报文页
  btnFrameRefresh: $('btnFrameRefresh'), btnFrameClear: $('btnFrameClear'),
  frameFilter: $('frameFilter'), frameAuto: $('frameAuto'), frameLog: $('frameLog'),
  btnInfer: $('btnInfer'), btnApplyInfer: $('btnApplyInfer'), inferTbody: $('inferTbody'),
  inferHint: $('inferHint'),
  btnBusSniff: $('btnBusSniff'), busSniffMs: $('busSniffMs'),
  txHex: $('txHex'), btnTx: $('btnTx')
}, {
  // 未在表里列出的 id 走 $() 现取（如 hStore 等只读展示字段），
  // 取不到返回 null，由调用方判空
  get(t, k) { return t[k] !== undefined ? t[k] : $(k); }
});

//---------------------------------------------------------------------
// 基础 UI 辅助
//---------------------------------------------------------------------
let toastTimer = null;
function toast(msg, ms = 2600) {
  el.toast.textContent = msg;
  el.toast.style.display = 'block';
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.toast.style.display = 'none', ms);
}
function status(msg, ok = true) {
  el.stMsg.textContent = msg;
  el.stMsg.className = ok ? 'ok' : 'err';
}
function radioVal(name) {
  const r = document.querySelector('input[name="' + name + '"]:checked');
  return r ? r.value : '';
}
function setRadio(name, val) {
  document.querySelectorAll('input[name="' + name + '"]').forEach(r => {
    r.checked = (r.value === String(val));
  });
}
function setKv(id, text, bad) {
  const n = $(id);
  if (!n) return;
  n.textContent = (text === null || text === undefined || text === '') ? '--' : String(text);
  n.className = bad ? 'bad' : '';
}
function esc(s) {
  return String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

//---------------------------------------------------------------------
// 串口
//---------------------------------------------------------------------
async function refreshPorts() {
  if (S.mock) {
    el.comSel.innerHTML = '<option value="MOCK">MOCK（浏览器预览）</option>';
    status('浏览器预览模式（mock 串口）', true);
    return;
  }
  const r = await window.serial.list();
  if (!r.ok) { toast('枚举串口失败：' + r.error); return; }
  el.comSel.innerHTML = '<option value="">-- 选择串口 --</option>';
  r.ports.forEach(p => {
    const o = document.createElement('option');
    o.value = p.path;
    o.textContent = p.label;
    el.comSel.appendChild(o);
  });
  if (r.ports.length === 0) toast('未发现串口，请检查 USB 连接并安装驱动');
}

async function togglePort() {
  if (S.open) {
    stopAutoRefresh();
    if (!S.mock) await window.serial.close();
    setPortState(false, '');
    status('串口已关闭', true);
    return;
  }
  const p = el.comSel.value;
  if (!p) { toast('请先选择串口'); return; }
  el.btnOpen.disabled = true;
  let r = { ok: true };
  if (!S.mock) r = await window.serial.open({ path: p, baud: 115200 });
  el.btnOpen.disabled = false;
  if (!r.ok) { toast('打开串口失败：' + r.error); return; }
  S.port = p;
  setPortState(true, p);
  status('串口已打开：' + p, true);
  toast('串口已打开，正在读取设备信息…');
  // ⚠️ 必须串行：sendCmd 是单未决设计，并发发两条会让第二条
  //    立刻以"上一条指令尚未返回"失败，且 Promise.all 会吞掉这个错
  await readInfo();
  await readMode();
  await readHome();      // R:STAT 五段全量；少了它，首页看门狗/点数/落盘要等 5s 定时器
  await readMqtt();
  startAutoRefresh();
}

function setPortState(open, path) {
  S.open = open;
  el.btnOpen.textContent = open ? '关闭串口' : '打开串口';
  el.stPort.textContent = open ? (path || S.port) : '未连接';
  el.stPort.style.color = open ? '#0a7d2c' : '#666';
  [el.btnReadInfo, el.btnReadCfg, el.btnSaveCfg, el.btnReadVal].forEach(b => b.disabled = !open);
}

//---------------------------------------------------------------------
// 指令收发：发送一行 -> 等 RET: 应答（超时 3s）
//   单未决设计：一次只允许一条在途指令，设备逐条应答
//---------------------------------------------------------------------
function sendCmd(line, expectCmd, timeout = 3000) {
  return new Promise((resolve, reject) => {
    if (!S.open) return reject(new Error('串口未打开'));
    if (S.pending) return reject(new Error('上一条指令尚未返回，请稍候'));
    let done = false;
    const finish = (fn, v) => {
      if (done) return;
      done = true;
      clearTimeout(S.pending.timer);
      S.pending = null;
      fn(v);
    };
    S.pending = {
      cmd: expectCmd,
      timer: setTimeout(() => finish(reject, new Error('设备应答超时：' + line)), timeout),
      settle: (resp) => {
        if (!resp.ok) return finish(reject, new Error('设备返回失败：' + (resp.data || resp.raw)));
        finish(resolve, resp);
      }
    };
    // 始终走 window.serial.send：mock 对象的 send 负责调度模拟应答，
    // 短路成 resolve 会让 mock 永远收不到指令、浏览器预览必然超时。
    const p = window.serial.send(line);
    p.then(r => { if (!r.ok) finish(reject, new Error(r.error || '发送失败')); })
     .catch(e => finish(reject, e));
  });
}

// 收到一行 -> 路由到等待中的指令
function onSerialLine(line) {
  const resp = Protocol.decode(line);
  if (!resp) return;
  // 匹配条件：cmd 相同，或设备返回 FAIL（错误要透传给调用方），
  // 或裸 RET:OK（写指令的成功应答，老固件可能不返回 key）
  const matched = S.pending && (
    resp.cmd === S.pending.cmd ||
    !resp.ok ||
    (resp.cmd === 'OK' && S.pending.cmd !== 'SN')
  );
  if (matched) {
    S.pending.settle(resp);
  } else if (!S.pending) {
    // 设备主动上报（预留）：如 VAL= 推送
    console.log('[recv]', line);
  }
}

//---------------------------------------------------------------------
// 读设备信息
//---------------------------------------------------------------------
async function readInfo() {
  try {
    const r = await sendCmd(Protocol.Enc.info(), 'INFO');
    const d = r.data || {};
    el.fSn.value    = d.sn || '';
    el.fImei.value  = d.imei || '';
    el.fIccid.value = d.iccid || '';
    el.fCsq.value   = d.csq != null ? d.csq : (d.rsrp != null ? 'rsrp ' + d.rsrp : '');
    el.fVer.value   = d.version || d.fw || '';
    el.fProj.value  = d.project || '';
    el.fUrl.value   = d.server || d.url || el.fUrl.value;
    el.stSn.textContent = d.sn || '--';
    el.stDev.textContent = (d.project || '--') + ' / ' + (d.version || d.fw || '--');
    status('设备信息已读取', true);
  } catch (e) {
    // 老固件没有 R:INFO，退回 R:ID + R:SN
    try {
      const r2 = await sendCmd(Protocol.Enc.id(), 'ID');
      const d2 = r2.data || {};
      if (typeof d2 === 'object') {
        el.fSn.value = d2.sn || '';
        el.fImei.value = d2.imei || '';
        el.fCsq.value = d2.rsrp != null ? 'rsrp ' + d2.rsrp : '';
        el.stSn.textContent = d2.sn || '--';
      }
      status('已读取基础信息（固件不支持 R:INFO，建议升级）', true);
    } catch (e2) {
      status('读取失败：' + e2.message, false);
      toast('读取设备信息失败：' + e2.message);
    }
  }
}

//=====================================================================
// 485 poll 配置读 / 写
//=====================================================================
async function readCfg() {
  try {
    const rc = await sendCmd(Protocol.Enc.cfg(), 'CFG');
    const payload = rc.data;
    const c = (payload && payload.cfg) ? payload.cfg : payload;
    if (c && typeof c === 'object') {
      S.cfg = c;
      el.selBaud.value = String(c.baud || 9600);
      setRadio('databits', String(c.databits || 8));
      setRadio('parity', String(c.parity != null ? c.parity : 0));
      setRadio('stopbits', String(c.stopbits || 1));
      // "485方向控制GPIO" 输入框已按需求移除。GPIO8 方向控制由设备端
      // 脚本固定处理（core/config.lua 的 UART_485_PIN），前端不再暴露。
      // ⚠️ 千万不要在这里给已删除的控件赋值：el 取不到会是 null，
      //    整个 readCfg 抛 TypeError 被下面的 catch 吞掉，
      //    后面所有表单项都不回填，表现为"读配置后表单全空"。
      el.inpRound.value = c.interval_ms || 3000;
      el.inpSlave.value = c.slave || 1;
      el.inpTimeout.value = (c.timeout_ms == null) ? '' : c.timeout_ms;
      if (payload && payload.src === 'default') {
        toast('设备尚未保存过配置，当前为默认值');
      }
    }
    const rr = await sendCmd(Protocol.Enc.reg(), 'REG');
    if (Array.isArray(rr.data)) {
      S.regs = rr.data;
      renderRegTable();
      status('配置已读取：' + S.regs.length + ' 个寄存器', true);
    } else {
      status('配置已读取', true);
    }
  } catch (e) {
    status('读取配置失败：' + e.message, false);
    toast('读取配置失败：' + e.message);
  }
}

// 收集串口配置。返回 { ok, cfg } 或 { ok:false, err }
// 单选钮没选中时 parseInt('') = NaN，绝不能让 NaN/null 流到设备端
// （设备 normalize 会整条拒绝，用户只看到一句"保存失败"却不知道原因）
function collectCfg() {
  const baud      = parseInt(el.selBaud.value, 10);
  const databits  = parseInt(radioVal('databits'), 10);
  const parity    = parseInt(radioVal('parity'), 10);
  const stopbits  = parseInt(radioVal('stopbits'), 10);
  const slave     = parseInt(el.inpSlave.value, 10);
  const interval  = parseInt(el.inpRound.value, 10);
  const timeout   = el.inpTimeout.value.trim();

  if (!baud || baud < 300 || baud > 921600) return { ok: false, err: '波特率越界(300~921600)' };
  if (databits !== 7 && databits !== 8)    return { ok: false, err: '数据位只能是 7 或 8' };
  if (parity !== 0 && parity !== 1 && parity !== 2) return { ok: false, err: '校验位未选择' };
  if (stopbits !== 1 && stopbits !== 2)    return { ok: false, err: '停止位只能是 1 或 2' };
  if (!slave || slave < 1 || slave > 247)  return { ok: false, err: '从机地址越界(1~247)' };
  if (!interval || interval < 200)         return { ok: false, err: '轮询间隔不能小于 200ms' };
  if (timeout !== '' && (isNaN(+timeout) || +timeout < 50 || +timeout > 500)) {
    return { ok: false, err: '响应超时越界(50~500ms)，或留空使用早返回模式' };
  }

  return {
    ok: true,
    cfg: {
      baud: baud,
      databits: databits,
      parity: parity,
      stopbits: stopbits,
      slave: slave,
      interval_ms: interval,
      // 留空 = 早返回模式（收到响应立刻走下一事务）
      timeout_ms: timeout === '' ? null : parseInt(timeout, 10)
    }
  };
}

function collectRegs() {
  const out = [];
  el.paramTbody.querySelectorAll('tr').forEach(tr => {
    const addr = parseInt(tr.querySelector('.c-addr').value, 10);
    const dtype = tr.querySelector('.c-type').value;
    const name = tr.querySelector('.c-name').value.trim();
    const count = parseInt(tr.querySelector('.c-count').value, 10);
    const byteOrder = tr.querySelector('.c-bo').value;
    const wordOrder = tr.querySelector('.c-wo').value;
    // 上报别名：MQTT 的 name 字段。空串照样下发，设备端会退回用标识符
    const alias = tr.querySelector('.c-alias').value.trim();
    // 落盘阈值：空/NaN 当 0（每轮都存）；负数拒绝（设备端会判越界）
    let eps = parseFloat(tr.querySelector('.c-eps').value);
    if (isNaN(eps) || eps < 0) eps = 0;
    if (!isNaN(addr) && dtype && count > 0) {
      out.push({ addr, count, name, alias, dtype, byteOrder, wordOrder, eps });
    }
  });
  return out;
}

async function saveCfg() {
  const c = collectCfg();
  if (!c.ok) { toast(c.err); status('配置无效：' + c.err, false); return; }
  const cfg = c.cfg;
  const regs = collectRegs();
  if (regs.length === 0) { toast('参数列表为空，请先添加寄存器'); return; }
  const dup = regs.some((r, i) => regs.findIndex(x => x.addr === r.addr && x.name === r.name) !== i);
  if (dup) { toast('存在重复的寄存器标识符，请检查'); return; }
  // 32/64 位类型：寄存器个数必须是宽度的整数倍
  const W = { uint32: 2, int32: 2, float32: 2, uint64: 4, int64: 4, float64: 4 };
  for (const r of regs) {
    const w = W[r.dtype] || 1;
    if (r.count % w !== 0) {
      toast('「' + (r.name || r.addr) + '」' + r.dtype + ' 占 ' + w + ' 个寄存器，个数需为 ' + w + ' 的整数倍');
      return;
    }
  }
  try {
    cfg.regs = regs;
    await sendCmd(Protocol.Enc.writeCfg(cfg), 'CFG', 5000);
    S.cfg = cfg; S.regs = regs;
    status('配置已保存（串口参数变化时设备会自动重启轮询任务）', true);
    toast('保存成功');
    await readMode();
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

//---------------------------------------------------------------------
// 实时值
//---------------------------------------------------------------------
async function readVal() {
  try {
    const r = await sendCmd(Protocol.Enc.val(), 'VAL', 4000);
    const list = Array.isArray(r.data) ? r.data : [];
    const byName = {}, byAddr = {};
    list.forEach(it => {
      if (it.name) byName[it.name] = it;
      if (it.addr != null) byAddr[String(it.addr)] = it;
    });
    let hit = 0;
    el.paramTbody.querySelectorAll('tr').forEach(tr => {
      const name = tr.querySelector('.c-name').value.trim();
      const addr = parseInt(tr.querySelector('.c-addr').value, 10);
      const type = tr.querySelector('.c-type').value;
      const count = parseInt(tr.querySelector('.c-count').value, 10) || 1;
      const bo = tr.querySelector('.c-bo').value;
      const wo = tr.querySelector('.c-wo').value;
      const cell = tr.querySelector('.c-val');
      const it = (name && byName[name]) || byAddr[String(addr)];
      if (it) {
        hit++;
        // 设备已解好的值优先；只有给了原始 regs 时才前端重解
        if (it.regs && Array.isArray(it.regs)) {
          const vals = Protocol.decodeValues(it.regs, type, count, bo, wo);
          cell.value = vals.map(Protocol.fmt).join(', ');
        } else if (it.value !== undefined && it.value !== null) {
          cell.value = Protocol.fmt(it.value);
        } else if (it.hex) {
          cell.value = it.hex;      // 读失败时至少看到原始字节
        } else {
          cell.value = '';
        }
      } else {
        cell.value = '';
      }
    });
    if (hit === 0 && list.length === 0) {
      status('暂无数据：设备可能未进入轮询模式', false);
      toast('没有读到数据，请先在「运行模式」页进入轮询模式');
    } else {
      status('实时值已刷新（' + hit + '/' + S.regs.length + ' 点有值）', true);
    }
  } catch (e) {
    status('读取实时值失败：' + e.message, false);
    toast('读取实时值失败：' + e.message);
  }
}

//---------------------------------------------------------------------
// 寄存器表格
//---------------------------------------------------------------------
const ALL_TYPES = ['uint16', 'int16', 'uint32', 'int32', 'float32', 'uint64', 'int64', 'float64'];

function renderRegTable() {
  el.paramTbody.innerHTML = '';
  const rows = (S.regs && S.regs.length) ? S.regs : [];
  if (rows.length === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td colspan="9" style="color:#999;padding:14px;">暂无寄存器，点「新增寄存器」添加</td>';
    el.paramTbody.appendChild(tr);
    return;
  }
  rows.forEach(r => addRegRow(r.addr, r.dtype || r.type, r.name, r.alias, r.count,
                              r.byteOrder, r.wordOrder, r.eps));
}

function addRegRow(addr, type, name, alias, count, byteOrder, wordOrder, eps) {
  const tr = document.createElement('tr');
  const opts = ALL_TYPES
    .map(t => '<option' + (t === type ? ' selected' : '') + '>' + t + '</option>').join('');
  const boOpts = ['BE', 'LE']
    .map(t => '<option' + (t === (byteOrder || 'BE') ? ' selected' : '') + '>' + t + '</option>').join('');
  const woOpts = ['BE', 'LE']
    .map(t => '<option' + (t === (wordOrder || 'BE') ? ' selected' : '') + '>' + t + '</option>').join('');
  // 落盘阈值：0 / 空 = 每轮都存。只影响本地写入量，不影响实时值和上报
  const epsVal = (eps != null && !isNaN(eps)) ? eps : 0;
  tr.innerHTML =
    '<td><input class="c-addr" type="number" value="' + addr + '"></td>' +
    '<td><select class="c-type">' + opts + '</select></td>' +
    '<td><input class="c-count" type="number" value="' + (count || 1) + '" min="1" max="125"></td>' +
    '<td><input class="c-name" type="text" value="' + esc(name || '') + '"></td>' +
    '<td><input class="c-alias" type="text" value="' + esc(alias || '') + '" ' +
    'title="MQTT 上报 name 字段的中文名，留空则用标识符"></td>' +
    '<td><select class="c-bo">' + boOpts + '</select></td>' +
    '<td><select class="c-wo">' + woOpts + '</select></td>' +
    '<td><input class="c-eps" type="number" value="' + epsVal + '" min="0" step="any" ' +
    'title="值变化超过该值才写本地文件，0=每轮都存"></td>' +
    '<td class="val-cell"><input class="c-val" type="text" value="" readonly></td>' +
    '<td><button class="btn-del" onclick="deleteRow(this)">删除</button></td>';
  el.paramTbody.appendChild(tr);
}

function deleteRow(btn) { btn.closest('tr').remove(); }
function addParamRow() {
  $('regAddr').value = 1;
  $('regType').value = '';
  $('regId').value = '';
  $('regAlias').value = '';
  $('regCount').value = 1;
  $('regByteOrder').value = 'BE';
  $('regWordOrder').value = 'BE';
  $('regEps').value = 0;
  $('modalAddReg').style.display = 'flex';
}
function closeModal() { $('modalAddReg').style.display = 'none'; }
function confirmAddReg() {
  const addr = $('regAddr').value;
  const type = $('regType').value;
  const phyId = $('regId').value;
  const alias = $('regAlias').value.trim();
  const cnt = parseInt($('regCount').value, 10);
  const bo = $('regByteOrder').value;
  const wo = $('regWordOrder').value;
  let eps = parseFloat($('regEps').value);
  if (isNaN(eps) || eps < 0) eps = 0;
  if (!type) { alert('请选择数据类型'); return; }
  if (!addr || !cnt) { alert('寄存器地址、寄存器个数不能为空'); return; }
  const W = { uint32: 2, int32: 2, float32: 2, uint64: 4, int64: 4, float64: 4 };
  const w = W[type] || 1;
  if (cnt % w !== 0) { alert(type + ' 占 ' + w + ' 个寄存器，个数需为 ' + w + ' 的整数倍'); return; }
  addRegRow(parseInt(addr, 10), type, phyId, alias, cnt, bo, wo, eps);
  closeModal();
}

//=====================================================================
// 运行模式
//=====================================================================
function renderMode() {
  const st = S.modeStat || {};
  const devMode = st.mode || 'idle';        // 设备当前模式（权威）
  const shown = S.modePending || devMode;   // 有待应用选择时优先显示它
  S.mode = devMode;                         // S.mode 始终跟设备走，别处据此判断 sniff
  el.stMode.textContent = devMode;
  // 卡片选中态：有待应用选择就高亮它，否则高亮设备当前模式
  // 模式名直接从 k 推导（idle/poll/sniff），不读 data-mode 属性：
  // 少一次 DOM 读取，也不依赖属性是否被正确设置。
  ['Idle', 'Poll', 'Sniff'].forEach(k => {
    const dm = k.toLowerCase();       // idle / poll / sniff，与卡片 data-mode 一致
    const c = $('mc' + k);
    if (c) c.classList.toggle('active', dm === shown);
    // 卡片状态行：让用户看清"这是设备现状"还是"我选的还没应用"
    const stEl = $('ms' + k);
    if (stEl) {
      const isPending = S.modePending && dm === S.modePending && dm !== devMode;
      if (isPending) stEl.textContent = S.modeSwitching ? '切换中…' : '待应用';
      else if (dm === devMode) stEl.textContent = (devMode === 'idle' ? '当前' : '运行中');
      else stEl.textContent = '';
      stEl.classList.toggle('pending', !!isPending);
    }
    // 切换进行中给卡片加禁手型，避免用户连点
    if (c && c.classList.contains('switching') !== !!S.modeSwitching) {
      c.classList.toggle('switching', !!S.modeSwitching);
    }
  });

  const p = st.poll || {}, m = st.mon || {};
  // 写队列统计：设备在顶层给 write，兼容只有 poll.write 的老固件
  const w = st.write || p.write || {};
  // guard 段只在 R:STAT 顶层有，R:MODE 不返回 → 必须从 S.stat 取
  const g = (S.stat && S.stat.guard) || {};
  setKv('mCurMode', devMode);
  setKv('mBusy', st.busy ? '占用中' : '空闲');
  setKv('mSlave', p.slave);
  setKv('mBaud', p.baud);
  setKv('mInterval', p.interval != null ? p.interval + ' ms' : '');
  setKv('mRespCap', p.resp_cap != null ? p.resp_cap + ' ms' : '早返回');
  setKv('mRegCount', p.regs);
  setKv('mGen', p.gen);
  setKv('mWriteQ', (w.queued != null ? w.queued : 0) + ' / ' + (w.qmax != null ? w.qmax : 0));
  setKv('mWriteStat', (w.done != null ? w.done : 0) + ' 成功 / ' + (w.fail != null ? w.fail : 0) + ' 失败');
  setKv('mMonFrames', m.frames);
  setKv('mPaired', m.paired);
  setKv('mOrphan', m.orphans);
  setKv('mPending', m.pending);
  setKv('mReqRsp', (m.reqs != null ? m.reqs : 0) + ' / ' + (m.rsps != null ? m.rsps : 0));
  setKv('mUptime', g && g.uptime != null ? g.uptime + ' s' : '');
  setKv('mWdt', g.wdt_to ? (wdtStalled(g, !!p.running).stalled ? '停滞!' : '正常') : '未启用');
}

async function readMode() {
  try {
    const r = await sendCmd(Protocol.Enc.mode(), 'MODE');
    S.modeStat = r.data;
    renderMode();
  } catch (e) {
    setKv('mCurMode', '读取失败', true);
  }
}

async function applyMode(mode) {
  // 切换进行中再点，忽略（避免连点把设备和 UI 搞乱）
  if (S.modeSwitching) return;
  S.modeSwitching = true;
  S.modePending = mode;          // 先记下用户所选，防止 5s 定时刷新把高亮打回旧模式
  renderMode();
  try {
    status('正在切换模式到 ' + mode + ' …', true);
    await sendCmd(Protocol.Enc.setMode(mode), 'MODE', 8000);
    await readMode();            // 设备已确认，读回真实状态
    S.modePending = null;        // 确认成功，清除待应用标记
    renderMode();
    await readHome();
    status('已切换到 ' + mode + ' 模式', true);
    toast('模式已切换：' + mode);
  } catch (e) {
    // 失败：放弃待应用选择，让界面回到设备真实模式
    S.modePending = null;
    renderMode();
    status('切换失败：' + e.message, false);
    toast('切换失败：' + e.message);
    readMode();
  } finally {
    S.modeSwitching = false;
  }
}

async function saveBootMode() {
  const v = el.selBootMode.value;
  try {
    await sendCmd(Protocol.Enc.bootMode(v), 'BOOTMODE');
    status('开机默认模式已设为 ' + v + '（重启后生效）', true);
    toast('开机默认模式：' + v);
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

//=====================================================================
// 首页状态总览
//=====================================================================
function renderHome() {
  // mode 段（mode/busy/poll/mon）来自 R:MODE 或 R:STAT.mode；
  // data/guard/store 三段只在 R:STAT 顶层，R:MODE 不返回，必须从 S.stat 取。
  const st   = S.modeStat || {};
  const full = S.stat || {};
  const p = st.poll || {}, m = st.mon || {}, d = full.data || {}, g = full.guard || {};
  const mq = (S.mqtt && S.mqtt.stat) || {};
  setKv('hMode', (st.mode || 'idle') + (st.busy ? '（占用总线）' : ''));
  setKv('hPoll', p.running ? '运行中' : '未运行');
  setKv('hRegs', p.regs);
  setKv('hPoints', d.points);
  setKv('hMqtt', mq.connected ? '已连接' : '未连接', !mq.connected);
  setKv('hDevId', mq.device_id || (mq.sn || ''));
  setKv('hWdt', g.wdt_to ? (wdtStalled(g, !!p.running).stalled ? '停滞!' : '正常') : '未启用',
        wdtStalled(g, !!p.running).stalled);
  setKv('hPub', mq.published);
  // 本地落盘：累计写入条数 + 当前保留轮数；关开关时明确告知
  // ⚠️ 变量名不能用 st：上面已有 const st = S.modeStat || {}，同名会
  //    "Identifier 'st' has already been declared" 直接语法错误
  const stStore = full.store || {};
  if (stStore.saved != null) {
    const extra = (stStore.rounds != null)
      ? '（保留 ' + stStore.rounds + ' 轮 / ' + stStore.recs + ' 条）' : '';
    setKv('hStore', stStore.saved + ' 条' + (stStore.enable === false ? '（已暂停）' : extra),
          stStore.enable === false);
  } else {
    setKv('hStore', '');
  }
  // 落盘开关复选框：以设备返回的 enable 为准（避免前端猜）
  if (typeof stStore.enable === 'boolean' && el.swStoreOn) {
    el.swStoreOn.checked = stStore.enable;
  }
  setKv('hFrames', m.frames);
  el.stMqtt.textContent = mq.connected ? '已连接' : '未连接';
  el.stMqtt.style.color = mq.connected ? '#0a7d2c' : '#999';
}

async function readHome() {
  try {
    const r = await sendCmd(Protocol.Enc.stat(), 'STAT', 4000);
    // R:STAT 一次性返回 mode/data/guard/store/mqtt 五个平级段。
    // ⚠️ 以前这里只 S.modeStat = r.data.mode，把 data/guard/store 全丢了，
    //    导致首页"看门狗"永远显示未启用、"数据点数"永远 --、"本地落盘"永远空。
    if (r.data) {
      S.stat = r.data;                                   // 完整五段，首页要用
      if (r.data.mode) {
        S.modeStat = r.data.mode;                        // mode 段单独给 renderMode 用
      }
      if (r.data.mqtt) S.mqtt = Object.assign({}, S.mqtt, { stat: r.data.mqtt });
      renderMode();
    }
    renderHome();
  } catch (e) { /* 首页刷新失败不打扰用户 */ }
}

//=====================================================================
// MQTT 配置
//=====================================================================
function renderMqtt() {
  const r = S.mqtt || {};
  const c = r.cfg || {};
  if (c.host !== undefined) {
    el.mqHost.value = c.host || '';
    el.mqPort.value = c.port != null ? c.port : 1883;
    el.mqSsl.checked = !!c.ssl;
    el.mqUser.value = c.user || '';
    el.mqPass.value = c.pass || '';
    el.mqClientId.value = c.client_id || '';
    el.mqPub.value = c.pub_topic || '';
    el.mqSub.value = c.sub_topic || '';
    el.mqInterval.value = c.interval_s != null ? c.interval_s : 60;
    // QoS 已从界面移除：设备端发布/订阅固定用 QoS 1，
    // 这里不再显示也不再下发（设备 normalize 会退回默认值 1）。
    el.mqAllowNoSn.checked = !!c.allow_no_sn;
    // MQTT 会话管理（select）：'1'=持久会话  '0'=离线自动销毁（默认）
    el.mqKeepSession.value = c.keep_session ? '1' : '0';
  }
  const s = r.stat || {};
  setKv('mqStConn', s.connected ? '已连接' : (s.want_run ? '连接中/已断开' : '未启动'), !s.connected);
  setKv('mqStClientId', s.client_id || s.device_id || s.sn || '');
  setKv('mqStDevId', s.device_id || s.sn || '');
  setKv('mqStPub', r.pub || '');
  setKv('mqStSub', r.sub || '');
  setKv('mqStSubed', s.subscribed ? '是' : '否', !s.subscribed);
  setKv('mqStPubed', s.published);
  setKv('mqStFailed', s.failed, s.failed > 0);
  setKv('mqStLast', s.last_pub ? new Date(s.last_pub * 1000).toLocaleTimeString() : '');
  setKv('mqStBackoff', s.backoff != null ? s.backoff + ' s' : '');
  setKv('mqStKeepSession',
        s.keep_session == null ? '--' : (s.keep_session ? '持久会话' : '离线自动销毁'));
  setKv('mqStErr', s.last_err || '', !!s.last_err);
  setKv('mqStSn', r.ready ? '已烧号' : (r.err || '未烧号'), !r.ready);
  renderHome();
}

async function readMqtt() {
  try {
    const r = await sendCmd(Protocol.Enc.mqtt(), 'MQTT');
    S.mqtt = r.data;
    renderMqtt();
  } catch (e) {
    setKv('mqStErr', '读取失败：' + e.message, true);
  }
}

async function saveMqtt() {
  const host = el.mqHost.value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  // {id} 只是推荐（多台设备不撞 topic）。平台若要求固定格式
  // （如 /12/<sn>/property/post），用户直接把 SN 写进 topic 也放行。
  if (el.mqPub.value.indexOf('{id}') < 0 && el.mqSub.value.indexOf('{id}') < 0) {
    if (!confirm('发布/订阅 Topic 都不含 {id} 占位符。\n若 topic 里没写设备 SN，多台设备会共用同一 topic 导致数据互相覆盖。\n确定继续吗？')) return;
  }
  const cfg = {
    host: host,
    port: parseInt(el.mqPort.value, 10) || 1883,
    ssl: el.mqSsl.checked,
    user: el.mqUser.value.trim(),
    pass: el.mqPass.value,
    client_id: el.mqClientId.value.trim(),
    pub_topic: el.mqPub.value.trim() || 'vkbox/{id}/up',
    sub_topic: el.mqSub.value.trim() || 'vkbox/{id}/down',
    interval_s: parseInt(el.mqInterval.value, 10) || 0,
    // QoS 界面已移除，不再下发；设备端固定用 QoS 1
    allow_no_sn: el.mqAllowNoSn.checked,
    // select: '1'=持久会话  '0'=离线自动销毁（默认）
    keep_session: el.mqKeepSession.value === '1'
  };
  try {
    await sendCmd(Protocol.Enc.writeMqtt(cfg), 'MQTT', 5000);
    status('MQTT 配置已保存，设备正在重连', true);
    toast('已保存，设备重连中');
    await new Promise(res => setTimeout(res, 1500));
    await readMqtt();
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

async function reportNow() {
  try {
    await sendCmd(Protocol.Enc.report(), 'REPORT', 5000);
    status('已触发一次上报', true);
    toast('已上报');
    await readMqtt();
  } catch (e) {
    status('上报失败：' + e.message, false);
    toast('上报失败：' + e.message);
  }
}

//=====================================================================
// 实时报文（sniff）
//=====================================================================
function frameMatches(f) {
  const sel = el.frameFilter.value;
  if (!sel) return true;
  if (sel === 'paired' || sel === 'orphan') return f.pair_state === sel;
  return f.kind === sel;
}

function renderFrames() {
  const list = S.frames.filter(frameMatches);
  if (list.length === 0) {
    el.frameLog.innerHTML = '<div class="frame-line"><span class="fl-desc">' +
      (S.frames.length ? '没有符合筛选条件的报文' : '暂无报文 —— 切到「运行模式」页进入旁听模式后，这里会实时显示总线报文') +
      '</span></div>';
    return;
  }
  el.frameLog.innerHTML = list.map(f => {
    const t = f.ts ? new Date(f.ts * 1000).toLocaleTimeString() : '';
    const dirCls = f.kind === 'err' ? 'err' : (f.kind || 'other');
    const dirTxt = f.kind === 'req' ? 'REQ ' : f.kind === 'rsp' ? 'RSP ' :
                   f.kind === 'err' ? 'ERR ' : f.kind === 'echo' ? 'ECHO' : 'FRM ';
    let desc;
    if (f.kind === 'req') {
      desc = '从机 ' + f.slave + ' 功能码 0x' + (f.fc != null ? f.fc.toString(16).padStart(2, '0').toUpperCase() : '??') +
             ' 读地址 ' + f.addr + ' 数量 ' + f.qty;
    } else if (f.kind === 'rsp') {
      desc = '从机 ' + f.slave + ' 字节数 ' + (f.bc || 0) + ' 值 [' + (f.vhex || '') + ']';
    } else if (f.kind === 'err') {
      desc = '从机 ' + f.slave + ' 异常码 0x' + (f.exception != null ? f.exception.toString(16).padStart(2, '0').toUpperCase() : '??');
    } else if (f.kind === 'echo') {
      desc = '从机 ' + f.slave + ' 回显 地址 ' + f.addr + ' 值 ' + (f.value != null ? f.value : '');
    } else {
      desc = '从机 ' + f.slave + ' 长度 ' + (f.len || 0) + ' 字节';
    }
    const pair = f.paired_addr != null ? ('← 配对 addr=' + f.paired_addr) :
                 (f.pair_state === 'orphan' ? '← 未配对（无在途请求）' : '');
    return '<div class="frame-line">' +
      '<span class="fl-time">' + esc(t) + '</span>' +
      '<span class="fl-dir ' + dirCls + '">' + dirTxt + '</span>' +
      '<span class="fl-hex">' + esc(f.hex || '') + '</span>' +
      '<span class="fl-desc">' + esc(desc) + '</span>' +
      '<span class="fl-pair">' + esc(pair) + '</span>' +
      '</div>';
  }).join('');
}

async function readFrames() {
  try {
    const r = await sendCmd(Protocol.Enc.frames(30), 'FRAMES', 4000);
    S.frames = Array.isArray(r.data) ? r.data : [];
    renderFrames();
  } catch (e) { /* 静默：可能未进 sniff 模式 */ }
}

async function doInfer() {
  try {
    const r = await sendCmd(Protocol.Enc.infer(), 'INFER', 4000);
    S.infer = r.data;
    renderInfer();
    if (S.infer && S.infer.regs && S.infer.regs.length) {
      status('推断出 ' + S.infer.regs.length + ' 个轮询项', true);
      toast('推断完成，可点「应用到轮询配置」');
    } else {
      status('未监听到请求帧，先在旁听模式下观察一段时间', false);
      toast('还没有监听到请求帧');
    }
  } catch (e) {
    status('推断失败：' + e.message, false);
    toast('推断失败：' + e.message);
  }
}

function renderInfer() {
  const inf = S.infer || {};
  const regs = inf.regs || [];
  el.inferHint.textContent = regs.length
    ? '监听到 ' + (inf.slaves || []).length + ' 个从机，共 ' + regs.length + ' 个轮询项'
    : '';
  if (regs.length === 0) {
    el.inferTbody.innerHTML = '<tr><td colspan="6" style="color:#999;">暂无推断结果</td></tr>';
    return;
  }
  el.inferTbody.innerHTML = regs.map(r =>
    '<tr>' +
    '<td>' + esc(r.slave) + '</td>' +
    '<td>' + esc(r.addr) + '</td>' +
    '<td>' + esc(r.count) + '</td>' +
    '<td>0x' + (r.fc != null ? r.fc.toString(16).padStart(2, '0').toUpperCase() : '?') + '</td>' +
    '<td>' + esc(r.hits) + '</td>' +
    '<td>s' + esc(r.slave) + '_r' + esc(r.addr) + '</td>' +
    '</tr>'
  ).join('');
}

async function applyInfer() {
  try {
    await sendCmd(Protocol.Enc.applyInfer(), 'APPLYINFER', 5000);
    status('推断结果已写入轮询配置', true);
    toast('已应用到轮询配置');
    await readCfg();
  } catch (e) {
    status('应用失败：' + e.message, false);
    toast('应用失败：' + e.message);
  }
}

//---------------------------------------------------------------------
// 总线诊断
//---------------------------------------------------------------------
async function busSniff() {
  const ms = parseInt(el.busSniffMs.value, 10) || 3000;
  try {
    status('正在静默侦听总线 ' + ms + 'ms …', true);
    const r = await sendCmd(Protocol.Enc.sniffBus(ms), 'SNIFF', ms + 4000);
    const n = parseInt(r.data, 10);
    status('侦听完成：收到 ' + n + ' 帧', n > 0);
    toast('收到 ' + n + ' 帧' + (n > 0 ? '（DE 收发切换与发送链路正常）' : '（总线上无数据）'));
  } catch (e) {
    status('侦听失败：' + e.message, false);
    toast('侦听失败：' + e.message);
  }
}

async function txHex() {
  const hex = el.txHex.value.trim();
  if (!hex) { toast('请输入要发送的十六进制字节，如 01 03 00 00 00 0A C5 CD'); return; }
  if (!/^([0-9A-Fa-f]{2}\s*)+$/.test(hex)) { toast('格式错误：只能含十六进制字节，用空格分隔'); return; }
  try {
    status('正在发送 ' + hex + ' …', true);
    await sendCmd(Protocol.Enc.txHex(hex), 'TX', 3000);
    status('已发送（DE 自动切换）', true);
    toast('发送成功');
    setTimeout(readFrames, 300);
  } catch (e) {
    status('发送失败：' + e.message, false);
    toast('发送失败：' + e.message);
  }
}

//---------------------------------------------------------------------
// 导入 / 导出配置（JSON 文件）
//---------------------------------------------------------------------
function exportCfg() {
  const c = collectCfg();
  if (!c.ok) { toast('当前表单配置无效，无法导出：' + c.err); return; }
  const data = {
    tool: 'VKBox配置工具', version: '2.0.0',
    exported: new Date().toISOString(),
    serial: c.cfg,
    registers: collectRegs(),
    mqtt: {
      host: el.mqHost.value.trim(), port: parseInt(el.mqPort.value, 10) || 1883,
      ssl: el.mqSsl.checked, user: el.mqUser.value.trim(),
      client_id: el.mqClientId.value.trim(),
      pub_topic: el.mqPub.value.trim(), sub_topic: el.mqSub.value.trim(),
      interval_s: parseInt(el.mqInterval.value, 10) || 0,
      allow_no_sn: el.mqAllowNoSn.checked,
      keep_session: el.mqKeepSession.value === '1'
    }
  };
  const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'vkbox_config_' + new Date().toISOString().slice(0, 10) + '.json';
  a.click();
  URL.revokeObjectURL(a.href);
  toast('配置已导出');
}

function importCfg() {
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = '.json,application/json';
  inp.onchange = () => {
    const f = inp.files && inp.files[0];
    if (!f) return;
    const rd = new FileReader();
    rd.onload = () => {
      try {
        const d = JSON.parse(rd.result);
        const c = d.serial || d.cfg || {};
        if (c.baud) el.selBaud.value = String(c.baud);
        if (c.databits) setRadio('databits', String(c.databits));
        if (c.parity != null) setRadio('parity', String(c.parity));
        if (c.stopbits) setRadio('stopbits', String(c.stopbits));
        if (c.interval_ms) el.inpRound.value = c.interval_ms;
        if (c.slave) el.inpSlave.value = c.slave;
        el.inpTimeout.value = (c.timeout_ms == null || c.timeout_ms === '') ? '' : c.timeout_ms;
        if (c.server) el.fUrl.value = c.server;
        const regs = d.registers || d.regs || [];
        S.regs = regs;
        renderRegTable();
        if (d.mqtt) {
          el.mqHost.value = d.mqtt.host || '';
          el.mqPort.value = d.mqtt.port || 1883;
          el.mqSsl.checked = !!d.mqtt.ssl;
          el.mqUser.value = d.mqtt.user || '';
          el.mqPass.value = d.mqtt.pass || '';
          el.mqClientId.value = d.mqtt.client_id || '';
          el.mqPub.value = d.mqtt.pub_topic || '';
          el.mqSub.value = d.mqtt.sub_topic || '';
          el.mqInterval.value = d.mqtt.interval_s != null ? d.mqtt.interval_s : 60;
          // QoS 界面已移除；老配置文件里若还带 qos 字段，忽略
          el.mqAllowNoSn.checked = !!d.mqtt.allow_no_sn;
          el.mqKeepSession.value = d.mqtt.keep_session ? '1' : '0';
        }
        toast('配置已导入：' + regs.length + ' 个寄存器');
      } catch (e) {
        toast('导入失败：不是合法的 JSON 配置文件');
      }
    };
    rd.readAsText(f);
  };
  inp.click();
}

//---------------------------------------------------------------------
// 自动刷新（报文页 + 首页定时）
//---------------------------------------------------------------------
let frameTimer = null, homeTimer = null;
function startAutoRefresh() {
  stopAutoRefresh();
  if (S.mock) return;
  homeTimer = setInterval(() => { if (!S.pending) readHome(); }, 5000);
  frameTimer = setInterval(() => {
    if (!S.pending && el.frameAuto.checked && S.mode === 'sniff') readFrames();
  }, 2000);
}
function stopAutoRefresh() {
  if (frameTimer) { clearInterval(frameTimer); frameTimer = null; }
  if (homeTimer) { clearInterval(homeTimer); homeTimer = null; }
}

//---------------------------------------------------------------------
// 事件绑定与初始化
//---------------------------------------------------------------------
el.btnRefresh.onclick = refreshPorts;
el.btnOpen.onclick = togglePort;
el.btnReadInfo.onclick = readInfo;
el.btnReadCfg.onclick = readCfg;
el.btnSaveCfg.onclick = saveCfg;
el.btnReadVal.onclick = readVal;
el.btnAddReg.onclick = addParamRow;
el.btnImport.onclick = importCfg;
el.btnExport.onclick = exportCfg;
el.comSel.onchange = () => { S.port = el.comSel.value; };

// 首页
el.btnHomeRefresh.onclick = async () => { await readHome(); await readMode(); await readMqtt(); };
el.btnQuickPoll.onclick = () => applyMode('poll');
el.btnQuickSniff.onclick = () => applyMode('sniff');
el.btnQuickStop.onclick = () => applyMode('stop');
el.btnQuickReport.onclick = reportNow;

// 本地存储开关：运行时立即生效；"保存"才写 fskv 重启后仍生效
//   store_enable 由 R:STAT.store 带回来（设备端 stats 里没有单独字段，
//   所以在 readHome 里从 R:DISK 之外的来源拿不到时保持复选框不动）
el.swStoreOn.onchange = async () => {
  const on = el.swStoreOn.checked;
  try {
    await sendCmd(Protocol.Enc.store(on, false), 'STORE', 4000);
    status('本地落盘已' + (on ? '开启' : '关闭') + '（重启后恢复默认，需点保存才持久化）', true);
    await readHome();
  } catch (e) {
    el.swStoreOn.checked = !on;      // 失败回滚勾选
    status('切换落盘开关失败：' + e.message, false);
  }
};
el.btnStoreSave.onclick = async () => {
  const on = el.swStoreOn.checked;
  try {
    await sendCmd(Protocol.Enc.store(on, true), 'STORE', 4000);
    status('本地落盘设置已保存（重启仍生效）', true);
    toast('落盘开关已持久化：' + (on ? '开' : '关'));
  } catch (e) {
    status('保存失败：' + e.message, false);
  }
};
el.btnQuickRst.onclick = async () => {
  if (!confirm('确定恢复默认配置？\n将清空设备保存的 485 配置、MQTT 配置和本地缓存数据。')) return;
  try {
    await sendCmd(Protocol.Enc.rst(), 'RST', 6000);
    status('已恢复默认配置', true);
    toast('已恢复默认配置');
    await readCfg(); await readMqtt(); await readMode();
  } catch (e) {
    status('恢复失败：' + e.message, false);
    toast('恢复失败：' + e.message);
  }
};

// 运行模式页
el.btnModeRefresh.onclick = readMode;
el.btnSaveBoot.onclick = saveBootMode;
// 点卡片 = 弹窗确认后立即切换（"应用所选模式"按钮已去掉，卡片即操作）。
// 之前只切高亮不发命令，5s 定时刷新一到就把高亮打回旧模式，
// 表现为"选中后模式自动跳回原来模式"。
// 卡片区域大、容易误点，切换又要停掉旧模式，所以必须弹窗确认。
const MODE_LABEL = { idle: '空闲 idle', poll: '轮询 poll', sniff: '旁听 sniff' };
document.querySelectorAll('.mode-card').forEach(c => {
  c.onclick = () => {
    const m = c.getAttribute('data-mode');
    // 点的就是设备当前模式且没有待应用选择：只重绘，不发命令、不弹窗
    if (m === S.mode && !S.modePending) { renderMode(); return; }
    // 切换中忽略连点（applyMode 内部也有同样的保护）
    if (S.modeSwitching) return;
    const label = MODE_LABEL[m] || m;
    const curLabel = MODE_LABEL[S.mode] || S.mode;
    if (!confirm('确定把 485 运行模式从「' + curLabel + '」切换到「' + label + '」？\n\n'
                 + '切换时设备会先停掉旧模式再启动新模式（互斥），'
                 + '正在进行的采集会中断。')) return;
    applyMode(m);
  };
});
// MQTT 页
el.btnMqttRefresh.onclick = readMqtt;
el.btnMqttSave.onclick = saveMqtt;
el.btnMqttReport.onclick = reportNow;
el.btnMqttReset.onclick = async () => {
  if (!confirm('确定恢复 MQTT 默认配置？')) return;
  el.mqHost.value = 'test.mosquitto.org';
  el.mqPort.value = 1883;
  el.mqSsl.checked = false;
  el.mqUser.value = '';
  el.mqPass.value = '';
  el.mqClientId.value = '';
  el.mqPub.value = 'vkbox/{id}/up';
  el.mqSub.value = 'vkbox/{id}/down';
  el.mqInterval.value = 60;
  // QoS 界面已移除，不再重置
  el.mqAllowNoSn.checked = false;
  el.mqKeepSession.value = '0';     // 离线自动销毁（与设备默认一致）
  await saveMqtt();
};

// 报文页
el.btnFrameRefresh.onclick = readFrames;
el.btnFrameClear.onclick = () => { S.frames = []; renderFrames(); };
el.frameFilter.onchange = renderFrames;
el.btnInfer.onclick = doInfer;
el.btnApplyInfer.onclick = applyInfer;
el.btnBusSniff.onclick = busSniff;
el.btnTx.onclick = txHex;

// 主标签页切换
const tabItems = document.querySelectorAll('.tab-header .tab-item');
tabItems.forEach(item => {
  item.onclick = function () {
    tabItems.forEach(t => t.classList.remove('active'));
    this.classList.add('active');
    const tabId = this.getAttribute('data-tab');
    document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
    $(tabId).classList.add('active');
    // 切到报文页时立即拉一次
    if (tabId === 'tabSniff' && S.open && S.mode === 'sniff') readFrames();
  };
});

// poll模式子标签切换：串口1（485总线）/ MQTT配置
const serialTabs = document.querySelectorAll('.serial-tab');
serialTabs.forEach(tab => {
  tab.onclick = () => {
    serialTabs.forEach(s => s.classList.remove('active'));
    tab.classList.add('active');
    const key = tab.getAttribute('data-serial');   // s1 / s2
    document.querySelectorAll('.serial-pane').forEach(p => p.classList.remove('active'));
    const pane = document.getElementById('sp-' + key);
    if (pane) pane.classList.add('active');
    // 切到 MQTT配置 时拉一次，避免刚切过去是空的
    if (key === 's2' && S.open) readMqtt();
  };
});

// 串口接收
// ⚠️ mock 分支也要调 onLine：否则 __mockOnLine 永远是 null，
//    浏览器预览模式下所有指令都等不到应答（必然超时）。
if (window.serial) {
  window.serial.onLine(onSerialLine);
  window.serial.onClosed(() => { stopAutoRefresh(); setPortState(false, ''); status('串口已断开', false); });
  window.serial.onError(m => { status('串口错误：' + m, false); });
} else {
  // mock：模拟设备应答，便于浏览器里联调界面
  window.serial = {
    list: async () => ({ ok: true, ports: [{ path: 'MOCK', label: 'MOCK（浏览器预览）' }] }),
    open: async () => ({ ok: true }),
    close: async () => ({ ok: true }),
    isOpen: async () => true,
    send: async (line) => {
      console.log('[mock tx]', line);
      setTimeout(() => mockReply(line), 120);
      return { ok: true };
    },
    onLine: cb => { window.__mockOnLine = cb; return () => {}; },
    onClosed: () => () => {},
    onError: () => () => {}
  };
  // 关键：mock 对象建好后必须立刻挂上接收回调
  window.serial.onLine(onSerialLine);
}

// mock 设备状态：切模式 / 保存配置后要能反映出来，否则预览时
// 状态永远是初始值，看不出交互效果
const MOCK = {
  mode: 'idle',
  cfg: {
    baud: 9600, databits: 8, parity: 0, stopbits: 1, slave: 1,
    interval_ms: 3000, timeout_ms: null,
    regs: [
      { addr: 0, count: 2, name: 'sensor1', alias: '传感器1', dtype: 'uint16', byteOrder: 'BE', wordOrder: 'BE' },
      { addr: 2, count: 2, name: 'sensor2', alias: '传感器2', dtype: 'int16', byteOrder: 'BE', wordOrder: 'BE' },
      { addr: 4, count: 2, name: 'temp', alias: '温度', dtype: 'float32', byteOrder: 'BE', wordOrder: 'BE' }
    ]
  },
  mqtt: { host: 'test.mosquitto.org', port: 1883, user: '', pass: '', ssl: false,
          pub_topic: 'vkbox/{id}/up', sub_topic: 'vkbox/{id}/down',
          interval_s: 60, allow_no_sn: false, keep_session: false },
  published: 0
};

function mockModeStat() {
  const m = MOCK.mode;
  return {
    mode: m, busy: m !== 'stop' && m !== 'idle',
    poll: { running: m === 'poll', gen: m === 'poll' ? 1 : 0, regs: MOCK.cfg.regs.length,
            slave: MOCK.cfg.slave, baud: MOCK.cfg.baud, interval: MOCK.cfg.interval_ms,
            resp_cap: MOCK.cfg.timeout_ms == null ? 500 : MOCK.cfg.timeout_ms,
            write: { queued: 0, done: 0, fail: 0, last_err: '', qmax: 8 } },
    mon: { running: m === 'sniff', gen: m === 'sniff' ? 1 : 0, baud: MOCK.cfg.baud,
           frames: m === 'sniff' ? 24 : 0, reqs: m === 'sniff' ? 12 : 0,
           rsps: m === 'sniff' ? 11 : 0, errs: 0, paired: m === 'sniff' ? 10 : 0,
           orphans: m === 'sniff' ? 1 : 0, pending: 0, last_rx: 0, buf: 0 },
    // 与设备 485_ctrl.status() 对齐：写队列统计在顶层
    write: { queued: 0, done: 0, fail: 0, last_err: '', qmax: 8 }
  };
}

function mockReply(line) {
  let resp = 'RET:FAIL:unknown cmd';
  if (line === 'R:INFO') resp = 'RET:INFO=' + JSON.stringify({
    sn: 'VK20260925001', imei: '860000000000000', iccid: '89860000000000000000',
    csq: 28, rsrp: -88, version: '1.0.0', project: 'vkbox_485_collect',
    server: 'iot.example.com', baud: MOCK.cfg.baud, slave: MOCK.cfg.slave,
    regs: MOCK.cfg.regs.length, lock: 1
  });
  else if (line === 'R:CFG') resp = 'RET:CFG=' + JSON.stringify({ cfg: MOCK.cfg, src: 'fskv' });
  else if (line === 'R:REG') resp = 'RET:REG=' + JSON.stringify(MOCK.cfg.regs);
  else if (line === 'R:VAL') {
    const list = MOCK.cfg.regs.map(r => {
      if (r.dtype === 'float32') return { name: r.name, addr: r.addr, value: 23.5, hex: '41BC0000', ts: 0, dtype: r.dtype };
      if (r.dtype === 'int16')  return { name: r.name, addr: r.addr, value: -12, hex: 'FFF4FFF4', ts: 0, dtype: r.dtype };
      return { name: r.name, addr: r.addr, value: 0, hex: '00000000', ts: 0, dtype: r.dtype };
    });
    resp = 'RET:VAL=' + JSON.stringify(list);
  }
  else if (line === 'R:MODE') resp = 'RET:MODE=' + JSON.stringify(mockModeStat());
  else if (line === 'R:SNIFFCFG') resp = 'RET:SNIFFCFG=' + JSON.stringify({
    cfg: { baud: MOCK.cfg.baud, databits: MOCK.cfg.databits,
           parity: MOCK.cfg.parity, stopbits: MOCK.cfg.stopbits }, src: 'fskv'
  });
  else if (line === 'R:MQTT') resp = 'RET:MQTT=' + JSON.stringify({
    cfg: MOCK.mqtt, pub: 'vkbox/VK20260925001/up', sub: 'vkbox/VK20260925001/down',
    ready: true, err: null,
    stat: { want_run: true, connected: true, subscribed: true,
            device_id: 'VK20260925001', published: MOCK.published,
            failed: 0, last_pub: 0, last_err: '', backoff: 1, dirty: false,
            sn: 'VK20260925001' }
  });
  else if (line === 'R:IOTSTAT') resp = 'RET:IOTSTAT=' + JSON.stringify({
    connected: true, published: MOCK.published, failed: 0, last_err: ''
  });
  else if (line === 'R:STAT') resp = 'RET:STAT=' + JSON.stringify({
    mode: mockModeStat(),
    data: { pushed: MOCK.cfg.regs.length, frames: 24, raw: 24, points: MOCK.cfg.regs.length, ring: 50 },
    guard: { uptime: 42, feed: 7, stall: false, wdt_to: 9000 },
    store: { pushed: 12, popped: 12, dropped: 0, saved: 12, failed: 0, boots: 1 },
    mqtt: { connected: true, published: MOCK.published, failed: 0, last_err: '' }
  });
  else if (line === 'R:FRAMES' || line.indexOf('R:FRAMES=') === 0) resp = 'RET:FRAMES=' + JSON.stringify([
    { slave: 1, fc: 3, kind: 'req', addr: 100, qty: 2, hex: '01 03 00 64 00 02', len: 8, pair_state: 'req' },
    { slave: 1, fc: 3, kind: 'rsp', bc: 4, vhex: '0000002A', hex: '01 03 04 00 00 00 2A', len: 9, pair_state: 'paired', paired_addr: 100 },
    { slave: 2, fc: 3, kind: 'req', addr: 0, qty: 10, hex: '02 03 00 00 00 0A', len: 8, pair_state: 'req' },
    { slave: 2, fc: 3, kind: 'rsp', bc: 20, vhex: '0001000200030004', hex: '02 03 14 00 01 …', len: 25, pair_state: 'orphan' }
  ]);
  else if (line === 'R:INFER') resp = 'RET:INFER=' + JSON.stringify({
    regs: [
      { slave: 1, addr: 100, count: 2, fc: 3, hits: 12 },
      { slave: 2, addr: 0, count: 10, fc: 3, hits: 5 }
    ],
    slaves: [1, 2],
    stat: { frames: 24, reqs: 12, rsps: 11, errs: 0, paired: 10, orphans: 1 }
  });
  else if (line.indexOf('R:SNIFF=') === 0) resp = 'RET:SNIFF=3';
  else if (line.indexOf('W:TX=') === 0) resp = 'RET:TX=OK';
  else if (line.indexOf('W:MODE=') === 0) {
    MOCK.mode = line.slice(7);
    resp = 'RET:MODE=OK';
  }
  else if (line.indexOf('W:BOOTMODE=') === 0) resp = 'RET:BOOTMODE=OK';
  else if (line.indexOf('W:CFG=') === 0) {
    try {
      const o = JSON.parse(line.slice(6));
      Object.assign(MOCK.cfg, o);
      resp = 'RET:CFG=OK';
    } catch (e) { resp = 'RET:FAIL:CFG:bad json'; }
  }
  else if (line.indexOf('W:REG=') === 0) {
    try {
      const a = JSON.parse(line.slice(6));
      if (Array.isArray(a)) { MOCK.cfg.regs = a; resp = 'RET:REG=OK'; }
      else resp = 'RET:FAIL:REG:not array';
    } catch (e) { resp = 'RET:FAIL:REG:bad json'; }
  }
  else if (line.indexOf('W:WRITE=') === 0) resp = 'RET:WRITE=OK';
  else if (line.indexOf('W:WRITEJ=') === 0) resp = 'RET:WRITEJ=OK';
  else if (line.indexOf('W:MQTT=') === 0) {
    try {
      const o = JSON.parse(line.slice(7));
      Object.assign(MOCK.mqtt, o);
      resp = 'RET:MQTT=OK';
    } catch (e) { resp = 'RET:FAIL:MQTT:bad json'; }
  }
  else if (line === 'R:REPORT') { MOCK.published++; resp = 'RET:REPORT=OK'; }
  else if (line === 'W:APPLYINFER') {
    MOCK.cfg.regs = [
      { slave: 1, addr: 100, count: 2, fc: 3, hits: 12 },
      { slave: 2, addr: 0, count: 10, fc: 3, hits: 5 }
    ].map(r => ({ addr: r.addr, count: r.count, name: 's' + r.slave + '_r' + r.addr,
                  dtype: 'uint16', byteOrder: 'BE', wordOrder: 'BE' }));
    resp = 'RET:APPLYINFER=OK';
  }
  else if (line === 'W:RST') {
    MOCK.mode = 'idle';
    resp = 'RET:RST=OK';
  }
  if (window.__mockOnLine) window.__mockOnLine(resp);
}

// 初始化
refreshPorts();
setPortState(false, '');
renderRegTable();
renderMode();
renderHome();
renderFrames();
status('请选择串口并打开', true);
