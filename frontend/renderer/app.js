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
  // 33-fix: platform 档的提示横幅状态
  platformMqttHintDismissed: false,  // 「MQTT 未连接」点过「知道了」. 切到 tabPlatform 时重置
  platformPullOkHintDismissed: false, // 「拉取成功」点过「知道了」. 切档 / 重启会话前持久 (类似 pushIgnored)
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
  mMqKeepSession: $('mMqKeepSession'),
  mMqStExtraTopics: $('mMqStExtraTopics'),  // 22-fix: 手动档额外生效 topic (U1/U2)
  // ====== Step 2a: tabPlatform 内的 p- 前缀引用 ======
  // Step 2c/2d: 平台档删 6 字段 (user/pass/ClientId/Pub/Sub) + 1 按钮
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
  // sniff 页面简版 MQTT 配置 (broker 只读 + 上报周期点弹窗改, 删了保存按钮)
  snMqHost: $('snMqHost'),
  snMqPort: $('snMqPort'),
  snMqInterval: $('snMqInterval'),
  btnSnMqttRefresh: $('btnSnMqttRefresh'),
  // sniff 状态卡片 (字段名跟 manual 档 mMqStXxx 对齐: DevId/Subed/ExtraTopics)
  snStConn: $('snStConn'),
  snStClientId: $('snStClientId'),
  snStUser: $('snStUser'),
  snStDevId: $('snStDevId'),
  snStMode: $('snStMode'),
  snStPub: $('snStPub'),
  snStSub: $('snStSub'),
  snStExtraTopics: $('snStExtraTopics'),
  snStSubed: $('snStSubed'),
  snStKeepSession: $('snStKeepSession'),
  // 报文页 (sniff-3 f: panel-title 的 [刷新] 删了, btnInferClear 改绑推断结果;
  //   总线报文子分段新加 [刷新] [清空] 按钮, id 同 frameLog 命名;
  //   sniff-3 g: 总线报文加滑动开关 frameSectionOn, 控制 frameButtons + frameBody 显隐)
  btnFrameRefresh: $('btnFrameRefresh'), btnFrameClear: $('btnFrameClear'),
  btnInferClear: $('btnInferClear'), btnInferRefresh: $('btnInferRefresh'),
  frameSectionOn: $('frameSectionOn'),
  frameButtons: $('frameButtons'),
  frameBody: $('frameBody'),
  frameFilter: $('frameFilter'), frameAuto: $('frameAuto'), frameLog: $('frameLog'),
  btnInfer: $('btnInfer'), inferTbody: $('inferTbody'),
  inferHint: $('inferHint'),
  btnAutoDetect: $('btnAutoDetect'), detectHint: $('detectHint'),
  // 33-fix: platform 档两个提示横幅的 DOM 引用
  pMqttHint: $('pMqttHint'), pMqttHintText: $('pMqttHintText'),
  pBtnMqttHintIgnore: $('pBtnMqttHintIgnore'),
  pPullOkHint: $('pPullOkHint'), pPullOkHintText: $('pPullOkHintText'),
  pBtnPullOkIgnore: $('pBtnPullOkIgnore')
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
// 否则 renderMqtt 内部 E('p',...).checked = ... 会让整个 renderMqtt 抛错,
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

