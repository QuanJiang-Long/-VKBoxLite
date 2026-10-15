//=====================================================================
// app.js - 渲染进程业务逻辑
// 依赖：protocol.js（Protocol 全局）、window.serial（preload 暴露）
// 浏览器预览模式：无 window.serial 时自动启用 mock，不影响界面联调
//
// 页面分工：
//   首页       —— 运行状态总览 + MQTT 服务器
//   运行模式   —— manual / pollpull / sniff / idle 互斥切换 + 开机默认模式
//   manual模式 —— 485 串口参数 + 寄存器表 + MQTT 连接与上报
//   sniff模式  —— 解译帧实时视图 + 轮询表推断 + 总线诊断
//=====================================================================

// 跟设备端对齐: 任何判定「当前是否手动档」/「当前是否拉取档」的地方都用 isManual(m)/isPlatform(m)
// 记录 3: 删 || 'poll' / || 'pollpull' 兼容。设备端 normalize_sys 限 4 值, 不会再返
// poll/pollpull, 前端收到任何历史别名都视作未知 (syncTabs / renderMode 自动兜底)
const isManual = (m) => m === 'manual';
const isPlatform = (m) => m === 'platform';

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
  bootSnap: null,      // 开机默认模式上次「干净」值 (selBootMode.value 字符串)
  bootDirty: false,    // 开机默认模式是否有未保存改动
  bootMode: null,      // 设备当前 boot_mode (R:BOOTMODE 应答, "运行状态总览" 卡片显示)
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
  // tabPoll 内的引用 (Step 2a 之前业务用这些, 现在仍保留作 fallback)
  btnReadCfg: $('btnReadCfg'), btnSaveCfg: $('btnSaveCfg'), btnPullCfg: $('btnPullCfg'),
  cfgSrcHint: $('cfgSrcHint'),
  selBaud: $('selBaud'), inpRound: $('inpRound'),
  inpSlave: $('inpSlave'), inpTimeout: $('inpTimeout'),
  btnReadVal: $('btnReadVal'), btnAddReg: $('btnAddReg'), paramTbody: $('paramTbody'),
  // Step 2i: 删 btnManualCfg / btnMqttReset (本面板就是手动配置, 有刷新了)
  btnMqttRefresh: $('btnMqttRefresh'), btnMqttSave: $('btnMqttSave'),
  btnMqttReport: $('btnMqttReport'),
  mqHost: $('mqHost'), mqPort: $('mqPort'), mqSsl: $('mqSsl'), mqUser: $('mqUser'),
  mqPass: $('mqPass'), mqClientId: $('mqClientId'),
  btnMqttPassEye: $('btnMqttPassEye'),
  mqPub: $('mqPub'), mqSub: $('mqSub'),
  mqInterval: $('mqInterval'),
  mqAllowNoSn: $('mqAllowNoSn'),
  mqKeepSession: $('mqKeepSession'),
  // ====== Step 2a: tabManual 内的 m- 前缀引用 ======
  mBtnReadCfg: $('mBtnReadCfg'), mBtnSaveCfg: $('mBtnSaveCfg'),
  // Step 2e+: manual 档 "重新拉取" 按钮藏掉 (manual 档不接平台), 也不建引用
  mCfgSrcHint: $('mCfgSrcHint'),
  mSelBaud: $('mSelBaud'), mInpRound: $('mInpRound'),
  mInpSlave: $('mInpSlave'), mInpTimeout: $('mInpTimeout'),
  mBtnReadVal: $('mBtnReadVal'), mBtnAddReg: $('mBtnAddReg'), mParamTbody: $('mParamTbody'),
  mBtnManualCfg: $('mBtnManualCfg'),
  mBtnMqttRefresh: $('mBtnMqttRefresh'), mBtnMqttSave: $('mBtnMqttSave'),
  mBtnMqttReport: $('mBtnMqttReport'), mBtnMqttReset: $('mBtnMqttReset'),
  mMqHost: $('mMqHost'), mMqPort: $('mMqPort'), mMqSsl: $('mMqSsl'), mMqUser: $('mMqUser'),
  mMqPass: $('mMqPass'), mMqClientId: $('mMqClientId'),
  mBtnMqttPassEye: $('mBtnMqttPassEye'),
  mMqPub: $('mMqPub'), mMqSub: $('mMqSub'),
  mMqInterval: $('mMqInterval'),
  mMqAllowNoSn: $('mMqAllowNoSn'),
  mMqKeepSession: $('mMqKeepSession'),
  // ====== Step 2a: tabPlatform 内的 p- 前缀引用 ======
  // Step 2c/2d: 平台档删 6 字段 (user/pass/ClientId/Pub/Sub/AllowNoSn) + 1 按钮
  // (pBtnManualCfg) + pBtnMqttSave/pBtnMqttReset/pBtnMqttPassEye (平台档不能改/不需要)
  // — 这些引用也不建了, 业务用不到
  // Step 2e+: 平台档 485 + 寄存器表 "保存配置" / "新增寄存器" 按钮藏掉
  // (pBtnSaveCfg / pBtnAddReg) — 也不建引用, 业务用不到
  pBtnReadCfg: $('pBtnReadCfg'), pBtnPullCfg: $('pBtnPullCfg'),
  pCfgSrcHint: $('pCfgSrcHint'),
  pSelBaud: $('pSelBaud'), pInpRound: $('pInpRound'),
  pInpSlave: $('pInpSlave'), pInpTimeout: $('pInpTimeout'),
  pBtnReadVal: $('pBtnReadVal'), pParamTbody: $('pParamTbody'),
  pBtnMqttRefresh: $('pBtnMqttRefresh'),
  pBtnMqttReport: $('pBtnMqttReport'),
  pBtnMqttReconnect: $('pBtnMqttReconnect'),
  pMqHost: $('pMqHost'), pMqPort: $('pMqPort'), pMqSsl: $('pMqSsl'),
  pMqInterval: $('pMqInterval'),
  pMqKeepSession: $('pMqKeepSession'),
  // ====== 共享元素 (仅在 tab0/tabSniff 用, 没拆) ======
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
  // sniff 页面简版 MQTT 配置 (只读 broker + 可改上报周期, 跟 sp-s2 共享 mqManual + mqDirty)
  snMqHost: $('snMqHost'),
  snMqPort: $('snMqPort'),
  snMqInterval: $('snMqInterval'),
  btnSnMqttRefresh: $('btnSnMqttRefresh'),
  btnSnMqttSave: $('btnSnMqttSave'),
  snMqttHint: $('snMqttHint'),
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

