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
  mqSnap: null,        // MQTT 表单+首页 4 个 MQTT 输入框上次「干净」快照。
                       // 含自动档下被 .manual-only 藏掉的那几项 —— 切档位时
                       // setManualMode 会重新取基线，所以不会误报脏
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
  autoClientId: '',    // 首页 ClientID 框里当前显示的"设备自动拼的那个值"。
                       // 保存时拿它判断用户到底改没改过，没改就发空串，
                       // 见 saveHomeMqtt()（R1）
  frames: [],          // 最近解译帧
  infer: null,         // R:INFER 返回的推断结果
  detected: null,      // R:AUTODETECT 识别出的通讯参数（仅本次会话，未写配置）
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
  hMqUser: $('hMqUser'), hMqClientId: $('hMqClientId'),
  hMqClientIdHint: $('hMqClientIdHint'),
  hMqPass: $('hMqPass'), btnHomeMqttPassEye: $('btnHomeMqttPassEye'),
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
  // 发布/订阅 Topic 保留在「MQTT 连接」面板（R1），随手动/自动开关切只读。
  // hello/服务调用/属性设置/属性查询 4 条 topic 已从界面和设备端配置项一并
  // 删除（设备走固定平台常量），所以这几个键不再注册
  mqPub: $('mqPub'), mqSub: $('mqSub'), mqInterval: $('mqInterval'),
  mqAllowNoSn: $('mqAllowNoSn'),
  // MQTT 会话管理：select（离线自动销毁=0 / 持久会话=1），不是开关
  mqKeepSession: $('mqKeepSession'),
  // 报文页
  btnFrameRefresh: $('btnFrameRefresh'), btnFrameClear: $('btnFrameClear'),
  frameFilter: $('frameFilter'), frameAuto: $('frameAuto'), frameLog: $('frameLog'),
  btnInfer: $('btnInfer'), inferTbody: $('inferTbody'),
  inferHint: $('inferHint'),
  btnAutoDetect: $('btnAutoDetect'), detectHint: $('detectHint'),
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
    // hello/服务调用/属性设置/属性查询 4 条 topic 已从界面和设备端配置项
    // 一并删除（设备走固定平台常量），只剩发布/订阅两条仍由本页配置
    pub: g(el.mqPub), sub: g(el.mqSub), iv: g(el.mqInterval),
    noSn: c(el.mqAllowNoSn), keep: g(el.mqKeepSession),
    hHost: g(el.hMqHost), hPort: g(el.hMqPort), hPass: g(el.hMqPass),
    hCid: g(el.hMqClientId)
  });
}

function snapMqClean() { S.mqSnap = mqSnap(); refreshMqDirty(); }

const MQ_TOPIC_IDS = ['mqPub', 'mqSub'];

// 每行 topic 右边跟一句"是谁定的"，比看主按钮更直接
function mqTopicHints() {
  const H = S.mqManual ? '手动' : '设备拼';
  const ids = ['mqPubHint', 'mqSubHint'];
  ids.forEach(id => { if (el[id]) el[id].textContent = H; });
}