// 38-fix: 带复选框的确认弹窗. 场景: 从 platform 切 manual/sniff 时,
//   问"是否清空平台拉取配置" (默认勾选). 返回 {ok, checked}, 都取消/确认
//   时结构一致, 调用方按需取字段
function askConfirmCheck(msg, title, opt) {
  return new Promise(resolve => {
    $('cfTitle').textContent = title || '请确认';
    $('cfMsg').textContent = msg;
    // 复选框块: 没传 opt 或 opt.label 隐藏
    const box = $('cfCheckBox');
    const lab = $('cfCheckLabel');
    const cb = $('cfCheck');
    if (opt && opt.label) {
      lab.textContent = opt.label;
      cb.checked = opt.checked !== false;   // 默认勾选
      box.style.display = 'flex';
    } else {
      box.style.display = 'none';
    }
    $('modalConfirm').style.display = 'flex';
    let done = false;
    const finish = ok => {
      if (done) return;
      done = true;
      $('modalConfirm').style.display = 'none';
      box.style.display = 'none';
      $('cfYes').onclick = null;
      $('cfNo').onclick = null;
      $('modalConfirm').onclick = null;
      document.removeEventListener('keydown', onKey);
      resolve({ ok: ok, checked: cb.checked });
    };
    // 复选框显示时, Enter 不能默认确认 (要按空格切勾选), 否则焦点在
    // 确认按钮时 Enter 还是确认. 这里保持原 Enter 行为, 勾选用鼠标或
    // Tab 到复选框按空格
    const onKey = e => {
      if (e.key === 'Escape') finish(false);
      else if (e.key === 'Enter') finish(true);
    };
    $('cfYes').onclick = () => finish(true);
    $('cfNo').onclick = () => finish(false);
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
function setKv(id, text, bad, cls) {
  const n = $(id);
  if (!n) return;
  n.textContent = (text === null || text === undefined || text === '') ? '--' : String(text);
  n.className = bad ? 'bad' : (cls || '');
}
// Step 2b: 跟 setKv 一样, 但指定 m-/p- 前缀, 写对应 tab 内的元素
// cls: 可选附加类(如 'info' 蓝), 用来表达"不是错、只是想区分"
function setKvPre(pre, id, text, bad, cls) {
  const fullId = pre ? (pre + id[0].toUpperCase() + id.slice(1)) : id;
  const n = $(fullId);
  if (!n) return;
  n.textContent = (text === null || text === undefined || text === '') ? '--' : String(text);
  n.className = bad ? 'bad' : (cls || '');
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

// 断连后把"从设备读来的值"清空 (2026-10)
//   留着会让人以为设备还在线、还停在那个档位 —— 截图上那种"串口已关闭
//   但页面还显示 sniff/正常/SN/IMEI"的状态最容易误判。
//   清的: 设备信息(只读框) + 所有状态卡的显示值 + 底栏的设备/模式/MQTT
//   保留: 首页 MQTT 的服务器地址/端口/凭证密码(本地配置, 重连还要用)
//   用户名(设备 SN 派生)清; ClientID 只在"还是设备自动值"时清(手输的保留)
function clearDeviceView() {
  [el.fSn, el.fImei, el.fIccid, el.fCsq, el.fVer, el.fProj, el.fUrl].forEach(e => {
    if (e) e.value = '';
  });
  // 所有 .kv-grid 里的显示值(首页总览 + 手动/平台/sniff 三张状态卡) → '--'
  document.querySelectorAll('.kv-grid .kv span').forEach(n => {
    n.textContent = '--';
    n.className = '';
  });
  // 其他生效 Topic 那几块是 pre(10 条 topic 清单), 也得清
  document.querySelectorAll('.kv-pre').forEach(n => {
    n.textContent = '--';
    n.className = 'kv-pre bad';
  });
  if (el.hMqUser) el.hMqUser.value = '';
  if (el.hMqClientId && (!S.autoClientId || el.hMqClientId.value === S.autoClientId)) {
    el.hMqClientId.value = '';
  }
  if (el.hMqErr) el.hMqErr.textContent = '';
  if (el.stSn) el.stSn.textContent = '--';
  if (el.stDev) el.stDev.textContent = '--';
  if (el.stMode) el.stMode.textContent = '--';
  if (el.stMqtt) el.stMqtt.textContent = '--';
}

function setPortState(open, path) {
  S.open = open;
  el.btnOpen.textContent = open ? '关闭串口' : '打开串口';
  el.stPort.textContent = open ? (path || S.port) : '未连接';
  el.stPort.style.color = open ? '#0a7d2c' : '#666';
  // 28-fix: 串口未连接时禁用首页 + 运行模式面板的功能按钮 + 顶部栏导入.
  //   设备没连, 按钮触发的命令要么发不出去, 要么发出去没意义, 灰掉避免误点.
  // 29-fix: 顶部栏导出 (btnExport) 也加入 (之前漏了).
  //   理由: 导出也是发设备命令 R:CFG + R:REG 把设备当前配置拉下来打包,
  //   没设备连就发不出去, 跟导入/读设备信息一类, 一并灰掉
  //   selBootMode 是 select, disabled 对 select 也有效
  //   注: btnImport 在 syncTabs 里另有一道 platform 档的守卫, 二者取或:
  //        串口未连 → 一定灰; 平台档 → 一定灰; 其他情况由 syncTabs 控制
  [el.btnReadInfo, el.btnReadCfg, el.btnPullCfg, el.btnSaveCfg, el.btnReadVal,
   el.btnHomeMqttSave,
   // 28-fix 新增 (5 个):
   el.btnImport,           // 顶部栏 导入
   el.btnHomeRefresh,      // 首页 状态总览 刷新
   el.btnModeRefresh,      // 运行模式 刷新状态
   el.selBootMode,         // 运行模式 开机默认模式 下拉
   el.btnSaveBoot,         // 运行模式 开机默认模式 保存
   // 29-fix 新增 (1 个):
   el.btnExport            // 顶部栏 导出
  ].forEach(b => { if (b) b.disabled = !open; });
  // btnImport 的 platform 档守卫要在 setPortState 之后跑, 否则会被覆盖
  // (syncTabs 现在是 mode 切换时调, 不是 port 切换时调, 所以这里手动补一下)
  // im-2: sniff 档也禁用导入 (sniff 档无表单可填, 导入会丢数据)
  // im-3: idle 档也禁用导入 (idle 档无配置, 导入没意义, 应先进 manual 档)
  if (el.btnImport) {
    const blocked = !open || isPlatform(S.mode) || S.mode === 'sniff' || S.mode === 'idle';
    el.btnImport.disabled = blocked;
    el.btnImport.title = !open ? '请先连接串口' :
      isPlatform(S.mode) ? '平台档配置从 MQTT 平台拉取，不能导入' :
      S.mode === 'sniff' ? 'sniff 档无表单可导入, 请切到手动档' :
      S.mode === 'idle' ? 'idle 档无配置, 请先切到手动档' :
      '导入配置文件 (.json / .csv)';
  }
  // im-3: btnExport 加 mode 守卫
  //   - platform 档: 开 (im-3 fix: 用户可导出平台拉下来的配置快照, 跟"导入禁用"语义不同)
  //   - idle 档: 禁 (idle 档无配置可导出, 用户应先进 manual 档看/改表单)
  //   - manual 档: 开
  //   - sniff 档: 开 (im-2 已加, 走 manual 档 prefix 导出)
  if (el.btnExport) {
    const blocked = !open || S.mode === 'idle';
    el.btnExport.disabled = blocked;
    el.btnExport.title = !open ? '请先连接串口' :
      S.mode === 'idle' ? 'idle 档无配置, 请先切到手动档' :
      '导出当前档配置 (sniff 档导 manual 档)';
  }
  // 29-fix: 4 个 mode-card (mcIdle/mcPoll/mcPollpull/mcSniff) 变灰
  //   28-fix 用 applyMode 拦截 + toast, 但用户希望视觉上就灰
  //   (toast 是兜底, 万一有别的入口绕过 .locked class 也能拦)
  // 35-fix: mcIdle 是逃生口, 永远不灰. 串口开了之后, idle 一定要能进.
  //   platform 档拉不到配置又不能切回 idle, 用户就被卡死了
  document.querySelectorAll('.mode-card').forEach(c => {
    c.classList.toggle('locked', !open && c.id !== 'mcIdle');
  });
  syncPullCfgBtn();
  // 档位标签显隐跟串口走 (2026-10): syncTabs 平时只在 mode 切换时调, 这里
  // 断连/连上时补一次, 否则标签要等下次切档才更新
  syncTabs();
  // 断连时如果正停在档位页(那个标签已被收起), 切回首页 —— 否则会留一个
  // 没有标签的页面在眼前, 看着像卡住
  if (!open) {
    const cur = document.querySelector('.tab-header .tab-item.active');
    const curId = cur && cur.getAttribute('data-tab');
    if (curId && curId !== 'tab0' && curId !== 'tabMode') activateTab('tab0');
    // 设备读来的值全部清空, 别留着"看着还在线"的残影
    clearDeviceView();
  }
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
    el.fUrl.value = d.server || d.url || el.fUrl.value;
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
    // 35b-fix: mcIdle 是逃生口, 哪怕在切换中也不能灰. 否则 platform 档
    //   等 waitPullDone 期间 idle 看起来禁用了, 用户不敢点
    if (c) {
      const shouldSwitch = !!S.modeSwitching && c.id !== 'mcIdle';
      if (c.classList.contains('switching') !== shouldSwitch) {
        c.classList.toggle('switching', shouldSwitch);
      }
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
    if (!S.detected && m.detected && m.detected.baud != null) {
      S.detected = m.detected;
      maybeAutoInfer(m.detected);   // 页面刷新后兜底采纳, 也补一次自动推断
    }
    if (S.detected) renderDetected();
    else el.detectHint.textContent = '';
  } else {
    S.detected = null;      // 离开 sniff 就作废: 下次进去会重新识别
    autoInferDone = '';     // 自动推断的"已推签名"跟着清: 再进 sniff 重新识别后要再推一次
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
  // ⚠️ 档位标签只在【串口已连接】时显示 (2026-10): 没连设备时 S.mode
  //   是上次会话的残留, 挂着"sniff模式"标签会让人以为设备还在 sniff
  const conn = !!S.open;
  const show = { tab0: true, tabMode: true,
    tabManual: conn && isManual(mode),
    tabPlatform: conn && isPlatform(mode),
    tabPoll: false,
    tabSniff: conn && mode === 'sniff' };
  Object.keys(show).forEach(id => {
    const t = document.querySelector('.tab-header .tab-item[data-tab="' + id + '"]');
    if (t) t.style.display = show[id] ? '' : 'none';
  });
  // 2h fix: 平台档配置从平台拉, 不允许手动导入, 按钮直接禁用
  // (之前 importCfg 起头 toast 拦截被用户否决, 改为 UI 层禁用,
  //  平台档点 "导入" 按钮没反应, 一看就懂)
  // 28-fix: 加一层 "串口未连接" 守卫. setPortState 已经把 btnImport 灰了,
  //   这里 mode 切换时也要保持灰 (避免 mode 切换把 setPortState 的灰给覆盖掉)
  if (el.btnImport) {
    // im-2: sniff 档也禁用导入 (sniff 档无表单可填, 导入会丢数据)
    // im-3: idle 档也禁用导入 (idle 档无配置, 导入没意义, 应先进 manual 档)
    const blocked = !S.open || isPlatform(mode) || mode === 'sniff' || mode === 'idle';
    el.btnImport.disabled = blocked;
    el.btnImport.title = !S.open ? '请先连接串口' :
      isPlatform(mode) ? '平台档配置从 MQTT 平台拉取，不能导入' :
      mode === 'sniff' ? 'sniff 档无表单可导入, 请切到手动档' :
      mode === 'idle' ? 'idle 档无配置, 请先切到手动档' :
      '导入配置文件 (.json / .csv)';
  }
  // im-3: btnExport 加 mode 守卫 (syncTabs 里补, 跟 setPortState 同步)
  //   im-3 fix: platform 档允许导出 (用户可导出平台拉下来的配置快照)
  if (el.btnExport) {
    const blocked = !S.open || mode === 'idle';
    el.btnExport.disabled = blocked;
    el.btnExport.title = !S.open ? '请先连接串口' :
      mode === 'idle' ? 'idle 档无配置, 请先切到手动档' :
      '导出当前档配置 (sniff 档导 manual 档)';
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
    // 35c-fix: 用户已切走 (applyMode 让 idle 能在 waitPullDone 期间也响应),
    //   设备模式已经不是 platform, 静默返回, 不弹"拉取失败/超时"误提示.
    //   设备可能根本就没收到完整的 platform 流程, 提示只会让用户困惑
    if ((S.modeStat || {}).mode !== 'platform') return false;
    // 33-fix 设备端撤掉了 MQTT 拦截, 轮询立即起来 (用 ds_pull 旧/空配置),
    //   所以 polling=true 不再代表拉取成功. 改用 pull.state === 'done' 判断
    //   (设备端 auto_apply 完成才置 'done', 此时新配置已落盘 + 已重启轮询)
    if (pull.state === 'done') {
      status('平台配置已拉取并生效，开始轮询', true);
      toast('已切换到 platform（拉取配置）模式，开始轮询');
      // 33-fix: 拉取成功, 设置横幅 pending 标记. 渲染器看到 tabPlatform 激活
      // 且未 dismiss 就会显示 pPullOkHint
      S.platformPullOkPending = true;
      renderPlatformHints();
      // quiet=true: 静默填表单, 避免 ds_pull 是空(首次进 platform 还没推)
      // 时弹「尚未保存过配置」误导用户以为配置没生效
      await readCfg(true);   // 表单回填成平台那份, 否则用户看到的还是手配的
      // 进 platform 时设备已被 ctrl 强制切到 MQTT 自动档, 不重读的话
      // MQTT 页那个手动档开关还停在旧状态, 和设备实际用的档位不一致
      readMqtt(true);
      return true;
    }
    // 轮询起来了但拉取还没完成 (常见: MQTT 未连接, host/port 没配)
    //   等拉取自动完成. 55s 后超时 waitPullDone 会返回 false, 不显示绿条
    if (polling && pull.state !== 'done') {
      // 静默继续等
    }
    if (pull.state === 'fail') {
      status('平台配置拉取失败：' + (pull.msg || '未知原因'), false);
      toast('拉取失败：' + (pull.msg || '未知原因') + '，模式已退回，可重试');
      return false;
    }
    // 34-fix: 拉取到了但应用失败 (auto_apply 失败: 配置不合法/存不下)
    //   单独区分 apply_fail 和 fail: 前者说明 MQTT 是通的, 是平台推的配置
    //   本身有问题; 后者是网络/超时. 给用户更精确的提示
    if (pull.state === 'apply_fail') {
      status('拉取到配置但应用失败：' + (pull.msg || '未知原因'), false);
      toast('平台配置不适用：' + (pull.msg || '未知原因') + '，轮询未启动，可联系平台管理员修正');
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
  // 35b-fix: idle 是逃生口, 哪怕在 waitPullDone 期间 (S.modeSwitching=true)
  //   也要能切回 idle. 串口单未决不会冲突, 新发的 W:MODE=idle 会在切
  //   platform 那条应答之后被设备处理
  if (S.modeSwitching && mode !== 'idle') return;
  // 28-fix: 串口未连接时禁止切档. 4 个 mode-card (mcIdle/mcPoll/mcPollpull/mcSniff)
  //   都走 applyMode, 在这里统一拦截 + toast 提示
  if (!S.open) {
    toast('请先连接串口');
    return;
  }
  // platform → manual 切档提示: 当前显示的是平台那份(ds_pull), 切过去
  // 后会清掉显示内容, 用户得自己点「读取配置」读 ds_poll 那份
  // "manual"/"platform" 是当前 mode 名; "poll"/"pollpull" 是历史别名
  // 38-fix: platform 切 manual/sniff 弹窗加 "清空平台拉取配置" 复选框,
  //   默认勾选. 切走意味着"不再用平台配置", 不清的话 ds_pull 留着, 用户
  //   切回 platform 时会被 34-fix 当成"已有旧配置"直接起, 不重新拉,
  //   这跟用户预期(切走就作废)不符
  if ((isManual(mode) || mode === 'sniff') && isPlatform(S.mode)) {
    const msg = '当前显示的是平台拉取配置 (ds_pull)。切换到「' + (MODE_LABEL[mode] || mode) +
      '」后, 切回 platform 档时是否清空这份配置?\n\n' +
      '• 勾选: 切档同时清空 ds_pull, 切回 platform 时重新从平台拉取\n' +
      '• 取消勾选: 保留 ds_pull, 切回 platform 时直接用旧配置起轮询';
    const r = await askConfirmCheck(msg, '切换运行模式',
      { label: '清空平台拉取配置 (ds_pull)', checked: true });
    if (!r.ok) return;
    if (r.checked) {
      // 38-fix: 先发 W:CLRPULL 清 ds_pull, 再发 W:MODE 切档. 即便
      //   W:CLRPULL 失败也继续切档 (设备端会用旧 ds_pull 起轮询, 用户
      //   可在 platform 面板点"重新拉取"补救), 弹个 toast 提示一下
      try {
        await sendCmd(Protocol.Enc.clrPull(), 'CLRPULL', 5000);
      } catch (e) {
        toast('清空 ds_pull 失败: ' + e.message + ' (切档后可能用旧配置)');
      }
    }
  }
  // 25-fix: 切到 platform 前预检 MQTT 连接状态 (弹窗拦截). 33-fix: 撤掉
  //   弹窗, 让用户自由进. 进入后 platform 面板顶部用 pMqttHint 横条提示
  //   MQTT 未连接, 「知道了」可点掉 (本会话内). 切走再回来还会再弹.
  //   设备端 (ctrl.lua) 仍会报清晰错误, 拉不到配置时用户能看到
  S.modeSwitching = true;
  S.modePending = mode;          // 先记下用户所选，防止 5s 定时刷新把高亮打回旧模式
  // 33-fix: 切到非 platform 档时清掉两个提示横幅的 dismiss/pending 状态,
  //   下次切回 platform 重新提示. 切到 platform 档不重置, 让 waitPullDone
  //   成功后再决定要不要显示
  if (!isPlatform(mode)) {
    S.platformMqttHintDismissed = false;
    S.platformPullOkHintDismissed = false;
    S.platformPullOkPending = false;
  }
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
      // sniff 卡的 MQTT 连接/状态信息同步刷一次 (R:MQTT): 别让用户切进来
      // 看到的是上一次会话的残影, 后来有人点「刷新」才更新
      readMqtt(true);
      const d = await pollDetect(25);
      if (d) {
        status('识别成功，开始旁听：' + serialDesc(d), true);
        toast('已识别 ' + serialDesc(d) + '，开始旁听');
      } else {
        // sniff-2 fix: 用户可能切走了 (35c-fix waitPullDone 那种场景),
        //   pollDetect 会因为 R:AUTODETECT 返 RET:FAIL:not in sniff mode
        //   立即返 null, 此时再弹"识别未完成"没意义 —— 设备都 idle 了
        //   谁还看这条? 在弹 toast 前再 check 一次 mode, 不在 sniff 就静默
        if (S.mode === 'sniff' || S.modePending === 'sniff') {
          status('识别未完成，设备会在后台每 3 秒重试直到认出来', false);
          toast('识别未完成，设备会自动重试；总线无流量时可检查 AB 线/从机');
        }
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
    if (r && r.data) {
      S.bootMode = r.data;
      // 同步 selBootMode 跟设备值, 刷新 dirty 状态
      // ⚠️ 只在"不脏"时同步: readBootMode 走 5s 定时器 (readHome) 也会到
      //   这里, 用户改了开机默认模式还没保存时, snapBootClean 会拿设备
      //   旧值覆盖下拉框并把 dirty 清掉 —— 表现为"没保存的修改过一会自己
      //   变回去, 保存按钮也回蓝" (2026-10 用户实测报出)。脏的时候只
      //   更新设备真值 S.bootMode, 不动用户的选择与按钮状态
      if (!S.bootDirty) snapBootClean();
    }
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
  // 30-fix: 串口未连接时 (S.modeStat/S.stat/S.mqtt.stat 都是空对象),
  //   原来用 'idle' / '未连接' / '未启用' 作默认值, 看起来像真值, 实际是假的.
  //   改成显式判 undefined → '--', 只在有应答的情况下才显示 'idle'/'已连接'/'未启用' 等真值
  // hMode: 有 mode 字段才显示模式名, 否则 '--' (原来 st.mode || 'idle' 是错的)
  setKv('hMode', st.mode ? (st.mode + (st.busy ? '（占用总线）' : '')) : '--');
  // hMqtt: mq.connected 是 undefined (没应答) → '--'; 是 false (应答了但没连) → '未连接' 红; 是 true → '已连接' 绿
  setKv('hMqtt',
    mq.connected == null ? '--' : (mq.connected ? '已连接' : '未连接'),
    mq.connected === false);
  setKv('hDevId', mq.device_id || (mq.sn || ''));
  // hWdt: wdt_to 是 undefined (没应答) → '--'; 是 0 (未启用) → '未启用'; 是 > 0 → '正常'/'停滞!'
  const wdtStalledNow = wdtStalled(g, !!(st.poll || {}).running).stalled;
  setKv('hWdt',
    g.wdt_to == null ? '--' : (g.wdt_to ? (wdtStalledNow ? '停滞!' : '正常') : '未启用'),
    wdtStalledNow);
  // 开机模式: 设备值 S.bootMode (R:BOOTMODE 应答), 跟本地 selBootMode 比对
  // 标 dirty (跟运行模式 tab 的 btnSaveBoot 同步)。这里只是渲染, dirty 状态
  // 状态由 refreshBootDirty() 维护 (改 selBootMode 时触发)
  const bootLabel = MODE_LABEL[S.bootMode] || S.bootMode || '--';
  setKv('hBootMode', bootLabel + (S.bootDirty ? ' *' : ''));
  // 首页 MQTT 地址/端口回填。5s 定时刷新会打到这里, 正在输入时不能抢,
  // 否则字打到一半被冲掉。密码要另外传 cfg —— stat 段不含 pass
  fillMqHome(mq, S.mqtt && S.mqtt.cfg);
  // 30-fix: 顶栏 MQTT 状态指示: 没应答时也显示 '--' (不要显示 '未连接', 那是 MQTT 自己的状态,
  //   没问过设备前不应该下结论). 有应答时按 connected 显示
  el.stMqtt.textContent = mq.connected == null ? '--' : (mq.connected ? '已连接' : '未连接');
  el.stMqtt.style.color = mq.connected ? '#0a7d2c' : '#999';
  renderPushBanner(mq);
  // 33-fix: 5s 定时刷新也刷两个 platform 档的提示横幅 (MQTT 状态变化时会重新显示)
  renderPlatformHints();
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

// 33-fix: platform 档两个提示横幅的渲染器.
//   - pMqttHint: MQTT 未连接时显示. 用户点「知道了」隐藏, 切到 tabPlatform 时重置
//   - pPullOkHint: 拉取成功 (waitPullDone 等到轮询起来) 时显示. 用户点「知道了」后
//                  本会话不重弹 (类比 pushIgnored)
// 调用点: renderHome() 末尾 (有数据就刷), readHome 5s 轮询
function renderPlatformHints() {
  const mqttBox = el.pMqttHint;
  const pullOkBox = el.pPullOkHint;
  if (!mqttBox || !pullOkBox) return;
  const mq = (S.mqtt && S.mqtt.stat) || {};
  const mqConnected = !!mq.connected;
  // 1. MQTT 未连接提示: 只在 platform 档 + tabPlatform 激活 + 未连接 + 未被 dismiss
  //    非激活 tab 上也隐藏, 避免切到 manual tab 还看到 platform 的横条
  const tabActive = document.getElementById('tabPlatform').classList.contains('active');
  const showMqtt = isPlatform(S.mode) && tabActive && !mqConnected && !S.platformMqttHintDismissed;
  mqttBox.hidden = !showMqtt;
  // 2. 拉取成功提示: 一次性. waitPullDone 触发时打开, 点了「知道了」关闭
  //    切档重置 (见 activateTab / applyMode). 平台档才显示
  const showPullOk = isPlatform(S.mode) && tabActive && !S.platformPullOkHintDismissed && S.platformPullOkPending;
  pullOkBox.hidden = !showPullOk;
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
  // 状态卡跟着设备实时状态走 (2026-10): R:STAT 的 mqtt 段已经并进
  //   S.mqtt.stat 了, 这里只重画状态卡(不碰任何输入框)。
  // 起因: 切 sniff 档时 MQTT 会断开重连, 那一刻读到的 connected=false,
  // 而状态卡只在 readMqtt(读全量)时才重画 → 重连成功后卡片一直显示
  //   "连接中/已断开", 切走再切回来才刷新(用户实测报出)。
  // renderMqttStatus 只画状态部分, 用户正在编辑的 MQTT 表单不会被冲掉。
  //
  // ⚠️ 这一句必须放在上面的 try【外面】: R:STAT 超时/失败时(串口忙、
  //   设备在识别), 上面整段会被 catch 掉, 状态卡就永远不重画 —— 而底栏
  //   (renderHome)也是同一轮, 用户会看到"底栏已连接、卡片未连接"的自相矛盾。
  try {
    if (typeof renderMqttStatus === 'function') renderMqttStatus();
  } catch (e) {
    console.warn('[mqtt] 状态卡重画失败:', e);
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

// 重新识别前的界面复位 (2026-10)。
// 设备端 R:AUTODETECT=restart 已经把旧帧/旧值/旧识别结果清空了, 前端这边
// 必须同步清掉对应的缓存与画面, 否则:
//   - "已识别: 19200/8/N/1" 继续挂着旧参数 (识别期间参数还没定, 挂着像结论)
//   - 推断表挂着一张旧参数下推出来的表, 容易被当成新一轮的结果
//   - 总线报文表挂着旧参数下抓的帧
// 注意顺序: 复位放在设备回"已受理"之后 —— 万一设备回 FAIL(不在 sniff 档),
// 什么都没发生, 画面就不该被动过
function resetSniffView() {
  S.detected = null;      // 已识别参数
  S.infer = null;         // 推断结果
  S.frames = [];          // 总线报文(设备端也清了)
  if (el.inferHint) el.inferHint.textContent = '';
  if (el.inferTbody) {
    el.inferTbody.innerHTML = '<tr><td colspan="9" style="color:#999;">点击"推断轮询表"从已监听到的报文反推</td></tr>';
  }
  renderFrames();         // 报文表回到空态
  renderDetected();       // S.detected=null → 提示清空 + 颜色回灰
}

// 推断表里给某个寄存器起名字的弹窗 (2026-10)。
// 两个输入: 参数名称(= 上报 name, 平台显示用) / 建议标识符(= 上报 id, 平台
// 物模型按它建属性)。留空 = 恢复默认(名称跟标识符都退回 reg<addr>)。
// 下面有实时预览: 存下去之后上报给平台的长什么样, 免得存完才发现填错。
// 风格参考 askEditInterval (.modal.modal-open + .modal-content)
function askEditRegName(row) {
  return new Promise(resolve => {
    const key = 'reg' + row.addr;
    const curId = row.id || key;
    const curName = row.name || '';
    const modal = document.createElement('div');
    modal.className = 'modal modal-open';
    modal.innerHTML = `
      <div class="modal-content" style="text-align:left;width:420px;">
        <h3 style="margin:0 0 4px 0;">给寄存器起名</h3>
        <div style="font-size:12px;color:#666;margin-bottom:12px;">
          从机 ${esc(row.slave)} · 寄存器地址 ${esc(row.addr)} · 功能码 0x${esc(String(row.fc == null ? '?' : row.fc).padStart(2, '0').toUpperCase())}
        </div>
        <div style="margin-bottom:10px;">
          <div style="font-size:12px;color:#666;margin-bottom:3px;">参数名称（上报 name，平台上显示的名字）</div>
          <input id="edName" type="text" maxlength="64" placeholder="例：A相电流" value="${esc(curName)}"
                 style="width:100%;box-sizing:border-box;padding:7px 8px;border:1px solid #dde2ea;border-radius:4px;font-size:13px;">
        </div>
        <div style="margin-bottom:10px;">
          <div style="font-size:12px;color:#666;margin-bottom:3px;">建议标识符（上报 id，平台按它建属性）</div>
          <input id="edId" type="text" maxlength="64" placeholder="例：CT1" value="${esc(curId)}"
                 style="width:100%;box-sizing:border-box;padding:7px 8px;border:1px solid #dde2ea;border-radius:4px;font-size:13px;">
        </div>
        <div id="edPreview" style="font-family:Menlo,Consolas,monospace;font-size:12px;color:#0a7d2c;
             background:#f4f6f9;border:1px solid #e6eaf0;border-radius:4px;padding:8px;margin-bottom:12px;"></div>
        <div style="display:flex;gap:8px;align-items:center;">
          <button id="edSave" class="primary" style="flex:1;padding:9px;">保存</button>
          <button id="edReset" style="padding:9px 12px;">恢复默认</button>
          <button id="edCancel" style="padding:9px 12px;background:transparent;color:#666;border:1px solid #dde2ea;">取消</button>
        </div>
        <div style="font-size:11px;color:#999;margin-top:8px;">
          保存后设备会按新名字上报；改标识符会让平台按新标识符重建物模型。<br>
          点「重新识别通讯参数」会开启新一轮识别，这些名字也会一起清空。
        </div>
      </div>`;
    document.body.appendChild(modal);
    const nameEl = modal.querySelector('#edName');
    const idEl = modal.querySelector('#edId');
    const prevEl = modal.querySelector('#edPreview');
    const preview = () => {
      const id = idEl.value.trim() || key;
      const nm = nameEl.value.trim() || id;
      prevEl.textContent = '上报: { id: "' + id + '", name: "' + nm + '" }';
    };
    preview();
    nameEl.addEventListener('input', preview);
    idEl.addEventListener('input', preview);
    const close = v => { document.body.removeChild(modal); resolve(v); };
    modal.querySelector('#edSave').onclick = () => close({
      id: idEl.value.trim(),
      name: nameEl.value.trim(),
    });
    // 恢复默认: 两个都清空 = 设备端删掉这条别名, 回到 reg<addr>
    modal.querySelector('#edReset').onclick = () => close({ id: '', name: '' });
    modal.querySelector('#edCancel').onclick = () => close(null);
    modal.addEventListener('click', e => { if (e.target === modal) close(null); });
    setTimeout(() => nameEl.focus(), 30);
  });
}

// 保存一条别名并刷新推断表
async function saveAlias(row, id, name) {
  const key = 'reg' + row.addr;
  try {
    await sendCmd(Protocol.Enc.aliasWrite({ key: key, id: id, name: name }), 'SALIAS', 4000);
    status('已保存 ' + key + ' 的名字，下次上报生效', true);
    toast('已保存：' + (name || id || key) + '（下次上报生效）');
    await doInfer();          // 重推一轮推断表，把新名字显示出来
    return true;
  } catch (e) {
    status('保存失败：' + e.message, false);
    toast('保存失败：' + e.message);
    return false;
  }
}

async function doInfer(silent) {
  // silent: 自动触发(切 sniff 面板)时用 —— 每次切面板都弹一次 toast 太吵
  // ⚠️ 撞"上一条指令尚未返回"时重试一次: 串口是单未决设计, 同一时刻只能
  //   有一条指令在途。5s 定时器(读首页)正好在途时会撞上, 不重试的话自动
  //   刷新会静默失败 —— 表现就是"切进 sniff 面板表没更新"
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const r = await sendCmd(Protocol.Enc.infer(), 'INFER', 4000);
      S.infer = r.data;
      renderInfer();
      if (toArr(S.infer && S.infer.regs).length) {
        if (!silent) status('推断出 ' + toArr(S.infer.regs).length + ' 个轮询项', true);
        // 不能提"应用到轮询配置": 那个按钮和 W:APPLYINFER 已经删了,
        // 推断结果只作参考, 由人工核对后自行配置(见 lua/README.md 配置隔离)
        if (!silent) toast('推断完成，结果仅供参考，请核对后自行配置');
      } else if (!silent) {
        status('未监听到请求帧，先在旁听模式下观察一段时间', false);
        toast('还没有监听到请求帧');
      }
      return;                       // 成功就收工, 别再发第二条
    } catch (e) {
      if (attempt === 0 && /尚未返回/.test(e.message || '')) {
        await new Promise(r => setTimeout(r, 500));   // 等上一条指令回完再试
        continue;
      }
      if (!silent) {
        status('推断失败：' + e.message, false);
        toast('推断失败：' + e.message);
      } else {
        console.warn('[sniff] 自动推断失败:', e.message);
      }
      return;
    }
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
    el.inferTbody.innerHTML = '<tr><td colspan="9" style="color:#999;">暂无推断结果</td></tr>';
    return;
  }
  el.inferTbody.innerHTML = regs.map(r => {
    // 最新值: 设备只带被解出过的地址; 浮点显示截 4 位小数(纯展示, 不改数据)
    const v = (r.value != null && typeof r.value === 'number' && !Number.isInteger(r.value))
      ? Math.round(r.value * 1e4) / 1e4 : r.value;
    const akey = 'reg' + r.addr;
    return '<tr>' +
    '<td>' + esc(r.slave) + '</td>' +
    '<td>' + esc(r.addr) + '</td>' +
    '<td>' + esc(r.count) + '</td>' +
    '<td>0x' + (r.fc != null ? r.fc.toString(16).padStart(2, '0').toUpperCase() : '?') + '</td>' +
    '<td>' + esc(r.hits) + '</td>' +
    '<td title="' + esc(r.dtype || '-') + '" style="font-family:monospace;font-size:12px;color:#0066cc;">' + esc(r.dtype || '-') + '</td>' +
    '<td title="旁听应答最新解析值" style="font-family:monospace;font-size:12px;">' +
      (v != null ? esc(v) : '<span style="color:#999;">--</span>') + '</td>' +
    // 参数名称: 与 U4 上报 payload 的 name 同一字段 (设备端 attach_names 给的);
    // 可点击改名 (2026-10)。老固件不带 name 时退显示 reg<addr>
    '<td class="ed-cell" data-alias-key="' + esc(akey) + '" data-alias-field="name" ' +
      'title="点击编辑上报用的参数名称">' + esc(r.name || akey) + '</td>' +
    // 建议标识符: 上报用的 id。改名会让平台按新 id 重建物模型
    '<td class="ed-cell" data-alias-key="' + esc(akey) + '" data-alias-field="id" ' +
      'title="点击编辑上报用的标识符(id)">' + esc(r.id || akey) + '</td>' +
    '</tr>';
  }).join('');
}

// 推断表里点"参数名称 / 建议标识符"单元格 → 弹窗改名 (2026-10)
// 事件委托: 表格是 innerHTML 重绘的, 绑在 tbody 上最省事
if (el.inferTbody) {
  el.inferTbody.addEventListener('click', async e => {
    const td = e.target && e.target.closest ? e.target.closest('.ed-cell') : null;
    if (!td) return;
    const key = td.getAttribute('data-alias-key');
    const regs = toArr(S.infer && S.infer.regs);
    const row = regs.find(r => 'reg' + r.addr === key);
    if (!row) return;
    const v = await askEditRegName(row);
    if (!v) return;
    await saveAlias(row, v.id, v.name);
  });
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

// 识别成功后自动推断一次 (2026-10 需求): 原本推断得手动点「推断轮询表」,
// 现在识别到位就先推一遍, 少一次手动操作。
// 触发口有 3 个, 都收口到这里:
//   ① 切档自动识别 (applyMode sniff → pollDetect 成功)
//   ② 手动「重新识别」(autoDetect, 头答/轮询两条路)
//   ③ 5s 状态轮询兜底采纳 (页面刷新后设备已识别的场景)
// fallback (21 组候选没认出、兜底 cfg.BAUD) 不算识别成功, 不触发;
// 同一参数签名只自动推一次, 防止 5s 轮询反复弹「推断完成」
let autoInferDone = '';
function maybeAutoInfer(d) {
  if (!d || d.baud == null || d.fallback) return;
  const sign = serialDesc(d);
  if (autoInferDone === sign) return;
  autoInferDone = sign;
  status('识别成功，自动推断轮询表…', true);
  doInfer();   // 不 await: 调用方流程继续, 推断自己走命令队列
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
      maybeAutoInfer(d);
      return d;
    }
  }
  return null;
}

// 手动「重新识别」。设备侧 request_detect() 会作废当前轮并从第一个候选重新扫,
// 所以识别中点它等于立刻重启一轮, 不用先停再进
async function autoDetect() {
  try {
    status('正在识别通讯参数…（新一轮识别，旧的参数名称会一起清空）', true);
    // 2026-10: 重新识别 ≠ 读当前结果。裸发 R:AUTODETECT 时, 设备若已有
    //   last 结果会头答直接回旧值 —— 现象就是"点了没重扫, 只是复读参数"。
    //   改发 R:AUTODETECT=restart: 设备作废上一轮 (清 monitor 结果) 并从
    //   第一个候选重扫, 头答 BUSY, 下面 pollDetect 等到的是新扫出来的参数
    autoInferDone = '';   // 强扫成功后允许 maybeAutoInfer 再推一轮(新结果会触发)
    const r = await sendCmd(Protocol.Enc.autoDetect() + '=restart', 'AUTODETECT', 4000);
    const raw = typeof r.raw === 'string' ? r.raw : '';
    if (raw.indexOf('RET:FAIL') === 0) {
      status('识别失败：先进旁听模式（运行模式页选 sniff）', false);
      toast('识别失败：当前不在旁听模式');
      return;
    }
    // 设备已受理重扫(并清空旧帧/旧值/旧结果), 前端同步复位画面:
    // 旧"已识别"参数、旧推断表、旧报文全部撤掉, 免得被当成这一轮的结果
    resetSniffView();
    el.detectHint.className = 'hint';
    el.detectHint.textContent = '正在识别通讯参数…';
    // restart 的头答一定是 BUSY(设备刚开始扫), 所以正常都走 pollDetect 等新结果;
    // 留着 r.data 分支只是兜底(万一设备已经扫完了, 直接用)
    const d = (r.data && r.data.baud != null) ? r.data : await pollDetect(25);
    if (!d) {
      // 25s 还没出结果 ≠ 失败: 设备会一直重试, 这里只告知"还没认出来"
      status('识别未完成，设备会在后台继续重试', false);
      toast('识别未完成，设备会自动重试直到认出来');
      return;
    }
    status('识别成功：' + serialDesc(d) + '（仅本次会话，未改配置）', true);
    toast('已识别 ' + serialDesc(d) + '（仅本次会话，未改配置）');
    maybeAutoInfer(d);
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
  if (!d || d.baud == null) {
    // ⚠️ 识别中【不要】清提示 (2026-10): 进度文案("正在识别通讯参数…第 N 轮,
    //   最坏 21 秒…")是 renderDetecting 写的, 而 readFrames 每 2 秒调一次
    //   renderDetected —— 一清就把进度抹了, 用户永远看不到识别进度
    //   (实测: 提示一闪就没)。识别结束仍没结果(兜底失败)才清空
    const monSt = (S.modeStat && S.modeStat.mon) || {};
    if (!monSt.detecting) {
      el.detectHint.className = 'hint';
      el.detectHint.textContent = '';
    }
    return;
  }
  // 从站号另起一段并标明"观测": 被动旁听拿不到从站号, 它是从报文里数出来的,
  // 和上面 4 个"识别"出来的参数不是一个性质, 含混写成一个"已识别"会误导
  const sl = observedSlave();
  // Q2: fallback (静默监听 21 候选都失败, 兜底 cfg.BAUD). 区分"识别命中"跟"兜底"
  // sniff-3 j: 兜底时不再混着显示兜底 baud, 只显示"待识别(未接总线或无流量)"
  //   兜底 baud 是 cfg.BAUD 默认值 (例如 9600/8/N/1), 跟总线上没流量时一致,
  //   user 看不出"识别到了", 写出来会误导. 等真识别命中后再显示 baud.
  if (d.fallback) {
    el.detectHint.className = 'hint';
    el.detectHint.textContent = '待识别(未接总线或无流量)';
    return;
  }
  // 已识别: 绿色加粗, 与下面状态栏位 (.kv span / ro-val 的 #0a7d2c) 一致
  el.detectHint.className = 'hint ok';
  el.detectHint.textContent = '已识别：' + serialDesc(d) +
    (sl != null ? ' · 观测到从站 ' + sl : ' · 从站未观测到（先听一会儿报文）');
}

// 识别进行中的提示。由 renderMode() 在读到 mon.detecting 时调用, 和
// renderDetected() 共用同一个 span, 所以两者互斥 —— 识别中不显示"已识别",
// 认出来了才显示
function renderDetecting(st) {
  el.detectHint.className = 'hint';   // 识别中回灰色 (成功时 renderDetected 才转绿)
  const round = st.detect_round || 0;
  const fail = st.detect_fail || 0;
  el.detectHint.textContent = '正在识别通讯参数…（第 ' + round + ' 轮' +
    (fail > 0 ? '，已失败 ' + fail + ' 次' : '') +
    '，最坏 21 秒，完成后自动开始旁听）';
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
    ['响应超时ms', 'timeout_ms'],
    // im-2: 加 server 列 (配置服务器url, 来自首页 fUrl 只读显示)
    ['服务器地址', 'server']
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

// data: { serial, registers, mqtt, mqtt_status, device_status } - 内部统一格式
// im-4: 加 mqtt_status 段 (设备 R:STAT 来的 mqtt 段, 只读快照)
//   - 含 connected / want_run / subscribed / client_id / user /
//     device_id / sub / pub_topics / keep_session 等运行态
//   - CSV 不导 (sub/keep_session/pub_topics 不太适合表格, JSON 优先)
// im-6: 加 device_status 段 (设备 R:STAT 来的 mode + data + guard 3 段, 设备运行态)
//   - 跟 mqtt_status 段平级, 但不含 mqtt 段 (mqtt 走 mqtt_status 段, 不重复)
//   - 没拉到 R:STAT 时 (S.stat 不存在): 返 null
//   - CSV 不导 (对象, 不适合表格)
function exportCfgAsJson(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const c = collectCfg(pre);
  if (!c.ok) { toast('当前表单配置无效，无法导出：' + c.err); return; }
  const data = {
    // im-5 6a: version 从 window.__APP_VERSION__ 读 (index.html 注入, 跟 package.json 同步)
    //   没读到时 (老环境/异常) fallback 'unknown', 不让导不出去
    tool: 'VKBox配置工具', version: (window.__APP_VERSION__ || 'unknown'),
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
      keep_session: E(pre, 'mqKeepSession').value === '1',
      auto: { pass: (S.mqtt && S.mqtt.auto_pass) || '' },
      manual_on: S.mqManual
    },
    // im-4: MQTT 运行态快照 (设备 R:STAT mqtt 段, 没拉到时 null)
    //   字段: connected / want_run / subscribed / client_id / user /
    //         device_id / sn / sub / pub_topics / keep_session 等
    mqtt_status: (S.mqtt && S.mqtt.stat) || null,
    // im-6: 设备运行态 (R:STAT 4 段里的 mode + data + guard, 不含 mqtt 段)
    //   - mode:  { mode, busy, poll, mon } 当前 485 模式 + 占用状态
    //   - data:  { pushed, frames, raw, points, ring } Modbus 采集数据状态
    //   - guard: { uptime, feed, stall, wdt_to } 看门狗状态
    device_status: S.stat ? {
      mode:  S.stat.mode  || null,
      data:  S.stat.data  || null,
      guard: S.stat.guard || null
    } : null
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
    keep_session: E(pre, 'mqKeepSession').value === '1'
  };
  // CSV 不存 keep_session / auto.pass / manual_on, 注释里说明
  const csv = toCsv({
    serial: c.cfg,
    registers: collectRegs(pre),
    mqtt: m
  });
  // 头部注释: 手动档额外字段
  const headerNote = '# manual_on=' + S.mqManual + ', keep_session=' + m.keep_session + '\n';
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
  // im-2: sniff 档无 485 表单, 用 manual 档 prefix ('m') 导出当前手动档配置.
  //   用户在 manual 档配好 baud/databits/parity/stopbits/interval/从机/寄存器表
  //   切 sniff 看, 想保存一份备份就用导出. 平台档仍然禁用 (syncTabs 守门).
  if (S.mode === 'sniff') {
    pre = 'm';
    toast('sniff 档无表单, 导出当前手动档配置');
  }
  const fmt = await askExportFormat();
  if (fmt === 'json') return exportCfgAsJson(pre);
  if (fmt === 'csv')  return exportCfgAsCsv(pre);
}

// 2h importCfg: 文件选择框 (filter .json,.csv), 选完按扩展名 dispatch
// 平台档已被 syncTabs 禁用 btnImport, 此处不需再检查 isPlatform
// im-2: sniff 档也禁用导入, sniff 档无表单可填, 导入会丢数据
async function importCfg(pre) {
  if (pre === undefined) pre = cfgPrefix();
  if (S.mode === 'sniff') {
    toast('sniff 档无表单可导入, 请切到手动档再导入');
    return;
  }
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
        // im-5 6b: JSON 导入时做版本校验 (major version 不同拒绝, minor/patch 兼容)
        //   - 没 version 字段 (老格式): 接受, 兼容
        //   - major 相同 (1.0.0 / 1.0.1): 接受; 1.x 与 2.x 互导也放行(版本重置, 导出格式一致)
        //   - 别的 major (3.x+): 拒绝 + 提示
        //   - CSV 不校验 (CSV 没 version 字段)
        if (fmt === 'JSON') {
          const cur = (window.__APP_VERSION__ || 'unknown');
          if (data.version != null) {
            const curMajor = String(cur).split('.')[0];
            const impMajor = String(data.version).split('.')[0];
            // 1.0.0 是【版本重置】(从 2.x 回到 1.0), 导出格式跟 2.x 完全一样,
            // 所以 1.x 与 2.x 的配置互导都该放行; 别的 major(3.x+) 才算不兼容
            const compatible = (curMajor === impMajor)
              || (curMajor === '1' && impMajor === '2')
              || (curMajor === '2' && impMajor === '1');
            if (!compatible) {
              throw new Error('版本不兼容 (导入 v' + data.version + ', 当前 v' + cur + ')');
            }
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
  // 5s 定时器: 等串口空出来再跑, 不要"忙就整轮跳过"。
  //   识别期间前端每秒在轮询 R:AUTODETECT, 串口几乎一直忙 —— 原来忙就
  //   return, 于是 5s 定时器次次跳过, 状态卡永远不重画(用户实测: 识别完成
  //   后卡片还显示"连接中/已断开")。排队等空闲最多 3s, 挤进轮询的间隙。
  homeTimer = setInterval(async () => {
    if (S.pending) {
      const t0 = Date.now();
      while (S.pending && Date.now() - t0 < 3000) {
        await new Promise(r => setTimeout(r, 200));
      }
      if (S.pending) return;   // 3s 还腾不出来, 这轮放弃(下轮再来)
    }
    try { await readHome(); } catch (_) {}
  }, 5000);
  frameTimer = setInterval(() => {
    // sniff-3 i: 总开关 (frameSectionOn) 关时不跟设备交互. 开关开 + 自动刷新勾选
    //   + sniff 模式 + 无 pending 才会发 R:FRAMES
    if (!S.pending && el.frameSectionOn && el.frameSectionOn.checked
        && el.frameAuto.checked && S.mode === 'sniff') readFrames();
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

// 33-fix: platform 档两个提示横幅的「知道了」按钮
//   - MQTT 未连接: 关闭本会话内的提示, 切到 tabPlatform 时重置 (状态没变)
//   - 拉取成功: 关闭本会话内的提示, 不重弹 (类比 pushIgnored)
if (el.pBtnMqttHintIgnore) el.pBtnMqttHintIgnore.onclick = () => {
  S.platformMqttHintDismissed = true;
  if (el.pMqttHint) el.pMqttHint.hidden = true;
};
if (el.pBtnPullOkIgnore) el.pBtnPullOkIgnore.onclick = () => {
  S.platformPullOkHintDismissed = true;
  S.platformPullOkPending = false;   // 不再尝试显示
  if (el.pPullOkHint) el.pPullOkHint.hidden = true;
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
 el.mqInterval, el.mqKeepSession,
 el.mMqHost, el.mMqPort, el.mMqSsl, el.mMqUser, el.mMqPass, el.mMqClientId,
 el.mMqPub, el.mMqSub, el.mMqInterval, el.mMqKeepSession,
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
    // 35-fix: idle 永远是逃生口, 串口没开也能进 (进 idle 不需要发命令,
    //   不会因为串口断而失败). 这条在 locked 拦截之前, 否则 platform 档
    //   拉不到配置又不能切回 idle, 用户就被卡死了
    if (m === 'idle') {
      // 不走 locked 检查, 但仍需串口开着 (进 idle 也要发 W:MODE=idle)
      if (!S.open) { toast('请先连接串口'); return; }
      // 35b-fix: 也不等 modeSwitching. platform 档切过去后 applyMode 在
      //   await waitPullDone (最多 55s), 这期间 S.modeSwitching=true,
      //   35-fix 漏了这个守卫, idle 还是被卡住. 串口单未决, 新发的
      //   W:MODE=idle 会被设备在切 platform 那条应答之后处理, 不会有竞争
      if (m === S.mode && !S.modePending) { renderMode(); return; }
      const label = MODE_LABEL[m] || m;
      const curLabel = MODE_LABEL[S.mode] || S.mode;
      if (!await askConfirm('确定把 485 运行模式从「' + curLabel + '」切换到「' + label + '」？\n\n'
                   + '切换时设备会先停掉旧模式再启动新模式（互斥），'
                   + '正在进行的采集会中断。'
                   // 切回空闲不只是停总线, 设备会顺带复位用户配置。这是不可恢复的
                   // 删除动作, 必须在同一个弹窗里一次说清, 不能让用户点完才知道
                   + idleWipeWarn(m), '切换运行模式')) return;
      applyMode(m);
      return;
    }
    // 非 idle 档: 走原来的 locked 守卫
    if (c.classList.contains('locked')) return;  // 35-fix: locked 卡片不响应
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
// sniff 面板的上报周期: readonly + 点击弹窗修改, 跟 platform 档 pMqInterval 同套
//   弹窗确认后同步 snMqInterval → mqInterval, 走 saveMqtt 走 W:MQTT
if (el.snMqInterval) {
  el.snMqInterval.addEventListener('click', async () => {
    const cur = parseInt(el.snMqInterval.value, 10) || 120;
    const v = await askEditInterval(cur);
    if (v == null || v === cur) return;
    el.snMqInterval.value = String(v);
    if (el.mqInterval) el.mqInterval.value = String(v);
    status('正在保存上报周期 ' + v + ' 秒…', true);
    try {
      await saveMqtt();
      status('已保存上报周期 ' + v + ' 秒', true);
      toast('上报周期已改为 ' + v + ' 秒');
    } catch (e) {
      status('保存失败：' + e.message, false);
      toast('保存失败：' + e.message);
    }
  });
}
if (el.btnHomeMqttPassEye) el.btnHomeMqttPassEye.onclick = togglePassEye;
// Step 2i: 删 btnMqttReset.onclick — 整**个**按**钮**已**从** HTML 移**除**(有**刷**新**了**, 按**钮**冗**余**)
// 如**果**用**户**需**要**重**置**配**置**, 手**动**改**每**一**项** (有**填**的**就**清**空**) + 走**保**存**即**可**

// 报文页 (sniff-3 f: 重新分配按钮绑定)
//   btnFrameRefresh/btnFrameClear 在总线报文子分段, 绑 frameLog
//   btnInferRefresh/btnInferClear 在 sniff嗅探 panel-title (刷新=重推一轮, 清空=推断表还原)
if (el.btnInferRefresh) el.btnInferRefresh.onclick = doInfer;
el.btnFrameRefresh.onclick = () => {
  // sniff-3 i: 总开关 (frameSectionOn) 关时手动刷新也不发 R:FRAMES
  if (el.frameSectionOn && !el.frameSectionOn.checked) return;
  readFrames();
};
el.btnFrameClear.onclick = () => { S.frames = []; renderFrames(); renderDetected(); };
if (el.btnInferClear) {
  el.btnInferClear.onclick = () => {
    // 推断表清空: inferTbody 还原到初始"点击'推断轮询表'从已监听到的报文反推"
    if (el.inferTbody) {
      el.inferTbody.innerHTML = '<tr><td colspan="9" style="color:#999;">点击"推断轮询表"从已监听到的报文反推</td></tr>';
    }
    if (el.inferHint) el.inferHint.textContent = '';
    if (el.detectHint) el.detectHint.textContent = '';
    // 同步清掉 S 里保存的推断结果
    if (S.infer) S.infer = null;
    status('已清空推断结果', true);
  };
}
// sniff-3 g/h: 总线报文子分段的滑动开关, 默认 unchecked
//   - 关: 隐藏 frameButtons ([刷新][清空]) + frameBody (类型筛选+frame-log)
//   - 开: 显示
// 初始化时按 checked 状态设一次, 之后 onchange 切换
// 注意: 不能用 el.frameButtons.hidden = !on, 因为 frameButtons 元素上有
//   style="display:flex" 内联样式, 优先级高于 [hidden]{display:none} 属性选择器,
//   开了 hidden 也被内联 display:flex 覆盖回来, 实际不隐藏. 改用 style.display 直接设
function applyFrameSection(on) {
  const disp = on ? '' : 'none';
  if (el.frameButtons) el.frameButtons.style.display = disp;
  if (el.frameBody) el.frameBody.style.display = disp;
}
if (el.frameSectionOn) {
  applyFrameSection(!!el.frameSectionOn.checked);
  el.frameSectionOn.addEventListener('change', (e) => {
    applyFrameSection(!!e.target.checked);
  });
}
el.frameFilter.onchange = renderFrames;
el.btnInfer.onclick = doInfer;
el.btnAutoDetect.onclick = autoDetect;

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
  // 33-fix: 切到 tabPlatform 时重置 pMqttHint 的 dismiss 状态. 切走再回来
  //   时 MQTT 还是未连接, 状态没变, 应该再弹一次提示. (platformPullOkHint
  //   不重置, 类比 pushIgnored, 拉取成功是一次性提示)
  if (tabId === 'tabPlatform') {
    S.platformMqttHintDismissed = false;
    renderPlatformHints();
  }
  // 切到 sniff 面板: 刷报文 + 刷 MQTT 信息 + 自动重推一次推断表
  //   (2026-10 用户要求: 每次切进来, 标题栏那个[刷新]的动作自动做一遍)
  // ⚠️ 必须【串行】不能并发: 串口是单未决设计, 同一时刻只能有一条指令在途。
  //   三条一起发, 后两条直接撞"上一条指令尚未返回"直接失败 —— doInfer 又是
  //   静默的, 于是切进来看着就是"自动刷新没生效"(表一直空着)。
  //   顺序也讲究: 先 MQTT(用户最先看), 再报文, 最后推断表(最慢)
  if (tabId === 'tabSniff' && S.open) {
    (async () => {
      await readMqtt();
      if (S.mode === 'sniff') {
        await readFrames();
        await doInfer(true);
      }
    })();
  }
  // pollpull 档: 进 poll tab 时静默读一份 ds_pull 填表单 —— 软件一打开
  // 就是 pollpull (没有 applyMode 这一步) 也覆盖。push 自动刷新另见
  // renderPushBanner. applyMode 钩子已删除 (窄), 这个钩子宽
  if (tabId === 'tabPoll' && isPlatform(S.mode)) readCfgSilent();
  // Step 1b fix: 同样, manual/platform tab 静默读一次配置
  // 26-fix: 之前只判 isPlatform, 手动档 (S.mode='manual') 进 manual tab
  //   时不读 ds_poll, 点表信息一直是空的。手动档是本地配 (ds_poll),
  //   一样需要 activateTab 时读一次填表单
  if ((tabId === 'tabManual' || tabId === 'tabPlatform') && S.open) {
    if (isManual(S.mode) || isPlatform(S.mode)) readCfgSilent();
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
    // 26-fix: 同样, 手动档切到 s1 (485 总线) 时也读一次 ds_poll
    if (key === 's1' && (isManual(S.mode) || isPlatform(S.mode))) readCfgSilent();
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
          interval_s: 120, keep_session: false,
          auto: { pass: 'VKBOXGW2026KEY' }, manual_on: false },
  published: 0,
  // sniff 别名表 (2026-10): 浏览器预览里也能改名看效果
  alias: { regs: [] }
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
          // 32-fix: 实际发送的 topic 列表 (和设备 profile().pub_topics 对齐)
          pub_topics: ['/sys/thing/node/property/post/' + (MOCK.sn || '11802026092600016') + '-1'],
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
            // 32-fix: 实际发送的 topic 列表 (和设备 M.status().pub_topics 对齐)
            pub_topics: ['/sys/thing/node/property/post/VK20260925001-1'],
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
  else if (line === 'R:INFER') {
    // 别名表里的名字要反映到推断表 (浏览器预览里改名后重推能看到变化)
    const mregs = [
      { slave: 1, addr: 100, count: 2, fc: 3, hits: 12, value: 42 },
      { slave: 2, addr: 0, count: 10, fc: 3, hits: 5, value: null }
    ].map(r => {
      const key = 'reg' + r.addr;
      const sa = MOCK.alias.regs.find(x => x.key === key);
      return Object.assign({}, r, {
        id: sa ? (sa.id || key) : key,
        name: sa ? (sa.name || sa.id || key) : key,
      });
    });
    resp = 'RET:INFER=' + JSON.stringify({
      regs: mregs,
      slaves: [1, 2],
      stat: { frames: 24, reqs: 12, rsps: 11, errs: 0, paired: 10, orphans: 1, detect_round: 0, detect_fail: 0 }
    });
  }
  // sniff 别名表 (2026-10): 浏览器预览里也能改名
  else if (line === 'R:SALIAS') resp = 'RET:SALIAS=' + JSON.stringify(MOCK.alias);
  else if (line.indexOf('W:SALIAS=') === 0) {
    let o = null;
    try { o = JSON.parse(line.slice('W:SALIAS='.length)); } catch (e) { o = null; }
    if (!o || !o.key) resp = 'RET:FAIL:SALIAS:bad json';
    else {
      const regs = MOCK.alias.regs.filter(r => r.key !== o.key);
      if (o.id || o.name) regs.push({ key: o.key, id: o.id || '', name: o.name || '' });
      MOCK.alias = { regs: regs };
      resp = 'RET:SALIAS=OK';
    }
  }
  // 浏览器预览: 模拟"进了 sniff 但还在识别"这一小段, 让「正在识别」提示
  // 在没接真设备时也走得到(真设备由 mon.is_detecting() 给)
  else if (line === 'R:AUTODETECT' && MOCK.detecting) {
    MOCK.detecting = false;
    resp = 'RET:AUTODETECT=BUSY';
  }
  else if (line === 'R:AUTODETECT') resp = 'RET:AUTODETECT=' + JSON.stringify(
    { baud: 9600, databits: 8, stopbits: 1, parity: 0 });
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
