//=====================================================================
// cfg.js - 485 配置 / 读实时值 / dirty 处理
//
// 从 app.js 拆出 (2g-2 refactor, 物理拆分不改逻辑)
// 依赖: 全局 S (state), el (Proxy), E(), sendCmd(), Protocol, fillOk(),
//       radioVal(), setRadio(), status(), toast(), guardUnsaved(),
//       askConfirm(), fmtTs(), toArr(), cfgPrefix() 在本文件内
//=====================================================================

// Step 2e: cfgPrefix() 跟 mqttPrefix 同逻辑, 485 段 + 寄存器表 (selBaud/
// inpRound/inpSlave/inpTimeout/paramTbody 等) 走 m/p 拆分
function cfgPrefix() {
  if (isManual(S.mode)) return 'm';
  if (isPlatform(S.mode)) return 'p';
  return '';
}

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
    // 27-fix: 之前 src='default' 时早 return, 不读 REG, 导致设备配置为空时
    //   切 manual tab / s1 sub-tab 看到的还是上次的缓存点表, 必须手动
    //   点「读取配置」才会刷新. 改成和 readCfg 行为对齐: 继续读 REG,
    //   静默路径不再早 return, 但仍不弹 toast (避免自动路径刷屏)
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
    // src hint 还是要根据 src 渲染, 但不再据此 early return
    renderCfgSrcHint(S.cfgSrc || 'pull');
    const rr = await sendCmd(Protocol.Enc.reg(), 'REG', 3000);
    // 设备端 regs 为空时回 {} (Lua 空表编码成对象而非数组),
    // 不能只判 Array.isArray, 否则空配置时 renderRegTable 不会被调用,
    // 参数表停留在上一次的内容/占位行上
    const d = rr.data;
    if (Array.isArray(d) || (d && typeof d === 'object')) {
      S.regs = toArr(d);
      renderRegTable(pre);
    }
    snapClean(pre);
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
      timeout_ms: timeout === '' ? null : parseInt(timeout, 10),
      // im-2: 加 server 字段 (配置服务器url, 来自首页 fUrl 只读显示)
      //   让 JSON/CSV 导出能带出来, 跟导入时 applyParsedData 的 c.server 对齐
      server: el.fUrl.value.trim()
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