// Step 2a: E(prefix, id) helper — 取当前档位对应的元素引用
// 例: E('m', 'mqHost') = el.mMqHost,  E('p', 'mqHost') = el.pMqHost
// 业务调用前先按 S.mode 选 prefix:
//   const h = E(isManual(S.mode) ? 'm' : (isPlatform(S.mode) ? 'p' : ''), 'mqHost');
// Step 2b 开始在 readMqtt/renderMqtt 用上
// Step 2c 修: 元素不存在时返 null-stub (所有属性写都吞掉, 业务不用 if 保护)
// 否则 renderMqtt 内部 E('p','mqAllowNoSn').checked = ... 会让整个 renderMqtt 抛错,
// 后续 17 字段 setKvPre 全跑不到
const _nullStub = { value: '', textContent: '', checked: false, className: '', hidden: false, addEventListener: () => {} };
function E(prefix, id) {
  if (!prefix) return el[id] || _nullStub;                       // tabPoll (无前缀)
  const n = el[prefix + id[0].toUpperCase() + id.slice(1)];
  return n || _nullStub;
}

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
// Step 2q: radioVal/setRadio 加 pre 参, manual/platform tab 的 radio name
// 加 m-/p- 前缀 (HTML 同步改), 不再是 3 个 pane 共用同一组 name
// 之前 3 pane 同名 (name="databits"), document.querySelector 永远拿第 1 个
// (tabPoll), 切到 manual tab 看 radio 的 checked 状态是 tabPoll 的, 不是自己的
function radioVal(name, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = pre ? pre + '-' : '';
  const r = document.querySelector('input[name="' + p + name + '"]:checked');
  return r ? r.value : '';
}
function setRadio(name, val, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = pre ? pre + '-' : '';
  document.querySelectorAll('input[name="' + p + name + '"]').forEach(r => {
    r.checked = (r.value === String(val));
  });
}
function setKv(id, text, bad) {
  const n = $(id);
  if (!n) return;
  n.textContent = (text === null || text === undefined || text === '') ? '--' : String(text);
  n.className = bad ? 'bad' : '';
}
// Step 2b: 跟 setKv 一样, 但指定 m-/p- 前缀, 写对应 tab 内的元素
function setKvPre(pre, id, text, bad) {
  const fullId = pre ? (pre + id[0].toUpperCase() + id.slice(1)) : id;
  const n = $(fullId);
  if (!n) return;
  n.textContent = (text === null || text === undefined || text === '') ? '--' : String(text);
  n.className = bad ? 'bad' : '';
}
// Step 2e: cfgPrefix() 跟 mqttPrefix 同逻辑, 485 段 + 寄存器表 (selBaud/
// inpRound/inpSlave/inpTimeout/paramTbody 等) 走 m/p 拆分
function cfgPrefix() {
  if (isManual(S.mode)) return 'm';
  if (isPlatform(S.mode)) return 'p';
  return '';
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
function cfgSnap(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  const rows = [];
  if (tbody.querySelectorAll) {
    tbody.querySelectorAll('tr').forEach(tr => {
      if (!tr.querySelector('.c-addr')) return;          // 空表提示行
      rows.push([
        tr.querySelector('.c-addr').value,
        tr.querySelector('.c-type').value,
        tr.querySelector('.c-count').value,
        tr.querySelector('.c-name').value,
        tr.querySelector('.c-alias').value
      ].join('|'));
    });
  }
  return JSON.stringify({
    b: E(pre, 'selBaud').value, db: radioVal('databits', pre), p: radioVal('parity', pre),
    sb: radioVal('stopbits', pre), sl: E(pre, 'inpSlave').value,
    iv: E(pre, 'inpRound').value, to: E(pre, 'inpTimeout').value, r: rows
  });
}

// 表单被程序改过（读配置 / 保存 / 拉取 / 导入）之后调用：当前状态记为干净
function snapClean(pre) { S.cfgSnap = cfgSnap(pre); refreshCfgDirty(pre); }

function refreshCfgDirty(pre) {
  // cfgSnap 还是 null 说明从没读过配置，没有可比基线，不算脏
  if (pre === undefined) pre = cfgPrefix();
  const d = S.cfgSnap !== null && cfgSnap(pre) !== S.cfgSnap;
  if (d === S.cfgDirty) return;
  const wasDirty = S.cfgDirty;
  S.cfgDirty = d;
  el.btnSaveCfg.textContent = d ? '保存配置 *' : '保存配置';
  el.btnSaveCfg.classList.toggle('dirty', d);
  // Step 2p: manual tab 的 mBtnSaveCfg 也加 dirty 切换
  // 平台档没保存按钮 (pBtnSaveCfg 已注释, 平台档只读), 不切
  if (el.mBtnSaveCfg) {
    el.mBtnSaveCfg.textContent = d ? '保存配置 *' : '保存配置';
    el.mBtnSaveCfg.classList.toggle('dirty', d);
  }
  if (d) status('有未保存的更改，点「保存配置」生效', false);
  // 由脏变干净时要清掉 status —— 程序填表 (readCfg/readCfgSilent/
  // pullCfg 内的 fillFormFromPlatform) 会先填成"脏"再 snapClean, 不清就
  // 让 status bar 一直挂着那条提示, 看着像用户改了东西其实没改
  else if (wasDirty && el.stMsg && el.stMsg.textContent === '有未保存的更改，点「保存配置」生效') {
    el.stMsg.textContent = '';
    el.stMsg.className = '';
  }
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
// Step 2n: 改用 E(pre, 'mqXxx') 而不是 el.mqXxx, 档位决定取哪个 input:
//   manual 档读 mMqXxx, platform 档读 pMqXxx, poll 档读 mqXxx (=el.mqXxx)
// 之前只读 el.mqXxx (=tabPoll), 切到 manual/platform tab 改了 5 字段
// 也不会被 dirty 识别, 保存按钮不变色


// 开机默认模式 dirty 提示: 跟 mqDirty 同模式, 改 selBootMode → 按钮变
// "保存 *", 点保存成功后清回。snapBootClean 在页面初始化 + readBootMode
// 应答后调一次 (取 selBootMode.value 当基线, 之后改动才报脏)。
function snapBootClean() {
  if (!el.selBootMode) return;
  // 同步 selBootMode 跟设备值: 启动时 HTML 默认 'idle', 但设备 boot_mode
  // 可能是别的 (上次用户改过没保存 / 切档等), 把 selBootMode 拉到设备值
  if (S.bootMode && S.bootMode !== el.selBootMode.value) {
    el.selBootMode.value = S.bootMode;
  }
  S.bootSnap = el.selBootMode.value;
  refreshBootDirty();
}
function refreshBootDirty() {
  if (!el.btnSaveBoot) return;
  const d = S.bootSnap !== null && el.selBootMode.value !== S.bootSnap;
  if (d === S.bootDirty) return;
  S.bootDirty = d;
  el.btnSaveBoot.textContent = d ? '保存 *' : '保存';
  el.btnSaveBoot.classList.toggle('dirty', d);
  if (d) status('开机默认模式已更改，点「保存」生效（重启后生效）', false);
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

// 拉取配置按钮: 只在「poll（拉取配置）」模式出现。
// 手动配置模式下整行藏掉而不是置灰 —— 手动档用自己手配的寄存器表, 页面上
// 摆一个点不动的拉取按钮只会让人猜"是不是我哪里没配对"。
// （设备侧手动档不订平台 config/get topic, 硬点只会白等 35s 超时）
function syncPullCfgBtn() {
  const b = el.btnPullCfg;
  if (!b) return;
  // 串口没开也藏: 指令发不出去, 摆着也是干扰
  const show = S.open && isPlatform(S.mode);
  b.style.display = show ? '' : 'none';
  b.disabled = !show;
  b.title = '从 MQTT 平台重新拉取 485 配置到「拉取配置」槽（ds_pull）';
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
// 配置来源提示条。拉取档下 R:CFG 返回的是平台那份（ds_pull），而保存也写
// 同一个槽（W:CFG 按模式选槽，见 cmd.lua），所以这里是"所见即所存"，
// 只是要提醒平台下次下发会盖掉本地改动。不说明白的话用户以为自己在改一份
// 独立的副本，平台一推发现改动没了
// sniff 也走这个 hint: 颜色更冷, 文案"线程没真跳人动的"
//
// 三档: pull (拉取档下 ds_pull 已下发), default (拉取档下 ds_pull 还是默认,
// 平台没推过, 不填表单等推), sniff
function renderCfgSrcHint(slot) {
  if (!el.cfgSrcHint) return;
  const h = el.cfgSrcHint;
  if (slot === 'pull') {
    h.hidden = false;
    h.textContent = '当前显示的是平台拉取的配置（ds_pull）；平台下次下发会覆盖本地改动 ——本页只读';
    h.style.color = '#b06a00';
  } else if (slot === 'default') {
    h.hidden = false;
    h.textContent = '等待平台下发配置 ——本页只读';
    h.style.color = '#999';
  } else if (slot === 'sniff') {
    h.hidden = false;
    h.textContent = 'sniff 旁听模式 —— 配置由设备自动识别, 本页只读';
    h.style.color = '#888';
  } else {
    h.hidden = true;
    h.textContent = '';
  }
}

// pollpull / sniff 把 #sp-s1 整个面板锁住: input readonly, select/radio
// disabled, 「保存配置」/「新增寄存器」/每行「删除」全藏,「读取配置」
// 留着让他主动查 ds_pull 内容. 只有 poll（手动配置）档是编辑档.
// cfgSrcHint 也按 mode 给提示文案, 让用户一眼看出"这块不给你动".
// 锁档下 snapClean() 抹掉「保存配置 *"」橙色提示, 跟用户调
// "锁上了, 别惦记着保存" 一致
//
// pollpull 下的 cfgSrcHint 要看 S.cfgSrc 决定显示"等待"还是"已拉取",
// 但 setFormLocked 是 renderMode 5s 轮询调, 此时 S.cfgSrc 可能还没被
// readCfgSilent 设过. 这里看到 cfgSrcHint 已经是某种状态就不动, 让
// readCfgSilent 自己负责更新
function setFormLocked(locked) {
  const pane = $('sp-s1');
  if (!pane) return;
  pane.querySelectorAll('input, select, textarea').forEach(e => {
    // <select> 没有 readonly 属性 (HTML 规范), 只认 disabled. input/textarea 是 readonly
    // 之前 select 设 readOnly=true 是无效操作, dtype 下拉仍可点, 用户能偷偷改
    if (e.tagName === 'SELECT' || e.type === 'radio') e.disabled = locked;
    else e.readOnly = locked;
    e.classList.toggle('ro', locked);
  });
  const edit = !locked;
  if (el.btnSaveCfg) el.btnSaveCfg.style.display = edit ? '' : 'none';
  if (el.btnAddReg) el.btnAddReg.style.display = edit ? '' : 'none';
  pane.querySelectorAll('.btn-del').forEach(b => { b.style.display = edit ? '' : 'none'; });
  if (locked) snapClean();
  // pollpull 下若 cfgSrcHint 已显示 (readCfgSilent 跑过), 不动它; 否则
  // 给个 'default' 兜底(等待平台下发), 不让 hint 整轮不出现
  if (locked && isPlatform(S.mode) && el.cfgSrcHint && el.cfgSrcHint.hidden) {
    renderCfgSrcHint('default');
  } else if (locked && S.mode === 'sniff' && el.cfgSrcHint && el.cfgSrcHint.hidden) {
    renderCfgSrcHint('sniff');
  } else if (!locked) {
    renderCfgSrcHint(null);
  }
}

async function readCfg(quiet) {
  // 取消 S.mode 守卫: waitPullDone/pollpull 自动刷新都要走这条路径填表单
  // (平台 push 后也要用, 见 renderPushBanner). 「读取配置」按钮本身在
  // pollpull 档下保留 (让用户主动查 ds_pull), sniff/idle 档下隐藏,
  // 没必要按模式再拦
  if (!quiet && !await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  // Step 2e: 用 E(pre, ...) 写当前 tab 内的 485 段 + 寄存器表
  const pre = cfgPrefix();
  try {
    const rc = await sendCmd(Protocol.Enc.cfg(), 'CFG');
    const payload = rc.data;
    const c = (payload && payload.cfg) ? payload.cfg : payload;
    // 设备端按运行模式选槽: poll->ds_poll, pollpull->ds_pull
    renderCfgSrcHint(payload && payload.slot);
    if (c && typeof c === 'object') {
      S.cfg = c;
      // 正在编辑的表单项不能抢：用户可能在从站地址/间隔/超时里打字，
      // 读配置应答一到就把字冲掉，表现为"输入框改不动"。
      if (fillOk(E(pre, 'selBaud'))) E(pre, 'selBaud').value = String(c.baud || 9600);
      setRadio('databits', String(c.databits || 8), pre);
      setRadio('parity', String(c.parity != null ? c.parity : 0), pre);
      setRadio('stopbits', String(c.stopbits || 1), pre);
      // "485方向控制GPIO" 输入框已按需求移除。GPIO8 方向控制由设备端
      // 脚本固定处理（core/config.lua 的 UART_485_PIN），前端不再暴露。
      if (fillOk(E(pre, 'inpRound'))) E(pre, 'inpRound').value = c.interval_ms || 3000;
      if (fillOk(E(pre, 'inpSlave'))) E(pre, 'inpSlave').value = c.slave || 1;
      if (fillOk(E(pre, 'inpTimeout'))) E(pre, 'inpTimeout').value = (c.timeout_ms == null) ? '' : c.timeout_ms;
      // 首次进 pollpull 时 ds_pull 还是空的, R:CFG 会回 src='default',
      // 这条提示只对用户主动点「读取配置」有意义; 自动路径
      // (waitPullDone / renderPushBanner) 走 silent, 不弹, 否则切档就被
      // 一条「还没保存」的 toast 误导, 以为配置没生效
      if (payload && payload.src === 'default' && !quiet) {
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
      renderRegTable(pre);
      status('配置已读取：' + S.regs.length + ' 个寄存器', true);
    } else {
      status('配置已读取', true);
    }
    snapClean(pre);                    // 读完了，当前表单就是干净基线
  } catch (e) {
    status('读取配置失败：' + e.message, false);
    toast('读取配置失败：' + e.message);
  }
}

// pollpull 自动刷新用: 静默读 R:CFG + R:REG 填表单, 不弹 toast/status,
// 不动「未保存」标记 (snapClean 让填完是基线). 失败也静默, 不打扰横幅.
// 失败原因最可能是设备正忙或串口被占, 下一次 5s 刷新会再试
//
// src='default' 特例: ds_pull 是出厂默认, 平台还没下发. 不填, 避免切档
// 立刻点 poll tab 看到假数据; 改显示「等待平台下发…」, 等真正配置到达
// (走 renderPushBanner 路径) 再填
async function readCfgSilent() {
  const pre = cfgPrefix();   // Step 2e
  try {
    const rc = await sendCmd(Protocol.Enc.cfg(), 'CFG', 3000);
    const payload = rc.data;
    S.cfgSrc = payload && payload.src || null;
    const c = (payload && payload.cfg) ? payload.cfg : payload;
    if (S.cfgSrc === 'default') {
      renderCfgSrcHint('default');
      return;
    }
    if (c && typeof c === 'object') {
      S.cfg = c;
      if (fillOk(E(pre, 'selBaud'))) E(pre, 'selBaud').value = String(c.baud || 9600);
      setRadio('databits', String(c.databits || 8), pre);
      setRadio('parity', String(c.parity != null ? c.parity : 0), pre);
      setRadio('stopbits', String(c.stopbits || 1), pre);
      if (fillOk(E(pre, 'inpRound'))) E(pre, 'inpRound').value = c.interval_ms || 3000;
      if (fillOk(E(pre, 'inpSlave'))) E(pre, 'inpSlave').value = c.slave || 1;
      if (fillOk(E(pre, 'inpTimeout'))) E(pre, 'inpTimeout').value = (c.timeout_ms == null) ? '' : c.timeout_ms;
    }
    const rr = await sendCmd(Protocol.Enc.reg(), 'REG', 3000);
    const d = rr.data;
    if (Array.isArray(d) || (d && typeof d === 'object')) {
      S.regs = toArr(d);
      renderRegTable(pre);
    }
    snapClean(pre);
    renderCfgSrcHint('pull');
  } catch (e) { /* 静默: 失败不打扰, 下次再试 */ }
}

// 拉取配置：从平台拉 485 配置并回填表单（不自动保存，由用户点保存生效）
//   ① 有平台主动下发的待确认配置时，直接读设备已解析好的那份，
//      跳过 W:PULLCFG 握手（否则把已解析好的结果冲掉，白等 20s+15s）
//   ② 否则 W:PULLCFG 发起，轮询 R:PULLCFG 直到 done/fail
//   ③ done 后回填 串口参数 + 寄存器表 + MQTT 上报/下行 topic
async function pullCfg() {
  if (S.pullBusy) return;
  // 拉取链路要求设备订着平台的 /sys/thing/gw/config/get/{sn}，只有
  // poll（拉取配置）档才订这条（手动档只订用户填的那一条，见 build_subs）。
  // 在手动档下发只会白等 20s 建连 + 15s 超时，所以按模式拦，不按 mqManual 拦
  // —— mqManual 是 MQTT 页自己的档位开关，和 485 运行模式是两件事
  if (!isPlatform(S.mode)) {
    const msg = '拉取配置需要在「platform（拉取配置）」模式下进行，请先切换运行模式';
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
    fillFormFromPlatform(d, cfgPrefix());  // Step 2f: 传 pre, 填当前 tab 内的元素
    // 不用在这里切 MQTT 档位了: poll（拉取配置）模式下设备侧 ctrl 已经强制
    // 自动档(manual_on=false)，MQTT 页读一次就是这个状态
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

// 把平台拉回的配置填进表单。只填不存：W:CFG/W:MQTT 全由用户点保存触发
// Step 2f: 拆 m/p 分支, pre 由 pullCfg 传 cfgPrefix() 进来
function fillFormFromPlatform(d, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = d.poll || {};
  if (p.baud) E(pre, 'selBaud').value = String(p.baud);
  if (p.databits) setRadio('databits', String(p.databits), pre);
  if (p.parity != null) setRadio('parity', String(p.parity), pre);
  if (p.stopbits) setRadio('stopbits', String(p.stopbits), pre);
  if (p.slave) E(pre, 'inpSlave').value = p.slave;
  if (p.regs) {
    S.regs = toArr(p.regs);
    renderRegTable(pre);
  }
  if (d.mqtt) {
    // MQTT 段里已无 topic：发布/订阅两档都是设备固定平台常量，界面不显示
  }
}

// 收集串口配置。返回 { ok, cfg } 或 { ok:false, err }
// 单选钮没选中时 parseInt('') = NaN，绝不能让 NaN/null 流到设备端
// （设备 normalize 会整条拒绝，用户只看到一句"保存失败"却不知道原因）
function collectCfg(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const baud      = parseInt(E(pre, 'selBaud').value, 10);
  const databits  = parseInt(radioVal('databits', pre), 10);
  const parity    = parseInt(radioVal('parity', pre), 10);
  const stopbits  = parseInt(radioVal('stopbits', pre), 10);
  const slave     = parseInt(E(pre, 'inpSlave').value, 10);
  const interval  = parseInt(E(pre, 'inpRound').value, 10);
  const timeout   = E(pre, 'inpTimeout').value.trim();

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

function collectRegs(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  const out = [];
  if (!tbody.querySelectorAll) return out;
  tbody.querySelectorAll('tr').forEach(tr => {
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
  const pre = cfgPrefix();  // Step 2e: 用当前 tab 内的 485 + 寄存器表
  try {
    const c = collectCfg(pre);
    if (!c.ok) { toast(c.err); status('配置无效：' + c.err, false); return; }
    const cfg = c.cfg;
    const bad = badRegRow(pre);
    if (bad) { toast(bad); status('配置无效：' + bad, false); return; }
    const regs = collectRegs(pre);
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
      snapClean(pre);                  // 保存成功 = 表单和设备一致，清掉「未保存」标记
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
function badRegRow(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  if (!tbody.querySelectorAll) return null;
  const rows = tbody.querySelectorAll('tr');
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
    // Step 2p: 改用 E(pre, 'paramTbody') 走档位取 tbody, 跟 cfgSnap 一致
    // 之前走 el.paramTbody (= tabPoll 的), manual tab 读了会显示"参数列表为空"
    // 因为手动档的寄存器行都在 mParamTbody 里, 不在 tabPoll 的 paramTbody
    const valTbody = E(cfgPrefix(), 'paramTbody');
    valTbody.querySelectorAll('tr').forEach(tr => {
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

function renderRegTable(pre) {
  // Step 2e: 拆 m/p 分支, pre 由 readCfg/readCfgSilent/activateTab 传入
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  // 两种情况都不重建 DOM：
  // ① 焦点正在参数表里 —— 重建会丢焦点、冲掉刚打的字；
  // ② 对应 tab 标签页不可见且表里已有真实数据行 —— 切走时浏览器会把焦点里的
  //    输入框 blur 掉，activeElement 变成 <body>，只判焦点会漏。
  //    ⚠️ 必须确认表里真的有 .c-addr 行才跳过：空表/占位行时该渲染
  const ae = document.activeElement;
  if (ae && ae.closest && tbody.contains && tbody.contains(ae)) return;
  const tabName = pre ? (pre === 'm' ? 'tabManual' : 'tabPlatform') : 'tabPoll';
  const pane = $(tabName);
  if (pane && !pane.classList.contains('active') && tbody.querySelector && tbody.querySelector('.c-addr')) return;
  tbody.innerHTML = '';
  const rows = toArr(S.regs);
  if (rows.length === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td colspan="8" style="color:#999;padding:14px;">暂无寄存器，点「新增寄存器」添加</td>';
    tbody.appendChild(tr);
    return;
  }
  rows.forEach(r => addRegRow(pre, r.addr, r.dtype || r.type, r.name, r.alias, r.count));
}

function addRegRow(pre, addr, type, name, alias, count) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
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
  const ph = tbody.querySelector && tbody.querySelector('tr td[colspan]');
  if (ph) ph.parentNode.removeChild(ph);
  tbody.appendChild(tr);
  // 新增行也要遵守当前模式的锁态: platform/sniff 下不该有「删除」键
  if (!isManual(S.mode)) {
    tr.querySelectorAll('input, select').forEach(e => {
      if (e.classList.contains('c-val') || e.classList.contains('c-ts')) return;
      // select 没有 readonly, 用 disabled
      if (e.tagName === 'SELECT') e.disabled = true;
      else e.readOnly = true;
      e.classList.add('ro');
    });
    const delBtn = tr.querySelector('.btn-del');
    if (delBtn) delBtn.style.display = 'none';
  }
  refreshCfgDirty(pre);                // 增行是 DOM 操作，不触发 input 事件，得手动标脏
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
  // Step 2e: 传当前档位 pre 给 addRegRow, 让行加到 m/p 各自 tab 的 paramTbody
  addRegRow(cfgPrefix(), parseInt(addr, 10), type, phyId.trim(), alias, cnt);
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
  // platform 档: 轮询起没起决定卡片状态显示"运行中"还是"拉取中"。
  // 必须在下面 forEach 之前算 —— 回调是同步执行的, const 声明在后面就是
  // 暂时性死区, 直接 ReferenceError 把整个 renderMode 打挂
  const pollRunning = !!((st.poll || {}).running);
  // 卡片选中态：有待应用选择就高亮它，否则高亮设备当前模式
  // 模式名直接从 k 推导（idle/manual/platform/sniff），不读 data-mode 属性：
  // 少一次 DOM 读取，也不依赖属性是否被正确设置。
  // DOM id 保留 mcPoll/mcPollpull 兼容老代码; k 映射到新 mode 字符串
  ['Idle', 'Poll', 'Pollpull', 'Sniff'].forEach(k => {
    let dm = k.toLowerCase();      // idle / poll / pollpull / sniff
    if (k === 'Poll') dm = 'manual';      // 卡片 ID 是 Poll, 新 mode 名是 manual
    if (k === 'Pollpull') dm = 'platform'; // 卡片 ID 是 Pollpull, 新 mode 名是 platform
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
        if (dm === 'platform') {
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
  // 记录 3: 删 19 字段 setKv (mCurMode/mCfgSrc/mBusy/mSlave/mBaud/mInterval/
  // mRespCap/mRegCount/mGen/mWriteQ/mWriteStat/mMonFrames/mPaired/mOrphan/
  // mPending/mReqRsp/mUptime/mWdt)。HTML panel 已删, 调 setKv 会报 null ref.
  // 调试: 走 R:STAT 串口命令查同样字段。

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
  // 拉取配置按钮跟着模式显隐: 手动配置模式下不该出现这个入口
  syncPullCfgBtn();
  // 锁定 485 表单: 只有 manual（手动配置）档可编辑, platform/sniff/idle 全锁
  setFormLocked(!isManual(S.mode));
}

//=====================================================================
// 栏目随运行模式显隐
//   idle  → 只有 首页 / 运行模式
//   manual → 首页 / 运行模式 / poll模式
//   platform → 首页 / 运行模式 / poll模式（拉取档也要能看/改配置）
//   sniff → 首页 / 运行模式 / sniff模式
// poll 与 sniff 是两种互斥的总线用法，设备同一时刻只跑一种，另一个页面留在
// 栏目上只会让人以为它也在工作。设备没接总线时尤其容易误点进去看一片空。
// 用 display 藏掉而不删 DOM：配置项和表单状态都还在，切回模式即原样恢复
//=====================================================================
function syncTabs() {
  const mode = S.mode || 'idle';
  // Step 1a: tabManual/tabPlatform 各管自己档位, tabPoll 完全隐藏
  // (后续 Step 1b 决定删/留)。tabManual/tabPlatform 内容跟 tabPoll
  // 一模一样, 业务 0 改 → getElementById 仍拿 tabPoll 内元素,
  // 切到新 tab 看到内容但响应跟 tabPoll 同步
  const show = { tab0: true, tabMode: true,
    tabManual: isManual(mode),
    tabPlatform: isPlatform(mode),
    tabPoll: false,
    tabSniff: mode === 'sniff' };
  Object.keys(show).forEach(id => {
    const t = document.querySelector('.tab-header .tab-item[data-tab="' + id + '"]');
    if (t) t.style.display = show[id] ? '' : 'none';
  });
  // 2h fix: 平台档配置从平台拉, 不允许手动导入, 按钮直接禁用
  // (之前 importCfg 起头 toast 拦截被用户否决, 改为 UI 层禁用,
  //  平台档点 "导入" 按钮没反应, 一看就懂)
  if (el.btnImport) {
    el.btnImport.disabled = isPlatform(mode);
    el.btnImport.title = isPlatform(mode)
        ? '平台档配置从 MQTT 平台拉取，不能导入'
        : '导入配置文件 (.json / .csv)';
  }
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
      toast('已切换到 platform（拉取配置）模式，开始轮询');
      // quiet=true: 静默填表单, 避免 ds_pull 是空(首次进 platform 还没推)
      // 时弹「尚未保存过配置」误导用户以为配置没生效
      await readCfg(true);   // 表单回填成平台那份, 否则用户看到的还是手配的
      // 进 platform 时设备已被 ctrl 强制切到 MQTT 自动档, 不重读的话
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
    // 记录 3: 删 mCurMode setKv。HTML panel 已删, 改用 status 提示一行
    status('读取模式状态失败：' + e.message, false);
  }
}

async function applyMode(mode) {
  // 切换进行中再点，忽略（避免连点把设备和 UI 搞乱）
  if (S.modeSwitching) return;
  // platform → manual 切档提示: 当前显示的是平台那份(ds_pull), 切过去
  // 后会清掉显示内容, 用户得自己点「读取配置」读 ds_poll 那份
  // "manual"/"platform" 是当前 mode 名; "poll"/"pollpull" 是历史别名
  if (isManual(mode) && isPlatform(S.mode)) {
    const ok = await askConfirm(
      '当前显示的是平台拉取配置 (ds_pull)。切换到「手动配置」会清掉显示内容, 需重新点「读取配置」读取您的本地配置。\n确定继续？',
      '切换运行模式');
    if (!ok) return;
  }
  S.modeSwitching = true;
  S.modePending = mode;          // 先记下用户所选，防止 5s 定时刷新把高亮打回旧模式
  renderMode();
  try {
    status('正在切换到 ' + (MODE_LABEL[mode] || mode) + ' …', true);
    const r = await sendCmd(Protocol.Enc.setMode(mode), 'MODE', 8000);
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
    // 注: 不在这里 readCfg —— 改用 activateTab('tabPoll') 钩子, 同样场景
    // (软件一打开就是 platform) 也覆盖, 比 applyMode 钩子更通用
    if (isPlatform(mode)) {
      await waitPullDone();
      return;
    }
    // 切到 manual(手动配置)时 ctrl 会把设备 MQTT 档位强制切回手动档,
    // 不重读的话 MQTT 页的手动档开关和实际档位不一致
    // "manual" 是当前 mode 名; "poll" 是历史别名
    if (isManual(mode)) readMqtt(true);
    // 切回空闲时设备复位了配置, 表单还显示着旧值(手配寄存器表/手动档凭证),
    // 不清掉就算"已经删了"也和界面上看到的不一致。cleared 是设备回的实际
    // 清单, 一条都没清时不播报, 免得每次切空闲都弹一遍没信息量的 toast
    if (mode === 'idle') {
      // quiet=true: 用户刚在模式切换弹窗里明确批准了这次动作, 不该再被
      // 「有未保存更改」二次询问拦住(那次是防止误丢编辑, 这里是已知后果)
      try { await readCfg(true); await readMqtt(true); } catch (e) {}
      const cl = r && r.data && r.data.cleared;
      if (cl) {
        status('已切回空闲，并清空了：' + String(cl).split('+').join('、'), true);
        toast('已清空配置：' + String(cl).split('+').join('、'));
        return;
      }
    }
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
    // 同步 dirty 基线: 保存成功, 当前值变干净。设备值也更新, selBootMode = 设备值
    S.bootMode = v;
    snapBootClean();
    renderHome();
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

async function readBootMode() {
  try {
    const r = await sendCmd(Protocol.Enc.readBootMode(), 'BOOTMODE', 2000);
    // r 是 Protocol.decode 返的 {cmd, ok, data, raw}, r.data 是应答字面
    // "idle"/"manual"/"platform"/"sniff" 直返字面
    if (r && r.data) S.bootMode = r.data;
    // 同步 selBootMode 跟设备值, 刷新 dirty 状态
    snapBootClean();
  } catch (e) { /* 读失败不打扰用户, 卡片显示 -- 即可 */ }
}

//=====================================================================
// 首页状态总览
//=====================================================================
function renderHome() {
  // mode 段（mode/busy/poll/mon）来自 R:MODE 或 R:STAT.mode；
  // data/guard 两段只在 R:STAT 顶层，R:MODE 不返回，必须从 S.stat 取。
  const st   = S.modeStat || {};
  const full = S.stat || {};
  const g = full.guard || {};
  const mq = (S.mqtt && S.mqtt.stat) || {};
  setKv('hMode', (st.mode || 'idle') + (st.busy ? '（占用总线）' : ''));
  setKv('hMqtt', mq.connected ? '已连接' : '未连接', !mq.connected);
  setKv('hDevId', mq.device_id || (mq.sn || ''));
  setKv('hWdt', g.wdt_to ? (wdtStalled(g, !!(st.poll || {}).running).stalled ? '停滞!' : '正常') : '未启用',
        wdtStalled(g, !!(st.poll || {}).running).stalled);
  // 开机模式: 设备值 S.bootMode (R:BOOTMODE 应答), 跟本地 selBootMode 比对
  // 标 dirty (跟运行模式 tab 的 btnSaveBoot 同步)。这里只是渲染, dirty 状态
  // 状态由 refreshBootDirty() 维护 (改 selBootMode 时触发)
  const bootLabel = MODE_LABEL[S.bootMode] || S.bootMode || '--';
  setKv('hBootMode', bootLabel + (S.bootDirty ? ' *' : ''));
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
  // pollpull 档: 平台 push 一来, 静默读一份 ds_pull 填进表单, 让用户立刻看
  // 到新配置 (5s 定时刷新看见 push_n 增, 触发一次 readCfg; 失败就静默, 不
  // 打断横幅本身的展示). 初次进 pollpull 由 waitPullDone 负责, 这里只管
  // "已进 pollpull 后再有新 push" —— 与 S.pushSeenN 配合, 同一份不重读
  if (isPlatform(S.mode) && mq.push_n && mq.push_n !== S.pushSeenN) {
    readCfgSilent();
  }
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
    // 开机模式不在 R:STAT 4 段里, 单独发 R:BOOTMODE 读
    await readBootMode();
    renderHome();
  } catch (e) { /* 首页刷新失败不打扰用户 */ }
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
      + (inf.ignored ? '；已过滤 ' + inf.ignored + ' 条无应答的请求（从机可能不在线）' : '')
    : '';
  if (regs.length === 0) {
    el.inferTbody.innerHTML = '<tr><td colspan="7" style="color:#999;">暂无推断结果</td></tr>';
    return;
  }
  el.inferTbody.innerHTML = regs.map(r =>
    '<tr>' +
    '<td>' + esc(r.slave) + '</td>' +
    '<td>' + esc(r.addr) + '</td>' +
    '<td>' + esc(r.count) + '</td>' +
    '<td>0x' + (r.fc != null ? r.fc.toString(16).padStart(2, '0').toUpperCase() : '?') + '</td>' +
    '<td>' + esc(r.hits) + '</td>' +
    '<td title="' + esc(r.dtype || '-') + '" style="font-family:monospace;font-size:12px;color:#0066cc;">' + esc(r.dtype || '-') + '</td>' +
    '<td>reg' + esc(r.addr) + '</td>' +
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
  // Q2: fallback 标识 (静默监听 21 候选都失败, 兜底 cfg.BAUD). 区分"识别命中"
  // (绿色) 跟"兜底配置" (橙色警告), user 一眼能看出 sniff baud 是从总线上抓的
  // 还是从 cfg 里抄的, 错的 cfg.BAUD 会让 sniff 收 CRC err.
  const tag = d.fallback ? ' ⚠ 兜底 cfg.BAUD' : '';
  el.detectHint.textContent = '已识别：' + serialDesc(d) + tag +
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
// 导入 / 导出配置（JSON / CSV 两种格式）
// 2h: 加 CSV 支持, 中文列名 (Excel 直接打开), 用扩展名/弹窗选 走对应格式
//---------------------------------------------------------------------
// 列名(中文, 用户 Excel 看到的) -> 内部 key (跟 JSON 字段对齐, 走同样导入流程)
const CSV_COLS = {
  serial: [
    ['波特率', 'baud'],
    ['数据位', 'databits'],
    ['校验位', 'parity'],
    ['停止位', 'stopbits'],
    ['从机地址', 'slave'],
    ['轮询间隔ms', 'interval_ms'],
    ['响应超时ms', 'timeout_ms']
  ],
  registers: [
    ['地址', 'addr'],
    ['数据类型', 'dtype'],
    ['寄存器个数', 'count'],
    ['标识符', 'name'],
    ['中文名', 'alias']
  ],
  mqtt: [
    ['服务器地址', 'host'],
    ['端口', 'port'],
    ['SSL', 'ssl'],
    ['用户名', 'user'],
    ['密码', 'pass'],
    ['ClientID', 'client_id'],
    ['发布Topic', 'pub_topic'],
    ['订阅Topic', 'sub_topic'],
    ['上报周期秒', 'interval_s']
  ]
};
function csvEscape(s) {
  if (s == null) return '';
  s = String(s);
  if (s.indexOf(',') >= 0 || s.indexOf('"') >= 0 || s.indexOf('\n') >= 0) {
    return '"' + s.replace(/"/g, '""') + '"';
  }
  return s;
}
function parseCsvLine(line) {
  const cells = [];
  let cur = '';
  let inQuote = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inQuote) {
      if (c === '"' && line[i+1] === '"') { cur += '"'; i++; }
      else if (c === '"') { inQuote = false; }
      else { cur += c; }
    } else {
      if (c === ',') { cells.push(cur); cur = ''; }
      else if (c === '"' && cur === '') { inQuote = true; }
      else { cur += c; }
    }
  }
  cells.push(cur);
  return cells;
}
function toCsv(data) {
  const lines = [
    '# VKBox 配置导出',
    '# 导出时间: ' + new Date().toISOString(),
    ''
  ];
  lines.push('[serial]');
  const sCols = CSV_COLS.serial;
  lines.push(sCols.map(c => csvEscape(c[0])).join(','));
  const s = data.serial || {};
  lines.push(sCols.map(c => csvEscape(s[c[1]])).join(','));
  lines.push('');
  lines.push('[registers]');
  const rCols = CSV_COLS.registers;
  lines.push(rCols.map(c => csvEscape(c[0])).join(','));
  for (const r of (data.registers || [])) {
    lines.push(rCols.map(c => csvEscape(r[c[1]])).join(','));
  }
  lines.push('');
  lines.push('[mqtt]');
  const mCols = CSV_COLS.mqtt;
  lines.push(mCols.map(c => csvEscape(c[0])).join(','));
  const m = data.mqtt || {};
  lines.push(mCols.map(c => csvEscape(m[c[1]])).join(','));
  return lines.join('\n');
}
function parseCsv(text) {
  const lines = text.split(/\r?\n/);
  let section = null;
  let headers = null;
  const result = { serial: {}, registers: [], mqtt: {} };
  for (let line of lines) {
    line = line.trim();
    if (!line || line.startsWith('#')) continue;
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.slice(1, -1);
      headers = null;
      continue;
    }
    if (!section) continue;
    const cells = parseCsvLine(line);
    if (!headers) { headers = cells; continue; }
    if (section === 'serial') {
      const cols = CSV_COLS.serial;
      for (let i = 0; i < cols.length; i++) result.serial[cols[i][1]] = cells[i] || '';
    } else if (section === 'registers') {
      const cols = CSV_COLS.registers;
      const reg = {};
      for (let i = 0; i < cols.length; i++) reg[cols[i][1]] = cells[i] || '';
      result.registers.push(reg);
    } else if (section === 'mqtt') {
      const cols = CSV_COLS.mqtt;
      for (let i = 0; i < cols.length; i++) result.mqtt[cols[i][1]] = cells[i] || '';
    }
  }
  return result;
}

// data: { serial, registers, mqtt } - 内部统一格式
function exportCfgAsJson(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const c = collectCfg(pre);
  if (!c.ok) { toast('当前表单配置无效，无法导出：' + c.err); return; }
  const data = {
    tool: 'VKBox配置工具', version: '2.0.0',
    exported: new Date().toISOString(),
    serial: c.cfg,
    registers: collectRegs(pre),
    mqtt: {
      host: E(pre, 'mqHost').value.trim(), port: parseInt(E(pre, 'mqPort').value, 10) || 1883,
      ssl: E(pre, 'mqSsl').checked, user: E(pre, 'mqUser').value.trim(),
      pass: E(pre, 'mqPass').value,
      client_id: E(pre, 'mqClientId').value.trim(),
      pub_topic: E(pre, 'mqPub').value.trim(),
      sub_topic: E(pre, 'mqSub').value.trim(),
      interval_s: parseInt(E(pre, 'mqInterval').value, 10) || 0,
      allow_no_sn: E(pre, 'mqAllowNoSn').checked,
      keep_session: E(pre, 'mqKeepSession').value === '1',
      auto: { pass: (S.mqtt && S.mqtt.auto_pass) || '' },
      manual_on: S.mqManual
    }
  };
  const json = JSON.stringify(data, null, 2);
  const blob = new Blob([json], { type: 'application/json' });
  downloadBlob(blob, 'vkbox_config_' + new Date().toISOString().slice(0, 10) + '.json');
  toast('配置已导出为 JSON');
}
function exportCfgAsCsv(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const c = collectCfg(pre);
  if (!c.ok) { toast('当前表单配置无效，无法导出：' + c.err); return; }
  // 抽 11 MQTT 字段 (跟 JSON 一样, 内部用 JSON 字段名)
  const m = {
    host: E(pre, 'mqHost').value.trim(),
    port: parseInt(E(pre, 'mqPort').value, 10) || 1883,
    ssl: E(pre, 'mqSsl').checked,
    user: E(pre, 'mqUser').value.trim(),
    pass: E(pre, 'mqPass').value,
    client_id: E(pre, 'mqClientId').value.trim(),
    pub_topic: E(pre, 'mqPub').value.trim(),
    sub_topic: E(pre, 'mqSub').value.trim(),
    interval_s: parseInt(E(pre, 'mqInterval').value, 10) || 0,
    allow_no_sn: E(pre, 'mqAllowNoSn').checked,
    keep_session: E(pre, 'mqKeepSession').value === '1'
  };
  // CSV 不存 allow_no_sn / keep_session / auto.pass / manual_on, 注释里说明
  const csv = toCsv({
    serial: c.cfg,
    registers: collectRegs(pre),
    mqtt: m
  });
  // 头部注释: 手动档额外字段
  const headerNote = '# manual_on=' + S.mqManual + ', allow_no_sn=' + m.allow_no_sn + ', keep_session=' + m.keep_session + '\n';
  // 2h fix: 加 UTF-8 BOM (\uFEFF), Excel 看到 BOM 自动用 UTF-8 解码, 中文不乱码
  // type 也加 charset=utf-8, 让其他工具 (LibreOffice/VSCode) 也能正确识别
  const blob = new Blob(['\uFEFF' + headerNote + csv], { type: 'text/csv;charset=utf-8' });
  downloadBlob(blob, 'vkbox_config_' + new Date().toISOString().slice(0, 10) + '.csv');
  toast('配置已导出为 CSV');
}
function downloadBlob(blob, name) {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  URL.revokeObjectURL(a.href);
}

// 内部统一: 把 {serial, registers, mqtt} 数据填到当前 tab
// export 走 exportCfgAsJson/Csv, import 走 applyParsedData
function applyParsedData(pre, d) {
  const c = d.serial || d.cfg || {};
  if (c.baud) E(pre, 'selBaud').value = String(c.baud);
  if (c.databits) setRadio('databits', String(c.databits), pre);
  if (c.parity != null) setRadio('parity', String(c.parity), pre);
  if (c.stopbits) setRadio('stopbits', String(c.stopbits), pre);
  if (c.interval_ms) E(pre, 'inpRound').value = c.interval_ms;
  if (c.slave) E(pre, 'inpSlave').value = c.slave;
  E(pre, 'inpTimeout').value = (c.timeout_ms == null || c.timeout_ms === '') ? '' : c.timeout_ms;
  if (c.server) el.fUrl.value = c.server;
  const regs = d.registers || d.regs || [];
  S.regs = toArr(regs);
  renderRegTable(pre);
  if (d.mqtt) {
    E(pre, 'mqHost').value = d.mqtt.host || '';
    E(pre, 'mqPort').value = d.mqtt.port || 1883;
    E(pre, 'mqSsl').checked = !!d.mqtt.ssl;
    E(pre, 'mqUser').value = d.mqtt.user || '';
    E(pre, 'mqPass').value = d.mqtt.pass || '';
    E(pre, 'mqClientId').value = d.mqtt.client_id || '';
    // 发布/订阅 topic：手动档专属，导入时一并带进来
    E(pre, 'mqPub').value = d.mqtt.pub_topic || '';
    E(pre, 'mqSub').value = d.mqtt.sub_topic || '';
    E(pre, 'mqInterval').value = d.mqtt.interval_s != null ? d.mqtt.interval_s : 120;
    E(pre, 'mqAllowNoSn').checked = !!d.mqtt.allow_no_sn;
    E(pre, 'mqKeepSession').value = d.mqtt.keep_session ? '1' : '0';
    // 自动档凭证密码回首页那个框；档次按钮按导入的 manual_on 切
    if (el.hMqPass && d.mqtt.auto) el.hMqPass.value = d.mqtt.auto.pass || '';
    setManualMode(!!d.mqtt.manual_on, { refill: true });
  }
  return regs.length;
}

// 2h.3 弹窗选格式: 导出时让用户选 JSON 或 CSV
// 用浏览器原生 confirm 太粗糙, 用自定义迷你模态 (不引外部库)
// 返回 'json' / 'csv' / null (取消)
function askExportFormat() {
  return new Promise(resolve => {
    const modal = document.createElement('div');
    modal.className = 'modal modal-open';
    modal.innerHTML = `
      <div class="modal-content" style="text-align:center;">
        <h3 style="margin:0 0 14px 0;">选择导出格式</h3>
        <div style="display:flex;gap:10px;margin-bottom:8px;">
          <button class="primary" data-fmt="json" style="flex:1;padding:10px;">JSON</button>
          <button data-fmt="csv" style="flex:1;padding:10px;">CSV (Excel)</button>
        </div>
        <button data-fmt="cancel" style="background:transparent;color:#666;border:none;cursor:pointer;">取消</button>
      </div>`;
    document.body.appendChild(modal);
    modal.addEventListener('click', e => {
      if (e.target === modal) { document.body.removeChild(modal); resolve(null); return; }
      const fmt = e.target && e.target.dataset && e.target.dataset.fmt;
      if (!fmt) return;
      document.body.removeChild(modal);
      resolve(fmt === 'cancel' ? null : fmt);
    });
  });
}

// Step 2j: 平台档点击 pMqInterval 弹窗修改上报周期
// 走问询弹窗 (单 input + 确认/取消), 返回输入的秒数 (number) 或 null (取消)
// 参考 askExportFormat 风**格**, 复用 .modal.modal-open class
function askEditInterval(cur) {
  return new Promise(resolve => {
    const modal = document.createElement('div');
    modal.className = 'modal modal-open';
    modal.innerHTML = `
      <div class="modal-content" style="text-align:center;width:320px;">
        <h3 style="margin:0 0 14px 0;">修改上报周期</h3>
        <div style="margin-bottom:8px;font-size:13px;color:#666;">当前值: <b style="color:#0a7d2c;">${cur} 秒</b></div>
        <div style="margin-bottom:14px;display:flex;align-items:center;justify-content:center;gap:6px;">
          <input id="askIntervalInp" type="number" min="120" max="86400" value="${cur}" style="width:140px;padding:8px;font-size:14px;">
          <span style="color:#666;">秒</span>
        </div>
        <div style="font-size:12px;color:#999;margin-bottom:12px;">范围 120 ~ 86400 秒 (2 分钟 ~ 1 天)</div>
        <div style="display:flex;gap:10px;">
          <button data-act="ok" class="primary" style="flex:1;padding:10px;">确认</button>
          <button data-act="cancel" style="flex:1;padding:10px;">取消</button>
        </div>
      </div>`;
    document.body.appendChild(modal);
    const inp = modal.querySelector('#askIntervalInp');
    setTimeout(() => { inp.focus(); inp.select(); }, 50);
    const close = v => { document.body.removeChild(modal); resolve(v); };
    modal.addEventListener('click', e => {
      if (e.target === modal) return close(null);
      const act = e.target && e.target.dataset && e.target.dataset.act;
      if (act === 'cancel') return close(null);
      if (act === 'ok') {
        const v = parseInt(inp.value, 10);
        if (!v || v < 120 || v > 86400) { toast('请输入 120~86400 之间的整数'); return; }
        return close(v);
      }
    });
    inp.addEventListener('keydown', e => {
      if (e.key === 'Enter') { e.preventDefault(); modal.querySelector('[data-act=ok]').click(); }
      else if (e.key === 'Escape') { e.preventDefault(); close(null); }
    });
  });
}

// 平台档 pMqInterval 只读但允许"点击弹窗修改", 输入新值后走 saveMqtt
async function editPlatformInterval() {
  const elInp = E('p', 'mqInterval');
  if (!elInp) return;
  const cur = parseInt(elInp.value, 10) || 120;
  const v = await askEditInterval(cur);
  if (v == null || v === cur) return;
  // 改 input.value (让 saveMqtt 走 E('p', 'mqInterval').value 拿到新值)
  elInp.value = String(v);
  status('正在保存上报周期 ' + v + ' 秒…', true);
  try {
    await saveMqtt();
    status('已保存上报周期 ' + v + ' 秒', true);
    toast('上报周期已改为 ' + v + ' 秒');
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
  }
}

// 2h exportCfg: 弹窗选 json/csv, dispatch 到对应导出函数
async function exportCfg(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const fmt = await askExportFormat();
  if (fmt === 'json') return exportCfgAsJson(pre);
  if (fmt === 'csv')  return exportCfgAsCsv(pre);
}

// 2h importCfg: 文件选择框 (filter .json,.csv), 选完按扩展名 dispatch
// 平台档已被 syncTabs 禁用 btnImport, 此处不需再检查 isPlatform
async function importCfg(pre) {
  if (pre === undefined) pre = cfgPrefix();
  // 先问再弹文件选择框：顺序反了的话用户选完文件才被告知会丢改动，白选一趟
  if (!await guardUnsaved(S.cfgDirty, '485', '保存配置', () => { S.cfgSnap = null; })) return;
  const inp = document.createElement('input');
  inp.type = 'file';
  inp.accept = '.json,application/json,.csv,text/csv';
  inp.onchange = () => {
    const f = inp.files && inp.files[0];
    if (!f) return;
    const rd = new FileReader();
    rd.onload = () => {
      const text = rd.result;
      let data, fmt;
      try {
        const lower = f.name.toLowerCase();
        if (lower.endsWith('.json')) {
          data = JSON.parse(text);
          fmt = 'JSON';
        } else if (lower.endsWith('.csv')) {
          data = parseCsv(text);
          fmt = 'CSV';
        } else {
          // 后缀名不在, 尝试按内容嗅探
          const t = String(text).trim();
          if (t.startsWith('{') || t.startsWith('[')) {
            data = JSON.parse(text);
            fmt = 'JSON';
          } else if (t.indexOf('[serial]') >= 0) {
            data = parseCsv(text);
            fmt = 'CSV';
          } else {
            throw new Error('无法识别格式');
          }
        }
        const cnt = applyParsedData(pre, data);
        toast('配置已导入 (' + fmt + ')：' + cnt + ' 个寄存器');
        snapClean(pre);                // 导入的内容成为新基线
      } catch (e) {
        toast('导入失败：不是合法的配置文件 (' + e.message + ')');
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
  // Step 2c/2d fix: homeTimer 5s 跑 readHome + readMqtt, 让 manual/platform
  // tab 的 5 字段状态 / 17 字段状态都自动刷。之前只 readHome, mqtt 状态不更新
  // Step 2l: 拿掉 readMqtt 5s 自动调。原因: 5s 一跑 renderMqtt 会把用户正填的
  // 5 字段 (user/pass/clientId/pub/sub) 覆盖掉, fillOk 只跳过当前聚焦的 1 个,
  // 其余 4 个会被冲掉, 体验差。MQTT 面板的"读全量"走 activateTab + 手动按钮。
  homeTimer = setInterval(async () => {
    if (S.pending) return;
    try { await readHome(); } catch (_) {}
  }, 5000);
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
// Step 2e: 485 + 寄存器表 4 button 拆 tab 后 m/p 都有, 单绑 el.btnXxx 只
// 拿到 tabPoll 内的, 切到 manual/platform tab 时点不到。querySelectorAll
// 绑所有 3 份, 跟 btnMqttSave/Reconnect/Report 同一改法
// Step 2e+: 平台档 "保存配置" (pBtnSaveCfg) + "新增寄存器" (pBtnAddReg)
// + manual 档 "重新拉取" (mBtnPullCfg) 已注释掉 (HTML 注释),
// 浏览器不渲染, querySelectorAll 自然找不到
document.querySelectorAll('#mBtnReadCfg, #pBtnReadCfg, #btnReadCfg').forEach(b => { b.onclick = readCfg; });
document.querySelectorAll('#mBtnSaveCfg, #btnSaveCfg').forEach(b => { b.onclick = saveCfg; });
document.querySelectorAll('#pBtnPullCfg, #btnPullCfg').forEach(b => { b.onclick = pullCfg; });
document.querySelectorAll('#mBtnAddReg, #btnAddReg').forEach(b => { b.onclick = addParamRow; });
document.querySelectorAll('#mBtnReadVal, #pBtnReadVal, #btnReadVal').forEach(b => { b.onclick = readVal; });
el.btnReadVal.onclick = readVal;
// Step 2f: importCfg / exportCfg 拆 m/p 后, 顶部 btnImport / btnExport
// 仍只 1 份 (top-bar 全局), 调时把当前档位 pre 传进去
el.btnImport.onclick = () => importCfg(cfgPrefix());
el.btnExport.onclick = () => exportCfg(cfgPrefix());
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
// Step 2p: 拆 m/p 后, manual/platform tab 的 485 面板 (sp-m-s1 / sp-p-s1)
// 也要挂上, 跟 2m/2n/2o 同根问题 (Step 2a 拆 tab 时漏)
// Step 2s: 用箭头函数包装, 不传事件对象给 refreshCfgDirty, 否则第一个参数
// 是 Event 对象 (有 isTrusted 等属性), 会被当作 pre 档位参数传给 cfgSnap,
// cfgSnap 走 E(事**件**对**象**, ...) 因**为**事**件**对**象**是** truthy 走** _nullStub 分**支**,
// 所**有**字**段**返**回**空**字**符**串**, dirty 判**定**失**效**
['input', 'change'].forEach(ev => {
  ['sp-s1', 'sp-m-s1', 'sp-p-s1'].forEach(id => {
    const pane = $(id);
    if (pane) pane.addEventListener(ev, () => refreshCfgDirty());
  });
});

// MQTT 未保存检测：MQTT 页(#sp-s2) + 首页 MQTT 那一栏(#tab0)分属两个容器，
// 用事件代理得挂到 body 上，反而绕。这里直接把可编辑字段逐个挂监听，
// 一目了然，新增字段时漏不了（编译器不会提醒，但列表就摆在眼前）。
// 程序回填(renderMqtt/fillMqHome 赋 .value)不触发这两个事件，不会误标脏
// Step 2o: 把 manual/platform tab 的 5 字段也加进来, 跟 Step 2a 拆 tab 时漏的
// 按钮绑定 (2m)、dirty 切换 (2n) 同根问题 — 当时只挂了一份 tabPoll 的 input
// 监听, manual/platform tab 改了字段不会触发 refreshMqDirty
//   manual 档 9 字段: mMqHost/Port/Ssl/User/Pass/Cid/Pub/Sub/Interval
//   platform 档 5 字段: pMqHost/Port/Ssl/Interval/KeepSession
//   tabPoll 还差 2: mqPub/Sub (之前漏了, 5 字段只有 user/pass/cid 被监听了)
[el.mqHost, el.mqPort, el.mqSsl, el.mqUser, el.mqPass, el.mqClientId,
 el.mqPub, el.mqSub,
 el.mqInterval, el.mqKeepSession, el.mqAllowNoSn,
 el.mMqHost, el.mMqPort, el.mMqSsl, el.mMqUser, el.mMqPass, el.mMqClientId,
 el.mMqPub, el.mMqSub, el.mMqInterval, el.mMqAllowNoSn, el.mMqKeepSession,
 el.pMqHost, el.pMqPort, el.pMqSsl, el.pMqInterval, el.pMqKeepSession,
 el.hMqHost, el.hMqPort, el.hMqPass, el.hMqClientId].forEach(e => {
  if (!e) return;
  e.addEventListener('input', refreshMqDirty);
  e.addEventListener('change', refreshMqDirty);
});
// sniff 页面简版: snMqInterval 改 → 同步 mqInterval + 触发 mqDirty
if (el.snMqInterval) {
  el.snMqInterval.addEventListener('input', () => {
    if (el.mqInterval) el.mqInterval.value = el.snMqInterval.value;
    refreshMqDirty();
  });
  el.snMqInterval.addEventListener('change', () => {
    if (el.mqInterval) el.mqInterval.value = el.snMqInterval.value;
    refreshMqDirty();
  });
}

// 首页
el.btnHomeRefresh.onclick = async () => { await readHome(); await readMode(); await readMqtt(); };
el.btnHomeMqttSave.onclick = saveHomeMqtt;

// 运行模式页
el.btnModeRefresh.onclick = readMode;
el.btnSaveBoot.onclick = saveBootMode;
// 开机默认模式 dirty 检测: 改了 selBootMode → 按钮变 "保存 *"
if (el.selBootMode) el.selBootMode.onchange = refreshBootDirty;
// 点卡片 = 弹窗确认后立即切换（"应用所选模式"按钮已去掉，卡片即操作）。
// 之前只切高亮不发命令，5s 定时刷新一到就把高亮打回旧模式，
// 表现为"选中后模式自动跳回原来模式"。
// 卡片区域大、容易误点，切换又要停掉旧模式，所以必须弹窗确认。
// 设备侧模式名 -> 用户看得懂的中文。platform 是内部约定名(设备侧 ds_pull
// 配置槽的标志), 直接显示会把用户搞糊涂, 所有 toast/status/保存回显都走它
// 记录 3: 删 poll/pollpull 项。设备端 normalize_sys 限 4 值, 不会再返历史别名
const MODE_LABEL = {
  idle: '空闲 idle',
  manual: 'manual（手动配置）',
  platform: 'platform（拉取配置）',
  sniff: '旁听 sniff'
};
// 切回空闲时设备会顺带复位用户配置, 确认弹窗里要多说一段。
// 清的是哪些必须逐条列 —— 只说"会清空配置"用户无法判断要不要先备份。
// 保留哪些也要说: 否则"首页填的 MQTT 还在不在"只能靠猜。
// 只有 idle/stop 有这段, 其它模式不涉及。
function idleWipeWarn(mode) {
  if (mode !== 'idle') return '';
  return '\n\n⚠️ 切回空闲会同时清空以下配置，且不可恢复：\n'
       + '  • 485 手动配置（寄存器表 / 串口参数 / 从机地址）\n'
       + '  • 485 平台拉取配置（下次进「拉取配置」档会重新向平台拉取）\n'
       + '  • MQTT 手动档的凭证与发布/订阅 Topic\n\n'
       + '保留不动：MQTT 服务器地址、端口、SSL、ClientID、上报周期，'
       + '以及首页填的 MQTT 凭证密码。\n\n'
       + '建议先到「配置」页点「导出配置」留一份备份。';
}

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
                 + '正在进行的采集会中断。'
                 // 切回空闲不只是停总线, 设备会顺带复位用户配置。这是不可恢复的
                 // 删除动作, 必须在同一个弹窗里一次说清, 不能让用户点完才知道
                 + idleWipeWarn(m), '切换运行模式')) return;
    applyMode(m);
  };
});
// MQTT 页
el.btnMqttRefresh.onclick = readMqtt;
// 立刻把手动档开关写给设备。读全量再合并: 共用字段(地址/端口/周期等)和
// 两份凭证都不能被这次写入冲掉。manual_on=false 时设备端会清空手动档的
// 凭证和 topic, 然后用 SN + 首页凭证密码重连 (topic 走 PLATFORM_* 固定常量)
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

// Step 2i: 删 btnManualCfg.onclick — 整**个**按**钮**已**从** HTML 移**除**(本面板就**是**手**动**配**置**)
// 档**位**切**换**走**保**存**时**的** saveMqtt / writeManualMode 配**合**完**成**, 不**再**单**独**有**"开/关"按**钮**
el.btnMqttSave.onclick = saveMqtt;
// Step 2j: 平台档 pMqInterval 只读但允许"点击弹窗修改"
// el Proxy lazy lookup: 第一次 el.pMqInterval 触发 $(pMqInterval) 拿到 DOM
// 只有 platform tab 有这元素, manual/tabPoll 的 mMqInterval / mqInterval 是可输入的 (无 .ro-clickable)
const pInp = $('pMqInterval');
if (pInp) pInp.onclick = editPlatformInterval;
// Step 2c/2d: 拆 tab 后 m-/p- 各有 button, 单绑 el.btnXxx 只拿到第一个 = tabPoll 内的
// 切到 manual/platform tab 时点不到。改用 querySelectorAll 绑所有 3 份
// Step 2m: 把 Save + Refresh 也加进来, 之前只绑了 Report/Reconnect/PassEye,
// manual tab 的 mBtnMqttSave / mBtnMqttRefresh 漏了, 点上去什么都不发生
document.querySelectorAll('#mBtnMqttSave, #btnMqttSave').forEach(b => { b.onclick = saveMqtt; });
document.querySelectorAll('#mBtnMqttRefresh, #btnMqttRefresh').forEach(b => { b.onclick = readMqtt; });
document.querySelectorAll('#mBtnMqttReport, #pBtnMqttReport, #btnMqttReport').forEach(b => { b.onclick = reportNow; });
document.querySelectorAll('#mBtnMqttReconnect, #pBtnMqttReconnect, #btnMqttReconnect').forEach(b => { b.onclick = mqttReconnect; });
// 密码眼按钮 manual 档有, 平台档没 (Step 2c 删了), tabPoll 仍保留
document.querySelectorAll('#mBtnMqttPassEye, #btnMqttPassEye').forEach(b => { b.onclick = togglePassEye; });
el.btnMqttPassEye.onclick = togglePassEye;
// sniff 页面简版: 刷新 = 跟 sp-s2 一起 readMqtt; 保存 = 走 saveMqtt (snMqInterval 同步到 mqInterval)
if (el.btnSnMqttRefresh) el.btnSnMqttRefresh.onclick = readMqtt;
if (el.btnSnMqttSave) el.btnSnMqttSave.onclick = async () => {
  // 同步 snMqInterval → mqInterval (saveMqtt 从 mqInterval 读)
  if (el.snMqInterval && el.mqInterval) el.mqInterval.value = el.snMqInterval.value;
  await saveMqtt();
  if (el.snMqttHint) {
    el.snMqttHint.textContent = S.mqtt ? '已保存' : '';
    setTimeout(() => { if (el.snMqttHint) el.snMqttHint.textContent = ''; }, 3000);
  }
};
if (el.btnHomeMqttPassEye) el.btnHomeMqttPassEye.onclick = togglePassEye;
// Step 2i: 删 btnMqttReset.onclick — 整**个**按**钮**已**从** HTML 移**除**(有**刷**新**了**, 按**钮**冗**余**)
// 如**果**用**户**需**要**重**置**配**置**, 手**动**改**每**一**项** (有**填**的**就**清**空**) + 走**保**存**即**可**

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
  // Step 1b fix: 切到 manual/platform/poll tab 时, 重置当前 tab 内的
  // .serial-pane active (默认显示"串口配置"段 = s1)。否则上次在另一个
  // tab 操作留下的 active 状态会让用户切回来看到空白/错位
  if (tabId === 'tabManual' || tabId === 'tabPlatform' || tabId === 'tabPoll') {
    const prefix = tabId === 'tabManual' ? 'm-' :
                   tabId === 'tabPlatform' ? 'p-' : '';
    const s1 = document.getElementById('sp-' + prefix + 's1');
    const s2 = document.getElementById('sp-' + prefix + 's2');
    if (s1) s1.classList.add('active');
    if (s2) s2.classList.remove('active');
    // .serial-tab 也要 reset 到 s1
    pane.querySelectorAll('.serial-tab').forEach(t => {
      t.classList.toggle('active', t.getAttribute('data-serial') === 's1');
    });
  }
  // 切到报文页时立即拉一次
  if (tabId === 'tabSniff' && S.open && S.mode === 'sniff') readFrames();
  // 切到 sniff tab 时同步刷一次 MQTT 配置 (snMqHost/Port/Interval)
  if (tabId === 'tabSniff' && S.open) readMqtt();
  // pollpull 档: 进 poll tab 时静默读一份 ds_pull 填表单 —— 软件一打开
  // 就是 pollpull (没有 applyMode 这一步) 也覆盖。push 自动刷新另见
  // renderPushBanner. applyMode 钩子已删除 (窄), 这个钩子宽
  if (tabId === 'tabPoll' && isPlatform(S.mode)) readCfgSilent();
  // Step 1b fix: 同样, manual/platform tab 静默读一次配置
  if ((tabId === 'tabManual' || tabId === 'tabPlatform') && S.open) {
    if (isPlatform(S.mode)) readCfgSilent();
  }
  // Step 2n: 切 tab 时重取 mqSnap 基线。理由: mqSnap 走 E(pre, 'mqXxx'),
  // 不同档位取不同 input, 切档时新旧基线如果不重取会误报 dirty
  // (例 manual 填 5 字段 → 切 poll → 切回 manual → 5 字段值还在但 baseline 是 poll 的空值)
  snapMqClean();
}

const tabItems = document.querySelectorAll('.tab-header .tab-item');
tabItems.forEach(item => {
  item.onclick = function () {
    activateTab(this.getAttribute('data-tab'));
  };
});

// poll模式子标签切换：串口1（485总线）/ MQTT配置
// Step 1b fix: 拆 tab 后有 3 份 .serial-pane (sp-m-s1/sp-m-s2, sp-p-s1/sp-p-s2,
// sp-s1/sp-s2), 用 getElementById('sp-s1') 只拿第一个 = tabPoll 内的 sp-s1,
// 切到 manual/platform tab 时会拿错 pane。改成在当前 .tab-pane 作用域内找
const serialTabs = document.querySelectorAll('.serial-tab');
serialTabs.forEach(tab => {
  tab.onclick = () => {
    // 当前 .serial-tab 在哪个 .tab-pane 下面 — click 时离它最近的那个
    const tabPane = tab.closest('.tab-pane');
    if (!tabPane) return;
    const tabId = tabPane.id;                    // tabManual / tabPlatform / tabPoll
    const prefix = tabId === 'tabManual' ? 'm-' :
                   tabId === 'tabPlatform' ? 'p-' : '';
    // 当前 tab 自己的 .serial-tab 列表 (其他 tab 的不在范围内)
    const myTabs = tabPane.querySelectorAll('.serial-tab');
    myTabs.forEach(s => s.classList.remove('active'));
    tab.classList.add('active');
    const key = tab.getAttribute('data-serial'); // s1 / s2
    // 只在当前 tab 内操作 .serial-pane, 不会误碰其他 tab 的同名 pane
    tabPane.querySelectorAll('.serial-pane').forEach(p => p.classList.remove('active'));
    const pane = document.getElementById('sp-' + prefix + key);
    if (pane) pane.classList.add('active');
    // 切到 MQTT配置 时拉一次，避免刚切过去是空的
    if (key === 's2' && S.open) readMqtt();
    // pollpull 档: 切回 485 总线面板 时再读一次 ds_pull, 覆盖"在 poll tab
    // 里从 MQTT 切回 485" 的场景 (activateTab 已经读过一次了, 重复读也
    // 没成本, 而且能赶上这中间平台 push 的内容)
    if (key === 's1' && isPlatform(S.mode)) readCfgSilent();
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
// 预览态配置的出厂值。MOCK.cfg 由它深拷贝而来, 切回空闲的"复位"也靠把它
// 拷回去 —— 真设备是删 fskv 键, 预览没有持久层, 只能回到这份初始常量。
// 少了它, 预览时"切回空闲会清空手配寄存器表"这条链路根本看不出来
const MOCK_CFG_DEFAULT = {
  baud: 9600, databits: 8, parity: 0, stopbits: 1, slave: 1,
  interval_ms: 3000, timeout_ms: null,
  regs: [
    { addr: 0, count: 2, name: 'sensor1', alias: '传感器1', dtype: 'uint16' },
    { addr: 2, count: 2, name: 'sensor2', alias: '传感器2', dtype: 'int16' },
    { addr: 4, count: 2, name: 'temp', alias: '温度', dtype: 'float32' }
  ]
};
const MOCK = {
  mode: 'idle',
  bootMode: 'idle',   // 预览用: 开机默认模式 (R:BOOTMODE 应答值), 默认跟 mode 一致
  detecting: false,   // 预览用: 下一次 R:AUTODETECT 先回一次 BUSY
  pulling: false,     // 预览用: pollpull 的假拉取进行中(见 mockModeStat)
  cfg: JSON.parse(JSON.stringify(MOCK_CFG_DEFAULT)),
  // 手动档（MQTT 配置页）+ 自动档（首页）两份凭证
  mqtt: { host: 'dz.voltkun.com', port: 1883, user: '', pass: '', ssl: false,
          // 手动档 topic 模板。{SN} 由设备代入；Step 2k 起留空 = 设备不订不发
          pub_topic: '/sys/thing/node/property/post/{SN}',
          sub_topic: '/sys/thing/gw/config/get/{SN}',
          interval_s: 120, allow_no_sn: false, keep_session: false,
          auto: { pass: 'VKBOXGW2026KEY' }, manual_on: false },
  published: 0
};

function mockModeStat() {
  const m = MOCK.mode;
  // platform 也要算"在跑 poll": 它是拉取档, 轮询行为与 manual 相同, 只是配置
  // 来源不同。少了这个分支, 浏览器预览时 platform 卡片永远显示"待拉取"
  // "manual"/"platform" 是当前 mode 名; "poll"/"pollpull" 是历史别名
  const isPoll = isManual(m) || isPlatform(m);
  return {
    mode: m, busy: m !== 'stop' && m !== 'idle',
    // poll_src/pull_ready 与设备 ctrl.status() 对齐, 前端据此显示"配置来源"
    poll_src: isPoll ? (isPlatform(m) ? 'pull' : 'poll') : null,
    pull_ready: 'fskv',
    pull: isPlatform(m) ? { state: MOCK.pulling ? 'waiting' : 'done', msg: '' } : null,
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
  else if (line === 'R:BOOTMODE') resp = 'RET:BOOTMODE=' + MOCK.bootMode;  // 跟 MOCK.mode 同步
  else if (line === 'R:MQTT') resp = 'RET:MQTT=' + JSON.stringify({
    cfg: MOCK.mqtt,
    auto_pass: MOCK.mqtt.auto.pass,
    manual_on: MOCK.mqtt.manual_on,
    ready: true, err: null,
    stat: { want_run: true, connected: true, subscribed: true,
            device_id: 'VK20260925001', published: MOCK.published,
            user: 'VK20260925001', client_id: 'VK20260925001_',
            // 生效发布/生效订阅：当前档次实际在用的两条成品 topic
            pub: '/sys/thing/node/property/post/VK20260925001-1',
            sub: '/sys/thing/gw/config/get/VK20260925001',
            subs: ['/sys/thing/gw/config/get/VK20260925001',
                   '/sys/thing/gw/function/get/VK20260925001',
                   '/sys/thing/gw/property/set/VK20260925001',
                   '/sys/thing/gw/property/get/VK20260925001'],
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
  else if (line.indexOf('W:BOOTMODE=') === 0) {
    MOCK.bootMode = line.slice(11);
    resp = 'RET:BOOTMODE=OK';
  }
  else if (line.indexOf('W:MODE=') === 0) {
    MOCK.mode = line.slice(7);
    // 真设备是"进 sniff 就异步开始识别", 预览也照样演一遍
    MOCK.detecting = (MOCK.mode === 'sniff');
    // pollpull: 真设备进模式即起 hello 拉取(异步)。预览用 1.2s 假等一会,
    // 让"拉取中→已生效"的过渡在没接设备时也看得到
    MOCK.pulling = isPlatform(MOCK.mode);
    if (MOCK.pulling) {
      setTimeout(() => { MOCK.pulling = false; }, 1200);
    }
    // 真设备切回空闲会复位配置并回报清了什么, 预览照样演一遍,
    // 否则"切回空闲会清空配置"这条链路在没接设备时看不到
    if (MOCK.mode === 'idle') {
      // 手配寄存器表回到出厂值 + 手动档凭证清空,
      // 对应真设备的 cfgstore.reset_user() + mqttcfg.clear_manual()。
      // Step 2k: 手动档 topic 不再有"默认模板", 切回 idle 留空 = 设备不订不发
      // 首页那份(host/port/ssl/auto.pass)按定义不动
      MOCK.cfg = JSON.parse(JSON.stringify(MOCK_CFG_DEFAULT));
      MOCK.mqtt.manual_on = false;
      MOCK.mqtt.user = ''; MOCK.mqtt.pass = '';
      // Step 2k: 切回 idle 顺手清空手动档 topic (真设备 clear_manual 走 fskv 整段覆盖)
      // 旧代码保留默认路径作为"恢复出厂"的语义, 现在没默认路径了, 留空即代表出厂态
      MOCK.mqtt.pub_topic = '';
      MOCK.mqtt.sub_topic = '';
      // 记录 3+A: cleared 用友好名 (跟设备端 cfg.lua RESET_SLOTS 对齐)
      resp = 'RET:MODE=OK;cleared:manual 配置+platform 配置';
    } else {
      resp = 'RET:MODE=OK';
    }
  }
  else if (line.indexOf('W:BOOTMODE=') === 0) resp = 'RET:BOOTMODE=OK';
  else if (line.indexOf('W:CFG=') === 0) {
    try {
      const o = JSON.parse(line.slice(6));
      Object.assign(MOCK.cfg, o);
      resp = 'RET:CFG=OK';
    } catch (e) { resp = 'RET:FAIL:CFG:bad json'; }
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
snapBootClean();     // 取 selBootMode.value 当基线, 之后改动才报脏
status('请选择串口并打开', true);