//---------------------------------------------------------------------
// Topic 手动/自动切换 = 建连档位切换
//   自动（默认）：用户名/密码/ClientID/发布/订阅 Topic 全部归设备管
//              —— 用户名固定 SN，密码用首页那份 MQTT凭证密码，Topic 用
//              默认模板自动拼。这几项整行藏掉（.manual-only），但「保存」
//              按钮两档都在：自动档还有地址/端口/SSL/周期/会话/no_SN 可改。
//   手动：      那几项显示出来，Topic 可编辑，保存时连用户名/密码一起下发，
//              设备先清掉自动拼的那套再写这套，然后按这套建连上报。
// 注意：开手动档是保存时才生效（用户填完再点「保存」）；
// 关手动档是当场生效 —— 屏幕上那几个手动档的值会被自动档顶掉，
// 所以关档必须自己把指令发下去（见下面 btnManualCfg.onclick）
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
  // R2: 手动档专属的行 + 「保存」按钮随档位整行显隐。用 body 上的 class
  // 驱动（CSS 里 body:not(.mq-manual) .manual-only），比逐个写
  // style.display 干净：.form-row 的 flex 不会被内联样式盖掉
  document.body.classList.toggle('mq-manual', S.mqManual);
  el.btnManualCfg.textContent = S.mqManual ? '关闭手动配置' : '手动配置';
  el.btnManualCfg.classList.toggle('on', S.mqManual);
  el.btnManualCfg.title = S.mqManual
      ? '关闭后设备改用 SN + 首页凭证密码 + 默认模板'
      : '手动配置：用本页填的用户名/密码/Topic 建连';
  syncPullCfgBtn();
  mqTopicHints();
  // 两种模式下输入框里放的东西不一样：自动=成品(SN 已拼)，手动=模板(带 {sn})。
  // 切过去就得顺手把内容也换掉，否则用户会拿成品去存，把 {sn} 模板存死成固定值
  if (opts.refill !== false) {
    const c = (S.mqtt && S.mqtt.cfg) || {};
    if (S.mqManual) {
      el.mqPub.value = c.pub_topic || '';
      el.mqSub.value = c.sub_topic || '';
    } else {
      el.mqPub.value = (S.mqtt && S.mqtt.pub) || '';
      el.mqSub.value = (S.mqtt && S.mqtt.sub) || '';
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

// 轮询等识别结果用的延时。setTimeout 版而不是忙等 —— 忙等会把 UI 线程占住,
// 期间连"取消"按钮都点不动
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

// Lua 空表经 json.encode 出来是 {} 而不是 [], JSON.parse 后是对象不是数组。
// readCfg 那里已经踩过一次(regs 为空), 凡是设备侧可能为空的数组字段都要过
// 这个: 直接当数组用, 空值时 .filter / .map 会 TypeError, 把一次成功的拉取
// 反报成"拉取失败"
function toArr(v) {
  return Array.isArray(v) ? v : [];
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

// 拉取配置按钮的可用性 = 串口开着 且 不在手动档。
// 手动档下设备只订用户填的那条 topic，不订 /sys/thing/gw/config/get/{sn}，
// 而平台应答只走那条。硬点只会白等 20s 建连 + 15s 超时，所以直接置灰
function syncPullCfgBtn() {
  const b = el.btnPullCfg;
  if (!b) return;
  b.disabled = !S.open || !!S.mqManual;
  b.title = S.mqManual
      ? '拉取配置需要平台 Topic：请先关闭「手动配置」'
      : '从 MQTT 平台拉取 485 配置并回填表单，需检查后点保存配置才生效';
}

function setPortState(open, path) {
  S.open = open;
  el.btnOpen.textContent = open ? '关闭串口' : '打开串口';
  el.stPort.textContent = open ? (path || S.port) : '未连接';
  el.stPort.style.color = open ? '#0a7d2c' : '#666';
  [el.btnReadInfo, el.btnReadCfg, el.btnPullCfg, el.btnSaveCfg, el.btnReadVal,
   el.btnHomeMqttSave].forEach(b => b.disabled = !open);
  syncPullCfgBtn();
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
    // 老固件没有 R:INFO，退回 R:ID（一行里带 imei/uid/sn/state/lock）
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
    if (Array.isArray(d) || (d && typeof d === 'object')) {
      S.regs = toArr(d);
      renderRegTable();
      status('配置已读取：' + S.regs.length + ' 个寄存器', true);
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
  // 手动档下设备只订用户填的那一条 topic，不订 config/get，平台应答
  // 进不来。这里先拦住说清原因，别让用户白等 20s 建连 + 15s 超时
  if (S.mqManual) {
    const msg = '拉取配置需要平台 Topic，请先关闭「手动配置」';
    status(msg, false);
    toast(msg);
    return;
  }
  if (!await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  S.pullBusy = true;
  const btn = el.btnPullCfg;
  const oldText = btn ? btn.textContent : '';
  if (btn) { btn.textContent = '拉取中…'; btn.disabled = true; }
  const restore = () => {
    S.pullBusy = false;
    if (btn) { btn.textContent = oldText; }
    syncPullCfgBtn();
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
    const skipped = toArr(d.skipped).length;
    const n = toArr(d.poll && d.poll.regs).length;
    // 平台把中文 name 按 GBK 下发时设备判为非法 UTF-8, 会自动把别名退回 id。
    // 必须说出来, 否则用户只会看见别名栏莫名其妙变成了 id
    const renamed = toArr(d.renamed).filter(x => typeof x === 'string' && x.trim());
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
  if (p.regs) {
    S.regs = toArr(p.regs);
    renderRegTable();
  }
  if (d.mqtt) {
    // 拉回的 MQTT 段带发布/订阅两个 topic 成品（SN 已代入），填进输入框。
    // 只填不存：topic 归设备管，用户改的只是地址/账号，与自动模式语义一致。
    // hello/服务调用/属性设置/属性查询 4 条已在设备端改为固定平台常量，
    // 不再随配置下发，这里也没有对应输入框
    if (d.mqtt.pub) el.mqPub.value = d.mqtt.pub;
    if (d.mqtt.sub) el.mqSub.value = d.mqtt.sub;
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
    const list = toArr(r.data);
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
  const rows = toArr(S.regs);
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
// pollpull 档的拉取进度文案。设备侧 ctrl.status() 的 pull 段来自
// iot.pull_status(): connecting(等 MQTT 建连) / helloing(发自述) /
// waiting(等平台下发) / done / fail。返回 null = 没在拉, 由调用方显示"运行中"
function pullStateText(pull, pollRunning) {
  if (!pull || !pull.state) return pollRunning ? null : '待拉取';
  if (pull.state === 'done' || pollRunning) return null;
  if (pull.state === 'fail') return '拉取失败：' + (pull.msg || '');
  if (pull.state === 'connecting') return '拉取中（连接 MQTT）…';
  if (pull.state === 'helloing') return '拉取中（自述 hello）…';
  if (pull.state === 'waiting') return '拉取中（等平台下发）…';
  return '拉取中…';
}

function renderMode() {
  const st = S.modeStat || {};
  const devMode = st.mode || 'idle';        // 设备当前模式（权威）
  const shown = S.modePending || devMode;   // 有待应用选择时优先显示它
  S.mode = devMode;                         // S.mode 始终跟设备走，别处据此判断 sniff
  el.stMode.textContent = devMode;
  // pollpull 档: 轮询起没起决定卡片状态显示"运行中"还是"拉取中"。
  // 必须在下面 forEach 之前算 —— 回调是同步执行的, const 声明在后面就是
  // 暂时性死区, 直接 ReferenceError 把整个 renderMode 打挂
  const pollRunning = !!((st.poll || {}).running);
  // 卡片选中态：有待应用选择就高亮它，否则高亮设备当前模式
  // 模式名直接从 k 推导（idle/poll/pollpull/sniff），不读 data-mode 属性：
  // 少一次 DOM 读取，也不依赖属性是否被正确设置。
  ['Idle', 'Poll', 'Pollpull', 'Sniff'].forEach(k => {
    const dm = k.toLowerCase();       // idle / poll / pollpull / sniff，与卡片 data-mode 一致
    const c = $('mc' + k);
    if (c) c.classList.toggle('active', dm === shown);
    // 卡片状态行：让用户看清"这是设备现状"还是"我选的还没应用"
    const stEl = $('ms' + k);
    if (stEl) {
      const isPending = S.modePending && dm === S.modePending && dm !== devMode;
      if (isPending) stEl.textContent = S.modeSwitching ? '切换中…' : '待应用';
      else if (dm === devMode) {
        // pollpull 的卡片状态要能看出"配置拉到没": 拉取是异步的(最坏 35s),
        // 那期间模式已经是 pollpull 但轮询还没起, 只显示"运行中"会误导
        if (dm === 'pollpull') {
          stEl.textContent = pullStateText(st.pull, pollRunning) || '运行中';
        } else {
          stEl.textContent = (devMode === 'idle' ? '当前' : '运行中');
        }
      }
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
  // 配置来源: 让用户看清当前采的是手配那份还是平台那份。两套配置是独立的,
  // 混在一起显示"poll"根本分不出, 所以才单列一个格子
  setKv('mCfgSrc', devMode === 'poll' ? '手动配置（ds_poll）'
    : devMode === 'pollpull' ? '平台拉取（ds_pull）' : '--');
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

  // sniff 页的「已识别/正在识别」提示也由这里驱动: R:MODE 的 mon 段带
  // detecting/detect_round/detect_fail, 5s 轮询就能让用户看到识别进度,
  // 不用他自己去点按钮问。两个渲染函数互斥, 见各自的注释
  if (m.detecting) {
    renderDetecting(m);
  } else if (devMode === 'sniff') {
    // 刷新页面后 S.detected 是空的, 但设备还记着上一轮的结果(mon.status 的
    // detected 段) —— 拿它兜底, 否则用户会看到"已识别"凭空消失
    if (!S.detected && m.detected && m.detected.baud != null) S.detected = m.detected;
    if (S.detected) renderDetected();
    else el.detectHint.textContent = '';
  } else {
    S.detected = null;      // 离开 sniff 就作废: 下次进去会重新识别
    el.detectHint.textContent = '';
  }
  syncTabs();
}

//=====================================================================
// 栏目随运行模式显隐
//   idle  → 只有 首页 / 运行模式
//   poll  → 首页 / 运行模式 / poll模式
//   pollpull → 首页 / 运行模式 / poll模式（拉取档也要能看/改配置）
//   sniff → 首页 / 运行模式 / sniff模式
// poll 与 sniff 是两种互斥的总线用法，设备同一时刻只跑一种，另一个页面留在
// 栏目上只会让人以为它也在工作。设备没接总线时尤其容易误点进去看一片空。
// 用 display 藏掉而不删 DOM：配置项和表单状态都还在，切回模式即原样恢复
//=====================================================================
function syncTabs() {
  const mode = S.mode || 'idle';
  // pollpull 归到 poll 页: 拉取档一样要看寄存器表和 MQTT 状态, 只是配置
  // 来源不同(平台 vs 手配)。少开一个栏目, 用户也不用理解"为什么两个 poll 页"
  const show = { tab0: true, tabMode: true,
    tabPoll: mode === 'poll' || mode === 'pollpull',
    tabSniff: mode === 'sniff' };
  Object.keys(show).forEach(id => {
    const t = document.querySelector('.tab-header .tab-item[data-tab="' + id + '"]');
    if (t) t.style.display = show[id] ? '' : 'none';
  });
  // 当前停留的栏目被藏掉时，落到首页 —— 否则界面会变成一片空白，
  // 用户以为程序卡死了（实际只是没有 active 的 tab-pane）
  const active = document.querySelector('.tab-header .tab-item.active');
  const activeId = active && active.getAttribute('data-tab');
  if (!show[activeId]) activateTab('tab0');
}

// 等 pollpull 的平台配置拉取落地。设备侧 ctrl.status() 的 pull 段来自
// iot.pull_status(): connecting -> helloing -> waiting -> done / fail。
// R:MODE 一秒钟轮一次就够(建连 20s + 等下发 15s 是设备侧的粗粒度等待,
// 前端问得太频只是占串口)
async function waitPullDone() {
  const t0 = Date.now();
  while (Date.now() - t0 < 55000) {
    await readMode();
    const pull = (S.modeStat && S.modeStat.pull) || {};
    const polling = !!((S.modeStat || {}).poll || {}).running;
    if (polling) {
      // 轮询起来了才是真的到位: 设备是在 save_pull 之后才 start("pull") 的
      status('平台配置已拉取并生效，开始轮询', true);
      toast('已切换到 poll（拉取配置）模式，开始轮询');
      await readCfg();       // 表单回填成平台那份, 否则用户看到的还是手配的
      // 进 pollpull 时设备已被 ctrl 强制切到 MQTT 自动档, 不重读的话
      // MQTT 页那个手动档开关还停在旧状态, 和设备实际用的档位不一致
      readMqtt(true);
      return true;
    }
    if (pull.state === 'fail') {
      status('平台配置拉取失败：' + (pull.msg || '未知原因'), false);
      toast('拉取失败：' + (pull.msg || '未知原因') + '，模式已退回，可重试');
      return false;
    }
    await sleep(1000);
  }
  status('拉取超时：平台未在 55 秒内下发配置', false);
  toast('拉取超时，可点「重新拉取」再试');
  return false;
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
    status('正在切换到 ' + (MODE_LABEL[mode] || mode) + ' …', true);
    await sendCmd(Protocol.Enc.setMode(mode), 'MODE', 8000);
    await readMode();            // 设备已确认，读回真实状态
    S.modePending = null;        // 确认成功，清除待应用标记
    renderMode();
    await readHome();
    // sniff 模式: W:MODE 只是"起了业务并开始后台识别", 不是识别完成。
    // 真正的到位要等 pollDetect 拿到参数 —— 那之前总线上看到的还是
    // 错参数的乱码, 所以这里必须说清"还在识别", 别让用户以为已经在听了
    if (mode === 'sniff') {
      status('已进入旁听，正在识别通讯参数（最坏 21 秒，完成后自动开始旁听）…', true);
      const d = await pollDetect(25);
      if (d) {
        status('识别成功，开始旁听：' + serialDesc(d), true);
        toast('已识别 ' + serialDesc(d) + '，开始旁听');
      } else {
        status('识别未完成，设备会在后台每 3 秒重试直到认出来', false);
        toast('识别未完成，设备会自动重试；总线无流量时可检查 AB 线/从机');
      }
      readMode();
      return;
    }
    // pollpull: W:MODE 只保证"起了拉取握手", 轮询要等平台配置落地后才开始
    // (最坏 35s = MQTT 建连 20s + 等下发 15s)。期间模式已是 pollpull 但还
    // 没在采, 只提示"已切换"会让用户以为已经在轮询了
    if (mode === 'pollpull') {
      await waitPullDone();
      return;
    }
    // 切到 poll(手动配置)时 ctrl 会把设备 MQTT 档位强制切回手动档,
    // 不重读的话 MQTT 页的手动档开关和实际档位不一致
    if (mode === 'poll') readMqtt(true);
    status('已切换到 ' + (MODE_LABEL[mode] || mode) + ' 模式', true);
    toast('模式已切换：' + (MODE_LABEL[mode] || mode));
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
    // 别把 pollpull 这种内部模式名直接糊到用户脸上
    const label = MODE_LABEL[v] || v;
    status('开机默认模式已设为 ' + label + '（重启后生效）', true);
    toast('开机默认模式：' + label);
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
  // 否则字打到一半被冲掉。密码要另外传 cfg —— stat 段不含 pass
  fillMqHome(mq, S.mqtt && S.mqtt.cfg);
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

function fillMqHome(mq, cfg) {
  if (!el.hMqHost) return;
  // 有未保存改动时，5s 定时刷新不许覆盖首页这三个可编辑 MQTT 输入框。
  // fillOk 只挡"焦点正在里面"——用户点一下别处焦点就丢了，下一轮刷新
  // 照样把改了一半的地址/端口冲成设备旧值，而且毫无提示。
  // 切到别的标签页时 tab0 不可见，fillOk 本来就会挡住，两道一起才全覆盖
  if (!S.mqDirty) {
    if (fillOk(el.hMqHost)) el.hMqHost.value = mq.host || '';
    if (fillOk(el.hMqPort)) el.hMqPort.value = mq.port != null ? mq.port : 1883;
    // 自动档凭证密码从 S.mqtt.auto_pass 取(R:MQTT 应答缓存的), 不从
    // stat 段取: stat 每 5s 回一次, 设备从不在里面放密码, 免得明文满屏刷。
    // auto_pass 与手动档那个 cfg.pass 是两份独立的值, 拿错会把 5s 刷新
    // 刚填的凭证密码冲成手动档的值, 两页显示互相串味
    if (fillOk(el.hMqPass)) el.hMqPass.value = (S.mqtt && S.mqtt.auto_pass) || '';
    // R1: ClientID 默认就显示设备拼好的自动值(SN_), 不再给空框。
    // 但必须保住"没动过就发空串"的语义 —— 否则显示值一旦被保存就变成
    // 显式配置, 换 SN(重烧号)后不会自动跟着变了。
    // 做法: 把这次显示出来的自动值记在 S.autoClientId, 保存时若输入框
    // 内容正好等于它, 就发空串交还设备兜底(见 saveHomeMqtt)
    if (fillOk(el.hMqClientId)) {
      const autoCid = mq.client_id || '';
      el.hMqClientId.value = (cfg && cfg.client_id) || autoCid;
      if (!S.mqDirty) S.autoClientId = autoCid;
      if (el.hMqClientIdHint) {
        el.hMqClientIdHint.textContent = (cfg && cfg.client_id)
          ? '已手输覆盖设备自动值'
          : (autoCid ? '设备自动拼的值，可直接改；清空则恢复自动' : '自动生成；也可手输覆盖');
      }
    }
  }
  // 用户名列只读回显 SN —— 自动档的用户名固定是 SN, 不许手改。
  // 手动档填的别的用户名只在 MQTT 页显示, 不回首页(那栏是自动档配置)
  if (el.hMqUser) el.hMqUser.value = mq.device_id || '';
  if (el.hMqErr) {
    el.hMqErr.textContent = mq.reject_reason || '';
    el.hMqErr.style.color = '#c0392b';
  }
}

// 首页 = 自动档配置: 改地址/端口/MQTT凭证密码/ClientID。先读全量配置再
// 合并。凭证密码走独立的 auto_pass 键, 与手动档的 pass 分开, 否则两个
// 输入框会互相覆盖。
// manual_on 照设备当前值回写: 首页不该因为改了凭证密码就把用户的手动
// 模式悄悄关掉
async function saveHomeMqtt() {
  // 必须守卫：合并用的基线来自 R:MQTT（设备当前值），不是表单。
  // 如果用户在 MQTT 页改了 topic/用户名没保存，这里一保存就把那些改动冲掉了
  if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
  const host = el.hMqHost.value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  const port = parseInt(el.hMqPort.value, 10) || 1883;
  // username 不在这里给: 自动档的用户名固定是 SN, 由设备兜底, 首页塞值
  // 会把它写死成显式配置, 换设备就不跟着变了。
  // clientId 反过来: R1 起首页默认会显示设备拼好的自动值(SN_), 所以
  // "留空=自动"的语义要靠比对来判断 —— 内容正好等于自动值 = 用户没想
  // 覆盖, 发空串交还设备兜底; 否则发用户填的值
  const pass = el.hMqPass ? el.hMqPass.value.trim() : '';
  const cidRaw = el.hMqClientId ? el.hMqClientId.value.trim() : '';
  const cid = (cidRaw !== '' && cidRaw === S.autoClientId) ? '' : cidRaw;
  try {
    const r = await sendCmd(Protocol.Enc.mqtt(), 'MQTT', 4000);
    const c = (r.data && r.data.cfg) || {};
    if (r.data) { S.mqtt = r.data; renderMqtt(); }
    await sendCmd(Protocol.Enc.writeMqtt(Object.assign({}, c, {
      host: host, port: port, client_id: cid,
      // 只改自动档凭证；手动档的 user/pass 原样回带，不能被这里冲掉
      auto_pass: pass,
      manual_on: c.manual_on,
      // 共用字段也从表单带一份: 自动档下 MQTT 页的「保存」按钮是藏掉的，
      // 用户在那边改的上报周期/会话管理/no_SN 只能靠首页这下保存带走。
      // 不带的话表单值会被 c(设备现值)覆盖, 用户等于白改
      ssl: el.mqSsl.checked,
      interval_s: parseInt(el.mqInterval.value, 10) || 0,
      allow_no_sn: el.mqAllowNoSn.checked,
      keep_session: el.mqKeepSession.value === '1'
    })), 'MQTT', 5000);
    // 刚存进去的凭证密码/ClientID 不动 MQTT 页那两个框: 它们是另一份值
    // (手动档), 同步过去等于把两档配置搅混
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
      if (r.data.mqtt) {
        S.mqtt = Object.assign({}, S.mqtt, { stat: r.data.mqtt });
      }
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
    // user/client_id 留空是故意的: 设备兜底填 SN, 所以这里显示空属正常。
    // 实际生效值看首页那两个框(用户名只读/ClientID 可填)或下面的连接状态面板。
    // 发布/订阅 topic：自动态填设备拼好的成品(SN 已代入)，
    // 手动态填带 {sn} 的模板
    if (fillOk(el.mqPub)) {
      el.mqPub.value = S.mqManual ? (c.pub_topic || '') : (r.pub || '');
    }
    if (fillOk(el.mqSub)) {
      el.mqSub.value = S.mqManual ? (c.sub_topic || '') : (r.sub || '');
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
  setKv('mqStUser', s.user || s.device_id || s.sn || '');
  setKv('mqStDevId', s.device_id || s.sn || '');
  // 当前档次: 手动 = 用本页填的凭证+Topic；自动 = 首页那份凭证 + SN + 默认模板
  setKv('mqStMode', c.manual_on ? '手动配置' : '自动（设备拼接）', !!c.manual_on);
  setKv('mqStPub', r.pub || '');
  setKv('mqStSub', r.sub || '');
  setKv('mqStSubed', s.subscribed ? '是' : '否', !s.subscribed);
  // 订阅Topic 全量：conack 时设备实际订到的每一条。只列 topic 不列数，
  // 现场直接照着对 broker 上有没有这条订阅。
  // 这一行只在自动档显示（.auto-only）：手动档下用户只该看到自己填的那两条，
  // 平台那 4 条通道是设备内部订的，混在一起会让人以为手动配置没生效
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
    // 档位跟设备实际状态走: 页面刚打开/设备重启过, 按钮颜色不能还是上次
    // 会话里点的那个。只在状态确实不同时才切, 否则会把用户刚点的按钮顶回去
    if (S.mqtt && S.mqtt.manual_on !== undefined && !!S.mqtt.manual_on !== S.mqManual) {
      setManualMode(!!S.mqtt.manual_on, { refill: true });
    }
    snapMqClean();                 // 读完了，当前表单就是干净基线
  } catch (e) {
    setKv('mqStErr', '读取失败：' + e.message, true);
  }
}

async function saveMqtt() {
  const host = el.mqHost.value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  // 2 个 topic 都先按"留空回退默认"归一，再判 {sn}。
  // 必须用归一后的值判：拿原始值判的话，清空输入框会被误报成"不含 {sn}"，
  // 而实际发下去的是含 {sn} 的默认模板
  const PUB = '/sys/thing/node/property/post/{sn}';
  const SUB = '/sys/thing/gw/config/get/{sn}';
  const pubT = el.mqPub.value.trim() || PUB;
  const subT = el.mqSub.value.trim() || SUB;
  // {sn} 只是推荐（多台设备不撞 topic）。平台若要求固定格式
  // （如 /12/<sn>/property/post），用户直接把 SN 写进 topic 也放行。
  // 自动模式下两个 topic 不下发，这里的 {sn} 提示就没意义，跳过
  if (S.mqManual && !hasSnPh(pubT) && !hasSnPh(subT)) {
    if (!await askConfirm('发布/订阅 Topic 都不含 {sn} 占位符。\n若 topic 里没写设备 SN，多台设备会共用同一 topic 导致数据互相覆盖。\n确定继续吗？', 'Topic 未含 {sn}')) return;
  }
  const cfg = {
    host: host,
    port: parseInt(el.mqPort.value, 10) || 1883,
    ssl: el.mqSsl.checked,
    user: el.mqUser.value.trim(),
    pass: el.mqPass.value,
    client_id: el.mqClientId.value.trim(),
    // 留空时用设备端默认模板，两边必须一致。
    // 手动档关闭时不下发这两个键: 设备端会把它们连同手动凭证一起清空，
    // 只留默认模板，正好就是自动拼的那两条
    ...(S.mqManual ? {
      pub_topic: pubT,
      sub_topic: subT,
    } : {}),
    interval_s: parseInt(el.mqInterval.value, 10) || 0,
    // QoS 界面已移除，不再下发；设备端固定用 QoS 1
    allow_no_sn: el.mqAllowNoSn.checked,
    // select: '1'=持久会话  '0'=离线自动销毁（默认）
    keep_session: el.mqKeepSession.value === '1',
    // 当前档次。false 时设备端清空手动凭证和手动 topic，改回 SN 用户名
    // + 首页那份 MQTT凭证密码 + 默认模板
    manual_on: S.mqManual
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
// 也不抢输入框焦点（按钮是独立的 type="button"，点了焦点还在输入框）。
// 首页和 MQTT 配置页各有一个密码框，两个一起切才一致 ——
// 只切其中一个，另一页还掩着，看着像按钮坏了
function togglePassEye() {
  const show = el.mqPass.type === 'password';
  [el.mqPass, el.hMqPass].forEach(inp => {
    if (!inp) return;
    inp.type = show ? 'text' : 'password';
  });
  [el.btnMqttPassEye, el.btnHomeMqttPassEye].forEach(btn => {
    if (!btn) return;
    btn.classList.toggle('show', show);
    btn.title = show ? '隐藏密码' : '显示密码';
  });
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
    // 从站号是从报文里数出来的, 报文刷新了就得重算, 否则「已识别」提示里的
    // 从站号会一直停在点识别那一刻的快照上
    renderDetected();
  } catch (e) { /* 静默：可能未进 sniff 模式 */ }
}

async function doInfer() {
  try {
    const r = await sendCmd(Protocol.Enc.infer(), 'INFER', 4000);
    S.infer = r.data;
    renderInfer();
    if (toArr(S.infer && S.infer.regs).length) {
      status('推断出 ' + toArr(S.infer.regs).length + ' 个轮询项', true);
      // 不能提"应用到轮询配置": 那个按钮和 W:APPLYINFER 已经删了,
      // 推断结果只作参考, 由人工核对后自行配置(见 lua/README.md 配置隔离)
      toast('推断完成，结果仅供参考，请核对后自行配置');
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
  const regs = toArr(inf.regs);
  el.inferHint.textContent = regs.length
    ? '监听到 ' + toArr(inf.slaves).length + ' 个从机，共 ' + regs.length + ' 个轮询项'
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

//---------------------------------------------------------------------
// 总线诊断
//---------------------------------------------------------------------
const PARITY_NAME = { 0: '无(N)', 1: '偶(E)', 2: '奇(O)' };

// 从已加载报文里统计出现最多的从站号。sniff 是被动旁听, 没法"识别"从站号,
// 只能看总线上主机在访问谁 —— 所以这个值标注为"观测"而非"识别"。
// 没有报文时返回 null, 由调用方决定怎么显示
function observedSlave() {
  const cnt = {};
  let best = null, bestN = 0;
  for (const f of S.frames) {
    if (f.slave == null) continue;
    cnt[f.slave] = (cnt[f.slave] || 0) + 1;
    if (cnt[f.slave] > bestN) { bestN = cnt[f.slave]; best = f.slave; }
  }
  return best;
}

// 轮询等识别结果。设备侧 R:AUTODETECT 是非阻塞的: 立即回 BUSY 或上一次的结果,
// 真正的扫描在后台跑(最坏 21s, 失败还会每 3s 重来一轮直到成功)。
// 所以这里不能死等一条应答 —— 那会把命令分发循环占住, 前端别的指令全卡
async function pollDetect(maxSec) {
  for (let i = 0; i < maxSec; i++) {
    await sleep(1000);
    let r;
    try { r = await sendCmd(Protocol.Enc.autoDetect(), 'AUTODETECT', 4000); }
    catch (e) { continue; }               // 偶发超时: 下一轮再问, 不判失败
    const raw = typeof r.raw === 'string' ? r.raw : '';
    if (raw === 'BUSY') continue;         // 还在扫
    if (raw.indexOf('RET:FAIL') === 0) return null;   // 没进 sniff 模式等
    const d = r.data || {};
    if (d.baud != null) {
      // 4 个串口参数全存: 设备本来就返回 databits/stopbits。从站号不存 ——
      // 它不是识别出来的, 是从报文里观测的
      S.detected = { baud: d.baud, databits: d.databits, parity: d.parity, stopbits: d.stopbits };
      renderDetected();
      return d;
    }
  }
  return null;
}

// 手动「重新识别」。设备侧 request_detect() 会作废当前轮并从第一个候选重新扫,
// 所以识别中点它等于立刻重启一轮, 不用先停再进
async function autoDetect() {
  try {
    status('正在识别通讯参数…', true);
    const r = await sendCmd(Protocol.Enc.autoDetect(), 'AUTODETECT', 4000);
    const raw = typeof r.raw === 'string' ? r.raw : '';
    if (raw.indexOf('RET:FAIL') === 0) {
      status('识别失败：先进旁听模式（运行模式页选 sniff）', false);
      toast('识别失败：当前不在旁听模式');
      return;
    }
    // 头一次问就带回结果: 说明上一轮已经识别过了, 直接用
    const d = (r.data && r.data.baud != null) ? r.data : await pollDetect(25);
    if (!d) {
      // 25s 还没出结果 ≠ 失败: 设备会一直重试, 这里只告知"还没认出来"
      status('识别未完成，设备会在后台继续重试', false);
      toast('识别未完成，设备会自动重试直到认出来');
      return;
    }
    status('识别成功：' + serialDesc(d) + '（仅本次会话，未改配置）', true);
    toast('已识别 ' + serialDesc(d) + '（仅本次会话，未改配置）');
  } catch (e) {
    status('识别失败：' + e.message, false);
    toast('识别失败：21 组候选都没解出合法帧，查 AB 线/从机是否在报');
  }
}

// 串口参数的完整描述: 波特率 / 数据位 / 校验 / 停止位。
// 单独抽出来是因为 toast、status、detectHint 三处都要用同一份格式,
// 之前三处各拼各的, toast 里还把校验名插在数据位和停止位之间成了 "8无(N)1"
function serialDesc(d) {
  return (d.baud != null ? d.baud : '?') + ' / ' +
         (d.databits != null ? d.databits : '?') + ' 数据位 / ' +
         (PARITY_NAME[d.parity] || ('校验' + d.parity)) + ' / ' +
         (d.stopbits != null ? d.stopbits : '?') + ' 停止位';
}

function renderDetected() {
  const d = S.detected;
  if (!d || d.baud == null) { el.detectHint.textContent = ''; return; }
  // 从站号另起一段并标明"观测": 被动旁听拿不到从站号, 它是从报文里数出来的,
  // 和上面 4 个"识别"出来的参数不是一个性质, 含混写成一个"已识别"会误导
  const sl = observedSlave();
  el.detectHint.textContent = '已识别：' + serialDesc(d) +
    (sl != null ? ' · 观测到从站 ' + sl : ' · 从站未观测到（先听一会儿报文）');
}

// 识别进行中的提示。由 renderMode() 在读到 mon.detecting 时调用, 和
// renderDetected() 共用同一个 span, 所以两者互斥 —— 识别中不显示"已识别",
// 认出来了才显示
function renderDetecting(st) {
  const round = st.detect_round || 0;
  const fail = st.detect_fail || 0;
  el.detectHint.textContent = '正在识别通讯参数…（第 ' + round + ' 轮' +
    (fail > 0 ? '，已失败 ' + fail + ' 次' : '') +
    '，最坏 21 秒，完成后自动开始旁听）';
}

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
      // 手动档凭证 + 自动档凭证密码分两个键，与设备端一致
      pass: el.mqPass.value,
      client_id: el.mqClientId.value.trim(),
      pub_topic: el.mqPub.value.trim(),
      sub_topic: el.mqSub.value.trim(),
      interval_s: parseInt(el.mqInterval.value, 10) || 0,
      allow_no_sn: el.mqAllowNoSn.checked,
      keep_session: el.mqKeepSession.value === '1',
      auto: { pass: (S.mqtt && S.mqtt.auto_pass) || '' },
      manual_on: S.mqManual
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
        S.regs = toArr(regs);
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
          el.mqAllowNoSn.checked = !!d.mqtt.allow_no_sn;
          el.mqKeepSession.value = d.mqtt.keep_session ? '1' : '0';
          // 自动档凭证密码回首页那个框；档次按钮按导入的 manual_on 切
          if (el.hMqPass && d.mqtt.auto) el.hMqPass.value = d.mqtt.auto.pass || '';
          setManualMode(!!d.mqtt.manual_on, { refill: true });
          // hello/func/pset/pget 4 条已无输入框，导入时忽略
          // （设备端是固定平台常量，配置文件里带了也不生效）
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
 el.mqPub, el.mqSub, el.mqInterval, el.mqKeepSession, el.mqAllowNoSn,
 el.hMqHost, el.hMqPort, el.hMqPass, el.hMqClientId].forEach(e => {
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
// 设备侧模式名 -> 用户看得懂的中文。pollpull 是内部约定名(设备侧 ds_pull
// 配置槽的标志), 直接显示会把用户搞糊涂, 所有 toast/status/保存回显都走它
const MODE_LABEL = {
  idle: '空闲 idle',
  poll: 'poll（手动配置）',
  pollpull: 'poll（拉取配置）',
  sniff: '旁听 sniff'
};
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
// 立刻把手动档开关写给设备。读全量再合并: 共用字段(地址/端口/周期等)和
// 两份凭证都不能被这次写入冲掉。manual_on=false 时设备端会清空手动档的
// 凭证和 topic, 回落默认模板, 然后用 SN + 首页凭证密码重连
async function writeManualMode(on) {
  const r = await sendCmd(Protocol.Enc.mqtt(), 'MQTT', 4000);
  const c = (r.data && r.data.cfg) || {};
  if (r.data) S.mqtt = r.data;
  const patch = {
    // 共用字段从表单带一份: 自动档下「保存」按钮是藏掉的, 用户在 MQTT 页
    // 改的这几个值只能靠这次写入带走, 否则会被 c(设备现值)覆盖等于白改
    ssl: el.mqSsl.checked,
    interval_s: parseInt(el.mqInterval.value, 10) || 0,
    allow_no_sn: el.mqAllowNoSn.checked,
    keep_session: el.mqKeepSession.value === '1',
    manual_on: on,
  };
  if (!on) {
    // R1: ClientID 在界面上归手动档那一组(关闭时跟用户名/密码/Topic 一起
    // 藏掉)，所以关档必须把它一起清掉，否则设备 fskv 里留着手填的那份，
    // 首页接着显示它，永远回不到 B 模型的 SN_。
    // 这里显式发空串而不是依赖设备端 normalize —— client_id 是共用字段，
    // 首页在自动档下也能自定义它，设备端分不清"手动档残留"和"首页自己设的"。
    // 关档是一次明确的用户动作，由前端表态最稳
    patch.client_id = '';
  }
  await sendCmd(Protocol.Enc.writeMqtt(Object.assign({}, c, patch)), 'MQTT', 5000);
}

// 「手动配置」切的是建连档位：
//   点开(蓝)=手动，用户名/密码/ClientID/发布/订阅 Topic 显示出来自己填，
//             保存后设备先清掉自动拼的那套，再按这套建连上报
//   点关(灰)=那几项藏掉，设备改用 SN + 首页凭证密码。
//             关档是当场生效：屏幕上那几个手动档的值会被自动档顶掉，
//             所以必须自己把指令发下去，否则用户看到的和设备不一致
el.btnManualCfg.onclick = async () => {
  if (!S.mqManual) {
    // 开手动：可能有未保存改动，开着会丢
    if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
    setManualMode(true);
    status('已开启手动配置，可填用户名/密码/Topic，记得保存', true);
  } else {
    // 关手动：屏幕上那几个手动档的值会被自动档顶掉，同样要先问
    if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
    status('正在关闭手动配置并重连…', true);
    try {
      await writeManualMode(false);
      // setManualMode 内部的 snapMqClean 会把"刚写下去的档位"设为干净基线，
      // 这样关档不会留下一个永远消不掉的「未保存」标记
      setManualMode(false);
      status('已关闭手动配置，设备改用 SN + 首页凭证密码', true);
      toast('已切回自动档，设备重连中');
      await new Promise(res => setTimeout(res, 1500));
      await readMqtt(true);
      readHome();
    } catch (e) {
      status('切换失败：' + e.message, false);
      toast('切换失败：' + e.message);
    }
  }
};
el.btnMqttSave.onclick = saveMqtt;
el.btnMqttReport.onclick = reportNow;
el.btnMqttReconnect.onclick = mqttReconnect;
el.btnMqttPassEye.onclick = togglePassEye;
if (el.btnHomeMqttPassEye) el.btnHomeMqttPassEye.onclick = togglePassEye;
el.btnMqttReset.onclick = async () => {
  if (!await guardUnsaved(S.mqDirty, 'MQTT', '保存', () => { S.mqSnap = null; })) return;
  if (!await askConfirm('确定恢复 MQTT 默认配置？', '恢复默认配置')) return;
  // 恢复默认 = 回到自动档。但默认模板要下发就必须先切手动（自动模式下
  // saveMqtt 把 topic 从 payload 里省掉），所以这里借用一下手动档把默认值
  // 写下去，写完立刻调 writeManualMode(false) 让设备清掉手动档内容，
  // 正好回到"SN + 首页凭证密码 + 默认模板"
  if (!S.mqManual) setManualMode(true, { snap: false });
  // 与设备端 mqttcfg.default 保持一致(见 lua/iot/mqttcfg.lua 的注释):
  // 默认指向本项目 V3 平台, 不是 mosquitto 测试盘
  el.mqHost.value = 'dz.voltkun.com';
  el.mqPort.value = 1883;
  el.mqSsl.checked = false;
  // username/clientId 都留空即由设备兜底: 自动档 username 用裸 SN,
  // clientId 用 SN 加下划线(平台 B 模型)
  el.mqUser.value = '';
  // 两档凭证密码都恢复产品级默认值, 首页那个框一起复位,
  // 否则恢复后两页显示不一致
  el.mqPass.value = 'VKBOXGW2026KEY';
  if (el.hMqPass) el.hMqPass.value = 'VKBOXGW2026KEY';
  el.mqClientId.value = '';
  el.mqPub.value = '/sys/thing/node/property/post/{sn}';
  el.mqSub.value = '/sys/thing/gw/config/get/{sn}';
  el.mqInterval.value = 60;
  el.mqAllowNoSn.checked = false;
  el.mqKeepSession.value = '0';     // 离线自动销毁（与设备默认一致）
  // hello/func/pset/pget 4 条已无输入框（设备端是固定平台常量），无需复位。
  // 首页 ClientID 一起清空 (清空 = 交还设备自动用 SN 拼)
  if (el.hMqClientId) el.hMqClientId.value = '';
  try {
    // 借手动档把默认模板写下去
    await saveMqtt();
    // 再显式关回自动档: 上面那下 manual_on 还是 true(借来的),
    // 不补这一下设备就停在手动档了
    await writeManualMode(false);
    setManualMode(false);
    status('已恢复默认配置，设备正在重连', true);
    toast('已恢复默认');
    await new Promise(res => setTimeout(res, 1500));
    await readMqtt(true);
    readHome();
  } catch (e) {
    status('恢复默认失败：' + e.message, false);
    toast('恢复默认失败：' + e.message);
  }
};

// 报文页
el.btnFrameRefresh.onclick = readFrames;
el.btnFrameClear.onclick = () => { S.frames = []; renderFrames(); renderDetected(); };
el.frameFilter.onchange = renderFrames;
el.btnInfer.onclick = doInfer;
el.btnAutoDetect.onclick = autoDetect;
el.btnBusSniff.onclick = busSniff;
el.btnTx.onclick = txHex;

// 主标签页切换。抽成 activateTab 是给 syncTabs 复用：栏目被模式藏掉时
// 也要走同一条路切回去，两处各写一份必然走偏
function activateTab(tabId) {
  const items = document.querySelectorAll('.tab-header .tab-item');
  items.forEach(t => t.classList.toggle('active', t.getAttribute('data-tab') === tabId));
  document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
  const pane = $(tabId);
  if (pane) pane.classList.add('active');
  // 切到报文页时立即拉一次
  if (tabId === 'tabSniff' && S.open && S.mode === 'sniff') readFrames();
}

const tabItems = document.querySelectorAll('.tab-header .tab-item');
tabItems.forEach(item => {
  item.onclick = function () {
    activateTab(this.getAttribute('data-tab'));
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

// 档位初始化：打开页面就按默认(自动档)把 .manual-only 那几行藏掉。
// 不这么做的话，第一批 R:MQTT 应答回来前那半秒里，用户名/密码/ClientID/
// Topic/保存会先闪一下再消失
setManualMode(S.mqManual);

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
  detecting: false,   // 预览用: 下一次 R:AUTODETECT 先回一次 BUSY
  pulling: false,     // 预览用: pollpull 的假拉取进行中(见 mockModeStat)
  cfg: {
    baud: 9600, databits: 8, parity: 0, stopbits: 1, slave: 1,
    interval_ms: 3000, timeout_ms: null,
    regs: [
      { addr: 0, count: 2, name: 'sensor1', alias: '传感器1', dtype: 'uint16' },
      { addr: 2, count: 2, name: 'sensor2', alias: '传感器2', dtype: 'int16' },
      { addr: 4, count: 2, name: 'temp', alias: '温度', dtype: 'float32' }
    ]
  },
  // 手动档（MQTT 配置页）+ 自动档（首页）两份凭证
  mqtt: { host: 'dz.voltkun.com', port: 1883, user: '', pass: '', ssl: false,
          pub_topic: '/sys/thing/node/property/post/{sn}',
          sub_topic: '/sys/thing/gw/config/get/{sn}',
          interval_s: 60, allow_no_sn: false, keep_session: false,
          auto: { pass: 'VKBOXGW2026KEY' }, manual_on: false },
  published: 0
};

function mockModeStat() {
  const m = MOCK.mode;
  // pollpull 也要算"在跑 poll": 它是拉取档, 轮询行为与 poll 相同, 只是配置
  // 来源不同。少了这个分支, 浏览器预览时 pollpull 卡片永远显示"待拉取"
  const isPoll = (m === 'poll' || m === 'pollpull');
  return {
    mode: m, busy: m !== 'stop' && m !== 'idle',
    // poll_src/pull_ready 与设备 ctrl.status() 对齐, 前端据此显示"配置来源"
    poll_src: isPoll ? (m === 'pollpull' ? 'pull' : 'poll') : null,
    pull_ready: 'fskv',
    pull: m === 'pollpull' ? { state: MOCK.pulling ? 'waiting' : 'done', msg: '' } : null,
    poll: { running: isPoll, gen: isPoll ? 1 : 0, regs: MOCK.cfg.regs.length,
            slave: MOCK.cfg.slave, baud: MOCK.cfg.baud, interval: MOCK.cfg.interval_ms,
            resp_cap: MOCK.cfg.timeout_ms == null ? 500 : MOCK.cfg.timeout_ms,
            write: { queued: 0, done: 0, fail: 0, last_err: '', qmax: 8 } },
    mon: { running: m === 'sniff', gen: m === 'sniff' ? 1 : 0, baud: MOCK.cfg.baud,
           frames: m === 'sniff' ? 24 : 0, reqs: m === 'sniff' ? 12 : 0,
           rsps: m === 'sniff' ? 11 : 0, errs: 0, paired: m === 'sniff' ? 10 : 0,
           orphans: m === 'sniff' ? 1 : 0, pending: 0, last_rx: 0, buf: 0,
           detecting: m === 'sniff' && MOCK.detecting,
           detect_round: m === 'sniff' ? 1 : 0, detect_fail: 0 },
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
  else if (line === 'R:MODE') resp = 'RET:MODE=' + JSON.stringify(mockModeStat());
  else if (line === 'R:MQTT') resp = 'RET:MQTT=' + JSON.stringify({
    cfg: MOCK.mqtt,
    auto_pass: MOCK.mqtt.auto.pass,
    manual_on: MOCK.mqtt.manual_on,
    pub: '/sys/thing/node/property/post/VK20260925001',
    sub: '/sys/thing/gw/config/get/VK20260925001',
    ready: true, err: null,
    stat: { want_run: true, connected: true, subscribed: true,
            device_id: 'VK20260925001', published: MOCK.published,
            user: 'VK20260925001', client_id: 'VK20260925001_',
            manual_on: MOCK.mqtt.manual_on,
            failed: 0, last_pub: 0, last_err: '', backoff: 1, dirty: false,
            sn: 'VK20260925001' }
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
    stat: { frames: 24, reqs: 12, rsps: 11, errs: 0, paired: 10, orphans: 1, detect_round: 0, detect_fail: 0 }
  });
  // 浏览器预览: 模拟"进了 sniff 但还在识别"这一小段, 让「正在识别」提示
  // 在没接真设备时也走得到(真设备由 mon.is_detecting() 给)
  else if (line === 'R:AUTODETECT' && MOCK.detecting) {
    MOCK.detecting = false;
    resp = 'RET:AUTODETECT=BUSY';
  }
  else if (line === 'R:AUTODETECT') resp = 'RET:AUTODETECT=' + JSON.stringify(
    { baud: 9600, databits: 8, stopbits: 1, parity: 0 });
  else if (line.indexOf('R:SNIFF=') === 0) resp = 'RET:SNIFF=3';
  else if (line.indexOf('W:TX=') === 0) resp = 'RET:TX=OK';
  else if (line.indexOf('W:MODE=') === 0) {
    MOCK.mode = line.slice(7);
    // 真设备是"进 sniff 就异步开始识别", 预览也照样演一遍
    MOCK.detecting = (MOCK.mode === 'sniff');
    // pollpull: 真设备进模式即起 hello 拉取(异步)。预览用 1.2s 假等一会,
    // 让"拉取中→已生效"的过渡在没接设备时也看得到
    MOCK.pulling = (MOCK.mode === 'pollpull');
    if (MOCK.pulling) {
      setTimeout(() => { MOCK.pulling = false; }, 1200);
    }
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
  else if (line.indexOf('W:MQTT=') === 0) {
    try {
      const o = JSON.parse(line.slice(7));
      Object.assign(MOCK.mqtt, o);
      resp = 'RET:MQTT=OK';
    } catch (e) { resp = 'RET:FAIL:MQTT:bad json'; }
  }
  else if (line === 'R:REPORT') { MOCK.published++; resp = 'RET:REPORT=OK'; }
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
