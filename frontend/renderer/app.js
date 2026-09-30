//=====================================================================
// app.js - 渲染进程业务逻辑
// 依赖：protocol.js（Protocol 全局）、window.serial（preload 暴露）
// 浏览器预览模式：无 window.serial 时自动启用 mock，不影响界面联调
//
// 页面分工：
//   首页       —— 运行状态总览 + MQTT 服务器
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
  regs: [],            // 寄存器表 [{addr,count,name,alias,dtype}]
  cfgSnap: null,       // 485 表单+参数表上次「干净」状态的归一化快照（null = 无基线）
  cfgDirty: false,     // 485 表单是否有未保存改动
  mqSnap: null,        // MQTT 表单+首页 3 个 MQTT 输入框上次「干净」快照
  mqDirty: false,      // MQTT 配置是否有未保存改动
  mode: 'idle',        // 当前 485 运行模式（始终跟随设备，不被用户选择污染）
  modeStat: null,      // R:MODE 返回的完整状态
  modePending: null,   // 用户已选但设备尚未确认的模式；null = 无待应用选择
  modeSwitching: false,// 是否正在切换模式（防连点）
  stat: null,          // R:STAT 的完整负载 {mode,data,guard,mqtt} 四段平级。
                       // ⚠️ 不能只存 r.data.mode：data/guard 两段会被丢掉，
                       //    首页"看门狗/数据点数"会永远显示未启用/--。
  mqtt: null,          // R:MQTT 返回的状态
  mqManual: false,     // MQTT topic 是否手动配置。false=自动（设备拼好、只读），
                       // true=手动（用户自己填）。见 setManualMode()
  sniffCfg: null,      // R:SNIFFCFG 返回的配置
  frames: [],          // 最近解译帧
  infer: null,         // R:INFER 返回的推断结果
  pullBusy: false,     // 拉取配置进行中（防连点）
  pulled: false,       // 刚拉过平台配置且尚未保存确认。
                       // true 时 saveCfg 要提示"已向平台回执"，见 saveCfg()
  pushIgnored: false,  // 用户点过横幅「忽略」。只对当前这一份生效：
                       // 平台再推一份（push_n 变）就重新弹，见 renderPushBanner()
  pushSeenN: 0,        // 被忽略的那一份的 push_n，用于判断"是不是新的一份"
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
  btnReadCfg: $('btnReadCfg'), btnSaveCfg: $('btnSaveCfg'), btnPullCfg: $('btnPullCfg'),
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
  hMqHost: $('hMqHost'), hMqPort: $('hMqPort'), hMqErr: $('hMqErr'),
  hMqRealId: $('hMqRealId'),
  btnHomeMqttSave: $('btnHomeMqttSave'),
  // MQTT 页
  btnManualCfg: $('btnManualCfg'),
  btnMqttRefresh: $('btnMqttRefresh'), btnMqttSave: $('btnMqttSave'),
  btnMqttReport: $('btnMqttReport'), btnMqttReset: $('btnMqttReset'),
  mqHost: $('mqHost'), mqPort: $('mqPort'), mqSsl: $('mqSsl'), mqUser: $('mqUser'),
  mqPass: $('mqPass'), mqClientId: $('mqClientId'),
  // 密码框右侧小眼睛：显/隐切换
  btnMqttPassEye: $('btnMqttPassEye'),
  // hello topic：设备向平台自述身份用的发布 topic，与数据上报 topic 分开
  mqHelloTopic: $('mqHelloTopic'),
  mqPub: $('mqPub'), mqSub: $('mqSub'), mqInterval: $('mqInterval'),
  // 补齐的 3 条下行订阅 topic。与 hello/pub/sub 同一套手动/自动语义，
  // 不能再拆第二套开关，否则用户会疑惑"为什么这几个能改那几个只读"
  mqFunc: $('mqFunc'), mqPset: $('mqPset'), mqPget: $('mqPget'),
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
  // 未在表里列出的 id 走 $() 现取（如只读展示字段），
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
// 通用确认弹窗，替代原生 confirm()。
// ⚠️ 为什么必须替换：Electron 的原生 confirm() 在 Windows 上是模态消息框，
//    关掉之后系统常常不把前台激活还给本窗口。此时 DOM 照样能点、能获得焦点，
//    但按键全部送给上一个前台窗口——用户看到的就是"点得进输入框却打不了字，
//    必须把鼠标点到软件外任意地方，再回到软件内点一次才能输入"。
//    模式切换每次都会弹一次确认框，所以切一轮 idle→poll 后就复现。
//    自绘弹窗全程留在渲染进程里，窗口激活状态不受影响。
function askConfirm(msg, title) {
  return new Promise(resolve => {
    $('cfTitle').textContent = title || '请确认';
    $('cfMsg').textContent = msg;
    $('modalConfirm').style.display = 'flex';
    // done 只允许跑一次：确定按钮有焦点时按 Enter 会同时触发 click 和 keydown
    let done = false;
    const finish = ok => {
      if (done) return;
      done = true;
      $('modalConfirm').style.display = 'none';
      $('cfYes').onclick = null;
      $('cfNo').onclick = null;
      $('modalConfirm').onclick = null;
      document.removeEventListener('keydown', onKey);
      resolve(ok);
    };
    const onKey = e => {
      if (e.key === 'Escape') finish(false);
      else if (e.key === 'Enter') finish(true);
    };
    $('cfYes').onclick = () => finish(true);
    $('cfNo').onclick = () => finish(false);
    // 点遮罩空白处算取消；点到内容区不关，避免误触
    $('modalConfirm').onclick = e => { if (e.target === $('modalConfirm')) finish(false); };
    document.addEventListener('keydown', onKey);
  });
}
// 添加寄存器弹窗内的错误提示。不用 alert()/toast()：
// alert() 是原生模态框，有和 confirm() 一样的焦点问题；
// toast 的 z-index 低于弹窗，会被遮住看不见
function regErr(msg) {
  const e = $('regErr');
  if (!msg) { e.style.display = 'none'; e.textContent = ''; return; }
  e.textContent = msg;
  e.style.display = 'block';
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
// 回填输入框前的占位判断：这个值现在能不能写进去。
// 焦点在它上面 → 不能（会冲掉正打的字）；
// 它所在的标签页不可见 → 也不能（切走时浏览器已 blur，activeElement 不再是它，
// 只判焦点会漏；而且用户看不见，写了也白写，等切回来发现"编辑的内容没了"）。
function fillOk(e) {
  if (!e) return false;
  if (document.activeElement === e) return false;
  const tp = e.closest && e.closest('.tab-pane');
  if (tp && !tp.classList.contains('active')) return false;
  const sp = e.closest && e.closest('.serial-pane');
  return !(sp && !sp.classList.contains('active'));
}

//---------------------------------------------------------------------
// 485 页「未保存改动」检测
//   问题：通讯参数和参数列表改完后没有任何提示，用户切个页面/点下读取配置
//        就丢了，还以为是设备没存上。
//   做法：把表单 + 参数表归一化成快照，和上一次「干净」快照（读入/保存/拉取/
//        导入之后）比对。比给每个控件挂 input 监听可靠——漏挂一个就漏判；
//        也不怕回填过程误触发——回填完再取快照。
//---------------------------------------------------------------------
function cfgSnap() {
  const rows = [];
  el.paramTbody.querySelectorAll('tr').forEach(tr => {
    if (!tr.querySelector('.c-addr')) return;          // 空表提示行
    rows.push([
      tr.querySelector('.c-addr').value,
      tr.querySelector('.c-type').value,
      tr.querySelector('.c-count').value,
      tr.querySelector('.c-name').value,
      tr.querySelector('.c-alias').value
    ].join('|'));
  });
  return JSON.stringify({
    b: el.selBaud.value, db: radioVal('databits'), p: radioVal('parity'),
    sb: radioVal('stopbits'), sl: el.inpSlave.value,
    iv: el.inpRound.value, to: el.inpTimeout.value, r: rows
  });
}

// 表单被程序改过（读配置 / 保存 / 拉取 / 导入）之后调用：当前状态记为干净
function snapClean() { S.cfgSnap = cfgSnap(); refreshCfgDirty(); }

function refreshCfgDirty() {
  // cfgSnap 还是 null 说明从没读过配置，没有可比基线，不算脏
  const d = S.cfgSnap !== null && cfgSnap() !== S.cfgSnap;
  if (d === S.cfgDirty) return;
  S.cfgDirty = d;
  el.btnSaveCfg.textContent = d ? '保存配置 *' : '保存配置';
  el.btnSaveCfg.classList.toggle('dirty', d);
  if (d) status('有未保存的更改，点「保存配置」生效', false);
}

// 会整份覆盖表单的动作（读配置/拉取/应用推断/导入/读 MQTT）之前调用。
//   what = "485"/"MQTT"，btn = 建议点的保存按钮名，clear = 用户确认后作废对应基线
// 为什么要 clear：表单马上要被设备值覆盖，旧基线没意义了；不清的话
// fillMqHome 还会按旧基线认为"用户改过"而拒绝覆盖，导致该刷新的不刷新。
// 用自绘弹窗，不用原生 confirm()——原生模态框会抢窗口激活
async function guardUnsaved(dirty, what, btn, clear) {
  if (!dirty) return true;
  const ok = await askConfirm(
    what + ' 配置有未保存的更改，继续会丢失这些改动。\n建议先点「' + btn + '」。确定继续？',
    '有未保存的更改');
  if (ok && clear) { clear(); refreshCfgDirty(); refreshMqDirty(); }
  return ok;
}

//---------------------------------------------------------------------
// MQTT 页「未保存改动」检测（与 485 页同一套思路）
//   MQTT 页不会被 5s 定时刷新打（readMqtt 只在点刷新/切子标签/保存后调），
//   可以放心用快照比对。首页那 2 个 MQTT 输入框会被 renderHome 每 5s 回填，
//   所以在 fillMqHome 里额外加一道"脏了就不覆盖"，否则用户改了一半的
//   地址/端口会被设备旧值冲掉且毫无提示。
//---------------------------------------------------------------------
function mqSnap() {
  const g = e => (e ? e.value : '');
  const c = e => (e ? e.checked : false);
  return JSON.stringify({
    host: g(el.mqHost), port: g(el.mqPort), ssl: c(el.mqSsl),
    user: g(el.mqUser), pass: g(el.mqPass), cid: g(el.mqClientId),
    hello: g(el.mqHelloTopic),
    pub: g(el.mqPub), sub: g(el.mqSub), iv: g(el.mqInterval),
    func: g(el.mqFunc), pset: g(el.mqPset), pget: g(el.mqPget),
    noSn: c(el.mqAllowNoSn), keep: g(el.mqKeepSession),
    hHost: g(el.hMqHost), hPort: g(el.hMqPort)
  });
}

function snapMqClean() { S.mqSnap = mqSnap(); refreshMqDirty(); }

const MQ_TOPIC_IDS = ['mqHelloTopic', 'mqPub', 'mqSub', 'mqFunc', 'mqPset', 'mqPget'];

// 每行 topic 右边跟一句"是谁定的"，比看主按钮更直接
function mqTopicHints() {
  const H = S.mqManual ? '手动' : '设备拼';
  const ids = ['mqHelloHint', 'mqPubHint', 'mqSubHint',
               'mqFuncHint', 'mqPsetHint', 'mqPgetHint'];
  ids.forEach(id => { if (el[id]) el[id].textContent = H; });
}

//---------------------------------------------------------------------
// MQTT topic 手动/自动切换
//   自动（默认）：6 个 topic 只读，显示设备拼好的值（SN 已代入），
//              保存时不下发 topic，设备保留自己的模板
//   手动：      6 个 topic 可编辑，显示带 {sn} 的模板，保存时原样下发
// 按钮文字/颜色 = 唯一的模式提示：蓝色「关闭手动配置」= 手动，灰色「手动配置」= 自动
//---------------------------------------------------------------------
function setManualMode(on, opts) {
  opts = opts || {};
  S.mqManual = !!on;
  MQ_TOPIC_IDS.forEach(id => {
    const e = el[id];
    if (!e) return;
    e.readOnly = !S.mqManual;
    e.classList.toggle('ro', !S.mqManual);
  });
  el.btnManualCfg.textContent = S.mqManual ? '关闭手动配置' : '手动配置';
  el.btnManualCfg.classList.toggle('on', S.mqManual);
  el.btnManualCfg.title = S.mqManual
      ? '关闭后 topic 改回由设备自动拼接'
      : '手动配置：自己填下面的 topic';
  mqTopicHints();
  // 两种模式下输入框里放的东西不一样：自动=成品(SN 已拼)，手动=模板(带 {sn})。
  // 切过去就得顺手把内容也换掉，否则用户会拿成品去存，把 {sn} 模板存死成固定值
  if (opts.refill !== false) {
    const c = (S.mqtt && S.mqtt.cfg) || {};
    if (S.mqManual) {
      el.mqHelloTopic.value = c.hello_topic || '';
      el.mqPub.value = c.pub_topic || '';
      el.mqSub.value = c.sub_topic || '';
      el.mqFunc.value = c.func_topic || '';
      el.mqPset.value = c.pset_topic || '';
      el.mqPget.value = c.pget_topic || '';
    } else {
      el.mqHelloTopic.value = (S.mqtt && S.mqtt.hello) || '';
      el.mqPub.value = (S.mqtt && S.mqtt.pub) || '';
      el.mqSub.value = (S.mqtt && S.mqtt.sub) || '';
      el.mqFunc.value = (S.mqtt && S.mqtt.func) || '';
      el.mqPset.value = (S.mqtt && S.mqtt.pset) || '';
      el.mqPget.value = (S.mqtt && S.mqtt.pget) || '';
    }
  }
  // 换内容等于换了一遍表单，必须重新取基线，否则会误报"有未保存更改"
  if (opts.snap !== false) snapMqClean();
}

function refreshMqDirty() {
  const d = S.mqSnap !== null && mqSnap() !== S.mqSnap;
  if (d === S.mqDirty) return;
  S.mqDirty = d;
  // MQTT 页和首页各有一个保存按钮，两边都要显示未保存标记
  el.btnMqttSave.textContent = d ? '保存 *' : '保存';
  el.btnMqttSave.classList.toggle('dirty', d);
  if (el.btnHomeMqttSave) {
    el.btnHomeMqttSave.textContent = d ? '保存并重连 *' : '保存并重连';
    el.btnHomeMqttSave.classList.toggle('dirty', d);
  }
  if (d) status('有未保存的 MQTT 更改，点「保存」生效', false);
}

function esc(s) {
  return String(s === null || s === undefined ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// 设备 ts 是秒级 Unix 时间戳(collector.push_data 默认 os.time())
// 秒就够看了：同一天内的采集时刻, 跨天看不出但 485 现场不需要
function fmtTs(ts) {
  if (ts == null || ts === '' || isNaN(+ts) || +ts <= 0) return '';
  const d = new Date(+ts * 1000);
  if (isNaN(d.getTime())) return '';
  const p = n => String(n).padStart(2, '0');
  return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
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
  await readHome();      // R:STAT 四段全量；少了它，首页看门狗/点数要等 5s 定时器
  await readMqtt();
  startAutoRefresh();
}

function setPortState(open, path) {
  S.open = open;
  el.btnOpen.textContent = open ? '关闭串口' : '打开串口';
  el.stPort.textContent = open ? (path || S.port) : '未连接';
  el.stPort.style.color = open ? '#0a7d2c' : '#666';
  [el.btnReadInfo, el.btnReadCfg, el.btnPullCfg, el.btnSaveCfg, el.btnReadVal,
   el.btnHomeMqttSave].forEach(b => b.disabled = !open);
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
// quiet=true 跳过「有未保存更改」确认（调用方已经问过了，或刚连上串口没有基线）
async function readCfg(quiet) {
  if (!quiet && !await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  try {
    const rc = await sendCmd(Protocol.Enc.cfg(), 'CFG');
    const payload = rc.data;
    const c = (payload && payload.cfg) ? payload.cfg : payload;
    if (c && typeof c === 'object') {
      S.cfg = c;
      // 正在编辑的表单项不能抢：用户可能在从站地址/间隔/超时里打字，
      // 读配置应答一到就把字冲掉，表现为"输入框改不动"。
      if (fillOk(el.selBaud)) el.selBaud.value = String(c.baud || 9600);
      setRadio('databits', String(c.databits || 8));
      setRadio('parity', String(c.parity != null ? c.parity : 0));
      setRadio('stopbits', String(c.stopbits || 1));
      // "485方向控制GPIO" 输入框已按需求移除。GPIO8 方向控制由设备端
      // 脚本固定处理（core/config.lua 的 UART_485_PIN），前端不再暴露。
      // ⚠️ 千万不要在这里给已删除的控件赋值：el 取不到会是 null，
      //    整个 readCfg 抛 TypeError 被下面的 catch 吞掉，
      //    后面所有表单项都不回填，表现为"读配置后表单全空"。
      if (fillOk(el.inpRound)) el.inpRound.value = c.interval_ms || 3000;
      if (fillOk(el.inpSlave)) el.inpSlave.value = c.slave || 1;
      if (fillOk(el.inpTimeout)) el.inpTimeout.value = (c.timeout_ms == null) ? '' : c.timeout_ms;
      if (payload && payload.src === 'default') {
        toast('设备尚未保存过配置，当前为默认值');
      }
    }
    const rr = await sendCmd(Protocol.Enc.reg(), 'REG');
    // 设备端 regs 为空时回 {}（Lua 空表编码成对象而非数组），
    // 不能只判 Array.isArray，否则空配置时 renderRegTable 不会被调用，
    // 参数表停留在上一次的内容/占位行上
    const d = rr.data;
    if (Array.isArray(d)) {
      S.regs = d;
      renderRegTable();
      status('配置已读取：' + S.regs.length + ' 个寄存器', true);
    } else if (d && typeof d === 'object') {
      S.regs = [];
      renderRegTable();
      status('配置已读取：0 个寄存器', true);
    } else {
      status('配置已读取', true);
    }
    snapClean();                       // 读完了，当前表单就是干净基线
  } catch (e) {
    status('读取配置失败：' + e.message, false);
    toast('读取配置失败：' + e.message);
  }
}

// 拉取配置：从平台拉 485 配置并回填表单（不自动保存，由用户点保存生效）
//   ① 有平台主动下发的待确认配置时，直接读设备已解析好的那份，
//      跳过 W:PULLCFG 握手（否则把已解析好的结果冲掉，白等 20s+15s）
//   ② 否则 W:PULLCFG 发起，轮询 R:PULLCFG 直到 done/fail
//   ③ done 后回填 串口参数 + 寄存器表 + MQTT 上报/下行 topic
async function pullCfg() {
  if (S.pullBusy) return;
  if (!await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  S.pullBusy = true;
  const btn = el.btnPullCfg;
  const oldText = btn ? btn.textContent : '';
  if (btn) { btn.textContent = '拉取中…'; btn.disabled = true; }
  const restore = () => {
    S.pullBusy = false;
    if (btn) { btn.textContent = oldText; btn.disabled = !S.open; }
  };
  try {
    await sendCmd(Protocol.Enc.pullCfg(), 'PULLCFG', 8000);
    // 设备端要先连 MQTT(PULL_CONNECT_MS=20s)再等平台下发(PULL_TIMEOUT_MS=15s),
    // 所以这里按总时长轮询, 不能用固定次数
    let r = null;
    const t0 = Date.now();
    while (Date.now() - t0 < 55000) {
      r = await sendCmd(Protocol.Enc.pullCfgStat(), 'PULLCFG', 5000);
      if (r.data && r.data.state !== 'connecting' && r.data.state !== 'helloing'
          && r.data.state !== 'waiting') break;
      await new Promise(res => setTimeout(res, 1000));
    }
    const d = r && r.data;
    if (!d || d.state !== 'done') {
      status('拉取失败：' + ((d && d.msg) || '未知原因'), false);
      toast('拉取失败：' + ((d && d.msg) || '未知原因'));
      return;
    }
    fillFormFromPlatform(d);
    // 拉取配置是"平台说了算"，抢过手动配置的话事权：强制关掉手动模式，
    // topic 换成平台返回的那套（设备拼好、SN 已代入）
    if (S.mqManual) setManualMode(false);
    snapClean();                       // 拉回来的值成为新基线，不再是「未保存」
    snapMqClean();
    const skipped = (d.skipped || []).length;
    const n = (d.poll && d.poll.regs ? d.poll.regs.length : 0);
    // 平台把中文 name 按 GBK 下发时设备判为非法 UTF-8, 会自动把别名退回 id。
    // 必须说出来, 否则用户只会看见别名栏莫名其妙变成了 id
    const renamed = (d.renamed || []).filter(x => typeof x === 'string' && x.trim());
    const renamedTip = renamed.length
        ? '，' + renamed.length + ' 个平台别名不可用已退用 id（' + renamed.join('、') + '，中文需平台改 UTF-8）'
        : '';
    // 设备端解析成功即自动落盘并生效，也自动回执 U6。回声里说出来，
    // 否则用户不知道刚才那一下已经把设备改了
    const autoTip = d.autosaved
        ? '，设备已自动保存并生效、已回执平台'
        : '，未自动保存（需检查设备日志）';
    status('已拉取 ' + n + ' 个寄存器' + (skipped ? '，忽略 ' + skipped + ' 条' : '')
           + renamedTip + autoTip, true);
    toast(d.autosaved ? '配置已拉取并自动保存生效' : '配置已拉取，但未能自动保存');
  } catch (e) {
    status('拉取失败：' + e.message, false);
    toast('拉取失败：' + e.message);
  } finally {
    restore();
  }
}

// 把平台拉回的配置填进表单。只填不存：W:CFG/W:REG/W:MQTT 全由用户点保存触发
function fillFormFromPlatform(d) {
  const p = d.poll || {};
  if (p.baud) el.selBaud.value = String(p.baud);
  if (p.databits) setRadio('databits', String(p.databits));
  if (p.parity != null) setRadio('parity', String(p.parity));
  if (p.stopbits) setRadio('stopbits', String(p.stopbits));
  if (p.slave) el.inpSlave.value = p.slave;
  if (p.regs) { S.regs = p.regs; renderRegTable(); }
  if (d.mqtt) {
    // 拉取的 MQTT 段现在带 6 个 topic 成品（hello/pub/sub/func/pset/pget），
    // 都是设备拼好的成品（SN 已代入）。只填不下发：topic 归设备管，
    // 用户改的只是地址/账号这些，与自动模式语义一致
    if (d.mqtt.hello) el.mqHelloTopic.value = d.mqtt.hello;
    if (d.mqtt.pub) el.mqPub.value = d.mqtt.pub;
    if (d.mqtt.sub) el.mqSub.value = d.mqtt.sub;
    if (d.mqtt.func) el.mqFunc.value = d.mqtt.func;
    if (d.mqtt.pset) el.mqPset.value = d.mqtt.pset;
    if (d.mqtt.pget) el.mqPget.value = d.mqtt.pget;
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

// topic 里是否含 SN 占位符。{sn} 是新默认模板的写法，
// {id} 是旧模板写法，两者都认，避免老配置被误判为"没写 SN"
function hasSnPh(s) {
  return String(s).indexOf('{sn}') >= 0 || String(s).indexOf('{id}') >= 0;
}

function collectRegs() {
  const out = [];
  el.paramTbody.querySelectorAll('tr').forEach(tr => {
    // 空表提示行没有 .c-addr，必须先判空。
    // 少了这道判断，空表时点保存配置会在这里抛 TypeError，
    // 而 collectRegs 在 saveCfg 的 try 之外，异常直接冲出 onclick，
    // 界面不弹任何提示 -> 表现为"点了没反应"
    if (!tr.querySelector('.c-addr')) return;
    const addr = parseInt(tr.querySelector('.c-addr').value, 10);
    const dtype = tr.querySelector('.c-type').value;
    const name = tr.querySelector('.c-name').value.trim();
    const count = parseInt(tr.querySelector('.c-count').value, 10);
    // 参数名称：MQTT 的 name 字段。空串照样下发，设备端会退回用标识符
    // name 合法性由 badRegRow() 提前逐行校验，这里只做最基本的结构过滤
    const alias = tr.querySelector('.c-alias').value.trim();
    if (!isNaN(addr) && dtype && count > 0 && name) {
      out.push({ addr, count, name, alias, dtype });
    }
  });
  return out;
}

// 设备 cfgstore.normalize_* 的错误码 -> 人话。原样弹 bad name 之类用户看不懂
const CFG_ERR = {
  'bad addr': '寄存器地址越界(0~65535)',
  'bad count': '寄存器个数越界(1~125)',
  'bad dtype': '数据类型不合法',
  'bad name': '标识符为空/超16字符/含非法字符(只能字母数字下划线)',
  'bad byteOrder': '字节序不合法',
  'bad wordOrder': '字序不合法',
  'bad slave': '从机地址越界(1~247)',
  'bad interval': '轮询间隔过小',
  'too many regs': '寄存器个数超过上限',
  'too large': '配置过大',
  'bad host': 'MQTT 服务器地址不合法',
  'bad port': 'MQTT 端口越界(1~65535)',
  'bad pub_topic': '发布 Topic 不合法',
  'bad sub_topic': '订阅 Topic 不合法',
  'bad interval_s': '上报周期越界',
  'bad qos': 'QoS 越界(0~2)',
  'bad boot_mode': '开机默认模式不合法',
  'not table': '配置格式错误'
};
function cfgErr(raw) {
  const s = String(raw || '');
  for (const k in CFG_ERR) if (s.indexOf(k) >= 0) return CFG_ERR[k];
  return s;
}

async function saveCfg() {
  // 兜底：前置校验任何意外都必须留下痕迹。否则异常会直接冲出 onclick，
  // 界面不弹 toast 也不改 status，用户看到的就是"点了没反应"
  try {
    const c = collectCfg();
    if (!c.ok) { toast(c.err); status('配置无效：' + c.err, false); return; }
    const cfg = c.cfg;
    const bad = badRegRow();
    if (bad) { toast(bad); status('配置无效：' + bad, false); return; }
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
      snapClean();                     // 保存成功 = 表单和设备一致，清掉「未保存」标记
      status('配置已保存（串口参数变化时设备会自动重启轮询任务）', true);
      toast('保存成功');
      await readMode();
    } catch (e) {
      const msg = cfgErr(e.message);
      status('保存失败：' + msg, false);
      toast('保存失败：' + msg);
    }
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

// 逐行检查参数表，返回第一条不合法的人类可读原因（全部合法返回 null）。
// 比 collectRegs 静默丢弃更好：能说清是第几行、缺什么
function badRegRow() {
  const rows = el.paramTbody.querySelectorAll('tr');
  for (let i = 0; i < rows.length; i++) {
    const tr = rows[i];
    if (!tr.querySelector('.c-addr')) continue;      // 空表提示行
    const addr = parseInt(tr.querySelector('.c-addr').value, 10);
    const dtype = tr.querySelector('.c-type').value;
    const name = tr.querySelector('.c-name').value.trim();
    const count = parseInt(tr.querySelector('.c-count').value, 10);
    const n = i + 1;
    if (isNaN(addr) || addr < 0 || addr > 65535) return '第 ' + n + ' 行：寄存器地址越界(0~65535)';
    if (!dtype) return '第 ' + n + ' 行：未选择数据类型';
    if (!count || count < 1 || count > 125) return '第 ' + n + ' 行：寄存器个数越界(1~125)';
    if (!name) return '第 ' + n + ' 行：标识符不能为空';
    if (name.length > 16) return '第 ' + n + ' 行：标识符超 16 字符';
    if (!/^\w+$/.test(name)) return '第 ' + n + ' 行：标识符只能含字母、数字、下划线';
    const w = ({ uint32: 2, int32: 2, float32: 2, uint64: 4, int64: 4, float64: 4 })[dtype] || 1;
    if (count % w !== 0) return '第 ' + n + ' 行：' + dtype + ' 占 ' + w + ' 个寄存器，个数需为 ' + w + ' 的整数倍';
  }
  return null;
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
    let hit = 0, total = 0;
    el.paramTbody.querySelectorAll('tr').forEach(tr => {
      // 空表提示行没有这些 class，必须先判空。
      // 少了这道判断，占位行会让 querySelector(...).value 抛 TypeError，
      // 被下面的 catch 吞成一句英文 "Cannot read properties of null"
      if (!tr.querySelector('.c-addr')) return;
      total++;
      const name = tr.querySelector('.c-name').value.trim();
      const addr = parseInt(tr.querySelector('.c-addr').value, 10);
      const type = tr.querySelector('.c-type').value;
      const count = parseInt(tr.querySelector('.c-count').value, 10) || 1;
      const cell = tr.querySelector('.c-val');
      const tsCell = tr.querySelector('.c-ts');
      const it = (name && byName[name]) || byAddr[String(addr)];
      if (tsCell) tsCell.value = '';
      if (it) {
        hit++;
        // 设备已解好的值优先；只有给了原始 regs 时才前端重解(固定 BE)
        if (it.regs && Array.isArray(it.regs)) {
          const vals = Protocol.decodeValues(it.regs, type, count);
          cell.value = vals.map(Protocol.fmt).join(', ');
        } else if (it.value !== undefined && it.value !== null) {
          cell.value = Protocol.fmt(it.value);
        } else if (it.hex) {
          cell.value = it.hex;      // 读失败时至少看到原始字节
        } else {
          cell.value = '';
        }
        if (tsCell) tsCell.value = fmtTs(it.ts);
      } else {
        cell.value = '';
      }
    });
    if (total === 0) {
      status('参数列表为空，请先添加寄存器', false);
      toast('参数列表为空，请先添加寄存器');
    } else if (hit === 0 && list.length === 0) {
      status('暂无数据：设备可能未进入轮询模式', false);
      toast('没有读到数据，请先在「运行模式」页进入轮询模式');
    } else {
      status('实时值已刷新（' + hit + '/' + total + ' 点有值）', true);
    }
  } catch (e) {
    status('读取实时值失败：' + cfgErr(e.message), false);
    toast('读取实时值失败：' + cfgErr(e.message));
  }
}

//---------------------------------------------------------------------
// 寄存器表格
//---------------------------------------------------------------------
const ALL_TYPES = ['uint16', 'int16', 'uint32', 'int32', 'float32', 'uint64', 'int64', 'float64'];

function renderRegTable() {
  // 两种情况都不重建 DOM：
  // ① 焦点正在参数表里 —— 重建会丢焦点、冲掉刚打的字；
  // ② poll 标签页不可见且表里已有真实数据行 —— 切走时浏览器会把焦点里的
  //    输入框 blur 掉，activeElement 变成 <body>，只判焦点会漏。此时用户
  //    看不见表格，重建只会悄悄丢数据，等切回来发现"编辑的内容没了"。
  //    ⚠️ 必须确认表里真的有 .c-addr 行才跳过：空表/占位行时该渲染，
  //    否则首次进入（首页默认激活）连"暂无寄存器"都画不出来。
  const ae = document.activeElement;
  if (ae && ae.closest && el.paramTbody.contains(ae)) return;
  const pane = $('tabPoll');
  if (pane && !pane.classList.contains('active') && el.paramTbody.querySelector('.c-addr')) return;
  el.paramTbody.innerHTML = '';
  const rows = (S.regs && S.regs.length) ? S.regs : [];
  if (rows.length === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td colspan="8" style="color:#999;padding:14px;">暂无寄存器，点「新增寄存器」添加</td>';
    el.paramTbody.appendChild(tr);
    return;
  }
  rows.forEach(r => addRegRow(r.addr, r.dtype || r.type, r.name, r.alias, r.count));
}

function addRegRow(addr, type, name, alias, count) {
  const tr = document.createElement('tr');
  const opts = ALL_TYPES
    .map(t => '<option' + (t === type ? ' selected' : '') + '>' + t + '</option>').join('');
  tr.innerHTML =
    '<td><input class="c-addr" type="number" value="' + addr + '"></td>' +
    '<td><select class="c-type">' + opts + '</select></td>' +
    '<td><input class="c-count" type="number" value="' + (count || 1) + '" min="1" max="125"></td>' +
    '<td><input class="c-name" type="text" value="' + esc(name || '') + '"></td>' +
    '<td><input class="c-alias" type="text" value="' + esc(alias || '') + '" ' +
    'title="MQTT 上报 name 字段的中文名，留空则用标识符"></td>' +
    '<td class="val-cell"><input class="c-val" type="text" value="" readonly></td>' +
    '<td class="ts-cell"><input class="c-ts" type="text" value="" readonly></td>' +
    '<td><button class="btn-del" onclick="deleteRow(this)">删除</button></td>';
  // 空表提示行没有 .c-addr，新增第一行前先删掉，否则它会和真实数据行并存，
  // 界面同时显示"暂无寄存器"和一个寄存器，自相矛盾
  const ph = el.paramTbody.querySelector('tr td[colspan]');
  if (ph) ph.parentNode.removeChild(ph);
  el.paramTbody.appendChild(tr);
  refreshCfgDirty();                   // 增行是 DOM 操作，不触发 input 事件，得手动标脏
}

function deleteRow(btn) {
  btn.closest('tr').remove();
  refreshCfgDirty();                   // 删行同理
}
function addParamRow() {
  $('regAddr').value = 1;
  $('regType').value = '';
  $('regId').value = '';
  $('regAlias').value = '';
  $('regCount').value = 1;
  regErr('');                                   // 上次的错误提示不能留着
  $('modalAddReg').style.display = 'flex';
}
function closeModal() { $('modalAddReg').style.display = 'none'; }
function confirmAddReg() {
  const addr = $('regAddr').value;
  const type = $('regType').value;
  const phyId = $('regId').value;
  const alias = $('regAlias').value.trim();
  const cnt = parseInt($('regCount').value, 10);
  // 错误提示写在弹窗里：alert() 是原生模态框，关掉后会让整个窗口丢失
  // 前台激活（详见 askConfirm 的注释），弹窗内的输入框也会跟着打不了字
  if (!type) { regErr('请选择数据类型'); return; }
  if (!addr || !cnt) { regErr('寄存器地址、寄存器个数不能为空'); return; }
  const W = { uint32: 2, int32: 2, float32: 2, uint64: 4, int64: 4, float64: 4 };
  const w = W[type] || 1;
  if (cnt % w !== 0) { regErr(type + ' 占 ' + w + ' 个寄存器，个数需为 ' + w + ' 的整数倍'); return; }
  if (!/^\w+$/.test(phyId.trim())) { regErr('标识符只能含字母、数字、下划线'); return; }
  if (phyId.trim().length > 16) { regErr('标识符最长 16 字符'); return; }
  addRegRow(parseInt(addr, 10), type, phyId.trim(), alias, cnt);
  regErr('');
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
  // data/guard 两段只在 R:STAT 顶层，R:MODE 不返回，必须从 S.stat 取。
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
  setKv('hFrames', m.frames);
  // 首页 MQTT 地址/端口回填。5s 定时刷新会打到这里, 正在输入时不能抢,
  // 否则字打到一半被冲掉
  fillMqHome(mq);
  el.stMqtt.textContent = mq.connected ? '已连接' : '未连接';
  el.stMqtt.style.color = mq.connected ? '#0a7d2c' : '#999';
  renderPushBanner(mq);
}

// 平台重新下发配置的横幅。
// 数据来自 R:STAT 的 mqtt 段（push_n/push_seen/push_err/autosaved），
// 跟着 5s 轮询走 —— R:PULLCFG 只在用户点「拉取配置」时才查，等不到这里。
// 拉取成功即自动保存，所以这里不再是"待确认"门控，而是"设备已被平台
// 改过"的通知；只有解析/保存失败才是需要用户介入的红色告警
function renderPushBanner(mq) {
  const box = el.pushBanner;
  if (!box || !el.pushBannerText) return;
  // 没有平台主动下发的记录就不显示（push_n=0 表示本机从未被平台推过）
  if (!mq.push_n) {
    box.hidden = true;
    S.pushIgnored = false;      // 清了就重置忽略状态
    return;
  }
  // 同一份（push_n 没变）且用户点过忽略，就别再刷屏
  if (S.pushIgnored && S.pushSeenN === mq.push_n) { box.hidden = true; return; }
  S.pushSeenN = mq.push_n;
  box.hidden = false;

  let txt, bad = false;
  if (mq.push_err) {
    // 解析或自动保存失败：设备认出了是配置包但没能落地。必须说出来，
    // 否则表现为"平台点了重新下发但前端毫无反应"
    bad = true;
    txt = '平台推送了配置，但设备处理失败：' + mq.push_err + '（见设备日志）';
  } else {
    const secs = mq.push_seen ? Math.max(0, Math.floor(Date.now() / 1000) - mq.push_seen) : 0;
    const age = secs >= 60 ? Math.floor(secs / 60) + ' 分钟' : secs + ' 秒';
    const n = mq.push_n > 1 ? '（第 ' + mq.push_n + ' 份）' : '';
    txt = '平台重新下发了配置' + n + '，设备已自动保存并生效（' + age + '前）。';
  }
  el.pushBannerText.textContent = txt;
  // 黄色=已生效的通知，红色=失败待处理
  box.classList.toggle('push-banner-bad', bad);
}

function fillMqHome(mq) {
  if (!el.hMqHost) return;
  // 有未保存改动时，5s 定时刷新不许覆盖首页这两个 MQTT 输入框。
  // fillOk 只挡"焦点正在里面"——用户点一下别处焦点就丢了，下一轮刷新
  // 照样把改了一半的地址/端口冲成设备旧值，而且毫无提示。
  // 切到别的标签页时 tab0 不可见，fillOk 本来就会挡住，两道一起才全覆盖
  if (!S.mqDirty) {
    if (fillOk(el.hMqHost)) el.hMqHost.value = mq.host || '';
    if (fillOk(el.hMqPort)) el.hMqPort.value = mq.port != null ? mq.port : 1883;
  }
  if (el.hMqErr) {
    el.hMqErr.textContent = mq.reject_reason || '';
    el.hMqErr.style.color = '#c0392b';
  }
  // 实际发给 broker 的 clientId(S.client_id), 与配置项可能不同(留空时用 SN)。
  // CONACK 0x05 时最该看的就是这行
  if (el.hMqRealId) {
    el.hMqRealId.textContent = mq.client_id || '--';
  }
}

// 首页只改地址/端口。先读全量配置再合并, 否则把用户名/主题等字段冲掉
async function saveHomeMqtt() {
  // 必须守卫：合并用的基线来自 R:MQTT（设备当前值），不是表单。
  // 如果用户在 MQTT 页改了 topic/用户名没保存，这里一保存就把那些改动冲掉了
  if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
  const host = el.hMqHost.value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  const port = parseInt(el.hMqPort.value, 10) || 1883;
  try {
    const r = await sendCmd(Protocol.Enc.mqtt(), 'MQTT', 4000);
    const c = (r.data && r.data.cfg) || {};
    if (r.data) { S.mqtt = r.data; renderMqtt(); }
    await sendCmd(Protocol.Enc.writeMqtt(Object.assign({}, c, { host: host, port: port })), 'MQTT', 5000);
    snapMqClean();
    status('MQTT 配置已保存，设备正在重连', true);
    toast('已保存，设备重连中');
    await new Promise(res => setTimeout(res, 1500));
    await readMqtt(true);
    readHome();
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

async function readHome() {
  try {
    const r = await sendCmd(Protocol.Enc.stat(), 'STAT', 4000);
    // R:STAT 一次性返回 mode/data/guard/mqtt 四个平级段。
    // ⚠️ 以前这里只 S.modeStat = r.data.mode，把 data/guard 全丢了，
    //    导致首页"看门狗"永远显示未启用、"数据点数"永远 --。
    if (r.data) {
      S.stat = r.data;                                   // 完整四段，首页要用
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
    // 正在输入的框不能抢：readMqtt 会在点"MQTT配置"子标签/刷新时触发，
    // 应答落地时把用户打到一半的字冲掉，表现为"输入框改不动"。
    if (fillOk(el.mqHost)) el.mqHost.value = c.host || '';
    if (fillOk(el.mqPort)) el.mqPort.value = c.port != null ? c.port : 1883;
    el.mqSsl.checked = !!c.ssl;
    if (fillOk(el.mqUser)) el.mqUser.value = c.user || '';
    if (fillOk(el.mqPass)) el.mqPass.value = c.pass || '';
    if (fillOk(el.mqClientId)) el.mqClientId.value = c.client_id || '';
    // hello topic 排在发布 Topic 上面：一个是拉配置时自述身份，一个是数据上报。
    // 自动模式填设备拼好的成品(SN 已代入)，手动模式填带 {sn} 的模板
    if (fillOk(el.mqHelloTopic)) {
      el.mqHelloTopic.value = S.mqManual
          ? (c.hello_topic || '')
          : (r.hello || '');
    }
    if (fillOk(el.mqPub)) {
      el.mqPub.value = S.mqManual ? (c.pub_topic || '') : (r.pub || '');
    }
    if (fillOk(el.mqSub)) {
      el.mqSub.value = S.mqManual ? (c.sub_topic || '') : (r.sub || '');
    }
    // 补齐的 3 条下行订阅：与上面完全同构，r.func/r.pset/r.pget 是设备拼好的成品
    if (fillOk(el.mqFunc)) {
      el.mqFunc.value = S.mqManual ? (c.func_topic || '') : (r.func || '');
    }
    if (fillOk(el.mqPset)) {
      el.mqPset.value = S.mqManual ? (c.pset_topic || '') : (r.pset || '');
    }
    if (fillOk(el.mqPget)) {
      el.mqPget.value = S.mqManual ? (c.pget_topic || '') : (r.pget || '');
    }
    if (fillOk(el.mqInterval)) el.mqInterval.value = c.interval_s != null ? c.interval_s : 60;
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
  // 下行订阅全量：设备 conack 时订的 4 条 gw 前缀通道。只列 topic 不列数，
  // 现场直接照着对 broker 上有没有这条订阅
  const subs = Array.isArray(s.subs) ? s.subs : [];
  setKv('mqStSubs', subs.length ? subs.join('\n') : '未连接', subs.length === 0);
  // 配置回执：拉取配置成功后要点保存才会 +1，为 0 说明平台还在等核销
  setKv('mqStReplied', s.replied ? s.replied + ' 次' : '0 次', !s.replied);
  setKv('mqStPubed', s.published);
  setKv('mqStFailed', s.failed, s.failed > 0);
  setKv('mqStLast', s.last_pub ? new Date(s.last_pub * 1000).toLocaleTimeString() : '');
  setKv('mqStBackoff', s.backoff != null ? s.backoff + ' s' : '');
  setKv('mqStKeepSession',
        s.keep_session == null ? '--' : (s.keep_session ? '持久会话' : '离线自动销毁'));
  setKv('mqStErr', s.reject_reason || s.last_err || '', !!(s.reject_reason || s.last_err));
  setKv('mqStSn', r.ready ? '已烧号' : (r.err || '未烧号'), !r.ready);
  renderHome();
  mqTopicHints();
  // 只在第一次渲染时套一次模式：只读属性/颜色/回显来源都要跟 S.mqManual 走。
  // 后面每次 readMqtt 都重套会覆盖用户在本次会话里点的「手动配置」
  if (S._mqModeInit !== true) {
    S._mqModeInit = true;
    setManualMode(S.mqManual);
  }
}

// quiet=true 跳过「有未保存更改」确认（保存/上报/重连之后的回读，以及
// 刚连上串口还没有基线时）。这两处不该弹框：不是用户主动发起的读取
async function readMqtt(quiet) {
  if (!quiet && !await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
  try {
    const r = await sendCmd(Protocol.Enc.mqtt(), 'MQTT');
    S.mqtt = r.data;
    renderMqtt();
    snapMqClean();                   // 读完了，当前表单就是干净基线
  } catch (e) {
    setKv('mqStErr', '读取失败：' + e.message, true);
  }
}

async function saveMqtt() {
  const host = el.mqHost.value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  // 6 个 topic 都先按"留空回退默认"归一，再判 {sn}。
  // 必须用归一后的值判：拿原始值判的话，清空输入框会被误报成"不含 {sn}"，
  // 而实际发下去的是含 {sn} 的默认模板
  const HELLO = '/sys/thing/gw/config/hello/{sn}';
  const PUB   = '/sys/thing/node/property/post/{sn}';
  const SUB   = '/sys/thing/gw/config/get/{sn}';
  const FUNC  = '/sys/thing/gw/function/get/{sn}';
  const PSET  = '/sys/thing/gw/property/set/{sn}';
  const PGET  = '/sys/thing/gw/property/get/{sn}';
  const helloT = el.mqHelloTopic.value.trim() || HELLO;
  const pubT   = el.mqPub.value.trim() || PUB;
  const subT   = el.mqSub.value.trim() || SUB;
  const funcT  = el.mqFunc.value.trim() || FUNC;
  const psetT  = el.mqPset.value.trim() || PSET;
  const pgetT  = el.mqPget.value.trim() || PGET;
  // {sn} 只是推荐（多台设备不撞 topic）。平台若要求固定格式
  // （如 /12/<sn>/property/post），用户直接把 SN 写进 topic 也放行。
  // 自动模式下三个 topic 不下发，这里的 {sn} 提示就没意义，跳过
  if (S.mqManual && !hasSnPh(pubT) && !hasSnPh(subT) && !hasSnPh(helloT)) {
    if (!await askConfirm('发布/订阅/hello Topic 都不含 {sn} 占位符。\n若 topic 里没写设备 SN，多台设备会共用同一 topic 导致数据互相覆盖。\n确定继续吗？', 'Topic 未含 {sn}')) return;
  }
  const cfg = {
    host: host,
    port: parseInt(el.mqPort.value, 10) || 1883,
    ssl: el.mqSsl.checked,
    user: el.mqUser.value.trim(),
    pass: el.mqPass.value,
    client_id: el.mqClientId.value.trim(),
    // 留空时用设备端默认模板，两边必须一致。
    // 自动模式下根本不下发这三个键：mqttcfg.save 对缺失键用设备现值补，
    // 语义正好是"topic 归设备管，用户改的只是地址/账号这些"
    ...(S.mqManual ? {
      hello_topic: helloT,
      pub_topic: pubT,
      sub_topic: subT,
      func_topic: funcT,
      pset_topic: psetT,
      pget_topic: pgetT,
    } : {}),
    interval_s: parseInt(el.mqInterval.value, 10) || 0,
    // QoS 界面已移除，不再下发；设备端固定用 QoS 1
    allow_no_sn: el.mqAllowNoSn.checked,
    // select: '1'=持久会话  '0'=离线自动销毁（默认）
    keep_session: el.mqKeepSession.value === '1'
  };
  try {
    await sendCmd(Protocol.Enc.writeMqtt(cfg), 'MQTT', 5000);
    snapMqClean();                     // 保存成功 = 表单和设备一致，清掉「未保存」标记
    status('MQTT 配置已保存，设备正在重连', true);
    toast('已保存，设备重连中');
    await new Promise(res => setTimeout(res, 1500));
    await readMqtt(true);
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
    await readMqtt(true);
  } catch (e) {
    status('上报失败：' + e.message, false);
    toast('上报失败：' + e.message);
  }
}

// 密码框右侧小眼睛：password / text 互换。
// 只改 type，值和焦点都不动，所以正在输入中途切也不会丢字；
// 也不抢输入框焦点（按钮是独立的 type="button"，点了焦点还在输入框）
function togglePassEye() {
  const show = el.mqPass.type === 'password';
  el.mqPass.type = show ? 'text' : 'password';
  el.btnMqttPassEye.classList.toggle('show', show);
  el.btnMqttPassEye.title = show ? '隐藏密码' : '显示密码';
}

// 只重连、不保存配置：改完地址/端口后想立即生效又不想整份覆盖时用。
// 设备侧 W:MQTTRC -> iot.kick()，销毁 client 后 backoff 归 1 立刻重连
async function mqttReconnect() {
  try {
    await sendCmd(Protocol.Enc.mqttReconnect(), 'MQTTRC', 5000);
    status('已通知设备重连', true);
    toast('重连中');
    await new Promise(res => setTimeout(res, 1500));
    await readMqtt(true);
  } catch (e) {
    status('重连失败：' + e.message, false);
    toast('重连失败：' + e.message);
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
  if (!await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  try {
    await sendCmd(Protocol.Enc.applyInfer(), 'APPLYINFER', 5000);
    status('推断结果已写入轮询配置', true);
    toast('已应用到轮询配置');
    await readCfg(true);               // 上面已经确认过，别再弹一次
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

async function importCfg() {
  // 先问再弹文件选择框：顺序反了的话用户选完文件才被告知会丢改动，白选一趟
  if (!await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
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
          el.mqFunc.value = d.mqtt.func_topic || '';
          el.mqPset.value = d.mqtt.pset_topic || '';
          el.mqPget.value = d.mqtt.pget_topic || '';
          el.mqInterval.value = d.mqtt.interval_s != null ? d.mqtt.interval_s : 60;
          // QoS 界面已移除；老配置文件里若还带 qos 字段，忽略
          el.mqAllowNoSn.checked = !!d.mqtt.allow_no_sn;
          el.mqKeepSession.value = d.mqtt.keep_session ? '1' : '0';
        }
        toast('配置已导入：' + regs.length + ' 个寄存器');
        snapClean();                   // 导入的内容成为新基线
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
el.btnPullCfg.onclick = pullCfg;
el.btnSaveCfg.onclick = saveCfg;
el.btnReadVal.onclick = readVal;
el.btnAddReg.onclick = addParamRow;
el.btnImport.onclick = importCfg;
el.btnExport.onclick = exportCfg;
el.comSel.onchange = () => { S.port = el.comSel.value; };

// 平台推送横幅：查看 = 走 pullCfg 读设备已解析好的那份；
// 忽略 = 本次不再提示（平台再推一份照旧弹，见 renderPushBanner）
if (el.btnPushView) el.btnPushView.onclick = () => { S.pushIgnored = false; pullCfg(); };
if (el.btnPushIgnore) el.btnPushIgnore.onclick = () => {
  S.pushIgnored = true;
  if (el.pushBanner) el.pushBanner.hidden = true;
};

// 485 页未保存检测：一条 input + 一条 change 的事件代理覆盖全部编辑入口
// （波特率/从站/间隔/超时 4 个输入框 + 3 组 radio + 参数表每行 5 个可编辑单元格），
// 比逐个控件挂监听省事，新增控件也不会漏。
// 增行/删行走 DOM 操作，不触发这两个事件，已在 addRegRow/deleteRow 里手动标脏
['input', 'change'].forEach(ev => {
  const pane = $('sp-s1');
  if (pane) pane.addEventListener(ev, refreshCfgDirty);
});

// MQTT 未保存检测：MQTT 页(#sp-s2) + 首页 MQTT 那一栏(#tab0)分属两个容器，
// 用事件代理得挂到 body 上，反而绕。这里直接把可编辑字段逐个挂监听，
// 一目了然，新增字段时漏不了（编译器不会提醒，但列表就摆在眼前）。
// 程序回填(renderMqtt/fillMqHome 赋 .value)不触发这两个事件，不会误标脏
[el.mqHost, el.mqPort, el.mqSsl, el.mqUser, el.mqPass, el.mqClientId,
 el.mqHelloTopic, el.mqPub, el.mqSub, el.mqInterval, el.mqKeepSession,
 el.mqAllowNoSn, el.hMqHost, el.hMqPort,
 el.mqFunc, el.mqPset, el.mqPget].forEach(e => {
  if (!e) return;
  e.addEventListener('input', refreshMqDirty);
  e.addEventListener('change', refreshMqDirty);
});

// 首页
el.btnHomeRefresh.onclick = async () => { await readHome(); await readMode(); await readMqtt(); };
el.btnHomeMqttSave.onclick = saveHomeMqtt;

// 运行模式页
el.btnModeRefresh.onclick = readMode;
el.btnSaveBoot.onclick = saveBootMode;
// 点卡片 = 弹窗确认后立即切换（"应用所选模式"按钮已去掉，卡片即操作）。
// 之前只切高亮不发命令，5s 定时刷新一到就把高亮打回旧模式，
// 表现为"选中后模式自动跳回原来模式"。
// 卡片区域大、容易误点，切换又要停掉旧模式，所以必须弹窗确认。
const MODE_LABEL = { idle: '空闲 idle', poll: '轮询 poll', sniff: '旁听 sniff' };
document.querySelectorAll('.mode-card').forEach(c => {
  c.onclick = async () => {
    const m = c.getAttribute('data-mode');
    // 点的就是设备当前模式且没有待应用选择：只重绘，不发命令、不弹窗
    if (m === S.mode && !S.modePending) { renderMode(); return; }
    // 切换中忽略连点（applyMode 内部也有同样的保护）
    if (S.modeSwitching) return;
    const label = MODE_LABEL[m] || m;
    const curLabel = MODE_LABEL[S.mode] || S.mode;
    if (!await askConfirm('确定把 485 运行模式从「' + curLabel + '」切换到「' + label + '」？\n\n'
                 + '切换时设备会先停掉旧模式再启动新模式（互斥），'
                 + '正在进行的采集会中断。', '切换运行模式')) return;
    applyMode(m);
  };
});
// MQTT 页
el.btnMqttRefresh.onclick = readMqtt;
// 「手动配置」是 topic 的手动/自动开关，不是跳页按钮：
//   点开(蓝)=手动，三个 topic 可自己填；点关(灰)=自动，topic 由设备拼好只读回显。
//   串口1那边「拉取配置」成功时会自动把它关掉并回填平台给的三个 topic
el.btnManualCfg.onclick = async () => {
  if (!S.mqManual) {
    // 开手动：可能有未保存改动，开着会丢
    if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
    setManualMode(true);
    status('已开启手动配置，可修改下面的 topic', true);
  } else {
    // 关手动：屏幕上那三个成品值会被设备模板顶掉，同样要先问
    if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
    setManualMode(false);
    status('已关闭手动配置，topic 由设备自动拼接', true);
  }
};
el.btnMqttSave.onclick = saveMqtt;
el.btnMqttReport.onclick = reportNow;
el.btnMqttReconnect.onclick = mqttReconnect;
el.btnMqttPassEye.onclick = togglePassEye;
el.btnMqttReset.onclick = async () => {
  if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
  if (!await askConfirm('确定恢复 MQTT 默认配置？', '恢复默认配置')) return;
  // 恢复默认会重写 topic，必须先切手动，否则自动模式下 topic 不下发，白改
  if (!S.mqManual) setManualMode(true, { snap: false });
  el.mqHost.value = 'test.mosquitto.org';
  el.mqPort.value = 1883;
  el.mqSsl.checked = false;
  el.mqUser.value = '';
  el.mqPass.value = '';
  el.mqClientId.value = '';
  el.mqHelloTopic.value = '/sys/thing/gw/config/hello/{sn}';
  el.mqPub.value = '/sys/thing/node/property/post/{sn}';
  el.mqSub.value = '/sys/thing/gw/config/get/{sn}';
  el.mqFunc.value = '/sys/thing/gw/function/get/{sn}';
  el.mqPset.value = '/sys/thing/gw/property/set/{sn}';
  el.mqPget.value = '/sys/thing/gw/property/get/{sn}';
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
      { addr: 0, count: 2, name: 'sensor1', alias: '传感器1', dtype: 'uint16' },
      { addr: 2, count: 2, name: 'sensor2', alias: '传感器2', dtype: 'int16' },
      { addr: 4, count: 2, name: 'temp', alias: '温度', dtype: 'float32' }
    ]
  },
  mqtt: { host: 'test.mosquitto.org', port: 1883, user: '', pass: '', ssl: false,
          pub_topic: '/sys/thing/node/property/post/{sn}',
          sub_topic: '/sys/thing/gw/config/get/{sn}',
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
  // 平台配置拉取 mock：发起后先 connecting，再 waiting，最后 done
  else if (line === 'W:PULLCFG') { MOCK.pullN = 0; resp = 'RET:PULLCFG=started'; }
  else if (line === 'R:PULLCFG') {
    MOCK.pullN = (MOCK.pullN || 0) + 1;
    if (MOCK.pullN < 3) {
      resp = 'RET:PULLCFG=' + JSON.stringify({ state: 'connecting', msg: '' });
    } else if (MOCK.pullN < 5) {
      resp = 'RET:PULLCFG=' + JSON.stringify({ state: 'waiting', msg: '' });
    } else {
      const regs = [
        { addr: 16, count: 1, name: 'Ua', alias: '电压', dtype: 'uint16' },
        { addr: 15, count: 1, name: 'PT', alias: 'PT1', dtype: 'uint16' },
        { addr: 14, count: 1, name: 'CT', alias: 'CT1', dtype: 'uint16' }
      ];
      resp = 'RET:PULLCFG=' + JSON.stringify({
        state: 'done', msg: '',
        poll: { baud: 9600, databits: 8, stopbits: 1, parity: 0, slave: 1, regs: regs },
        skipped: [],
        mqtt: {
          pub: '/sys/thing/node/property/post/' + (MOCK.sn || '11802026092600016') + '-1',
          sub: '/sys/thing/gw/function/get/' + (MOCK.sn || '11802026092600016')
        }
      });
    }
  }
  else if (line === 'R:MODE') resp = 'RET:MODE=' + JSON.stringify(mockModeStat());  else if (line === 'R:SNIFFCFG') resp = 'RET:SNIFFCFG=' + JSON.stringify({
    cfg: { baud: MOCK.cfg.baud, databits: MOCK.cfg.databits,
           parity: MOCK.cfg.parity, stopbits: MOCK.cfg.stopbits }, src: 'fskv'
  });
  else if (line === 'R:MQTT') resp = 'RET:MQTT=' + JSON.stringify({
    cfg: MOCK.mqtt,
    pub: '/sys/thing/node/property/post/VK20260925001',
    sub: '/sys/thing/gw/config/get/VK20260925001',
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
                  dtype: 'uint16' }));
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
