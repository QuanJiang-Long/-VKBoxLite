//=====================================================================
// mqtt.js - MQTT 配置 / 报告 / 重连 / dirty 处理
//
// 从 app.js 拆出 (2g-1 refactor, 物理拆分不改逻辑)
// 依赖: 全局 S (state), el (Proxy), E(), sendCmd(), Protocol, fillOk(),
//       setKvPre(), status(), toast(), guardUnsaved(), renderHome(),
//       syncPullCfgBtn(), mqttPrefix() 在本文件内
//=====================================================================

// 取当前档位对应的 prefix: 'm' (manual) / 'p' (platform) / '' (idle/sniff/未知)
function mqttPrefix() {
  if (isManual(S.mode)) return 'm';
  if (isPlatform(S.mode)) return 'p';
  return '';
}

//---------------------------------------------------------------------
function mqSnap() {
  const g = e => (e ? e.value : '');
  const c = e => (e ? e.checked : false);
  const pre = mqttPrefix();
  const E_ = id => E(pre, id);
  return JSON.stringify({
    host: g(E_('mqHost')), port: g(E_('mqPort')), ssl: c(E_('mqSsl')),
    user: g(E_('mqUser')), pass: g(E_('mqPass')), cid: g(E_('mqClientId')),
    pub: g(E_('mqPub')), sub: g(E_('mqSub')),
    iv: g(E_('mqInterval')), snIv: g(el.snMqInterval),
    keep: g(E_('mqKeepSession')),
    hHost: g(el.hMqHost), hPort: g(el.hMqPort), hPass: g(el.hMqPass),
    hCid: g(el.hMqClientId)
  });
}

function snapMqClean() { S.mqSnap = mqSnap(); refreshMqDirty(); }

// 打开手动档时把手动档那几项从设备当前值回填出来。
// 单独抽出来是因为调用点有两个（setManualMode 的 refill 分支、readMqtt 的
// 档位切换分支），且都发生在 R:MQTT 应答刚落地之后 —— 此时 S.mqtt.cfg 里
// 是设备实际存的那份，回填它等于"把你上次填的还给你"
function refillManual() {
  const c = (S.mqtt && S.mqtt.cfg) || {};
  // Step 2e: refillManual 是 setManualMode 调, 手动档专属, 写 m- 前缀元素
  const pre = 'm';
  if (fillOk(E(pre, 'mqUser'))) E(pre, 'mqUser').value = c.user || '';
  if (fillOk(E(pre, 'mqPass'))) E(pre, 'mqPass').value = c.pass || '';
  if (fillOk(E(pre, 'mqClientId'))) E(pre, 'mqClientId').value = c.client_id || '';
  if (fillOk(E(pre, 'mqPub'))) E(pre, 'mqPub').value = c.pub_topic || '';
  if (fillOk(E(pre, 'mqSub'))) E(pre, 'mqSub').value = c.sub_topic || '';
}

//---------------------------------------------------------------------
// 手动/自动切换 = 建连档位切换
//   自动（默认）：用户名/密码/ClientID/发布Topic/订阅Topic 全部归设备管 ——
//              用户名固定 SN、密码用首页那份 MQTT凭证密码、topic 用默认
//              模板。这几项整行藏掉（.manual-only），但「保存」按钮两档都
//              在：自动档还有地址/端口/SSL/周期/会话 可改。
//   手动：      那几项显示出来，保存时连用户名/密码/topic 一起下发，设备
//              先清掉自动拼的那套再写这套，然后按这套建连上报。
// 注意：开手动档是保存时才生效（用户填完再点「保存」）；
// 关手动档是当场生效 —— 屏幕上那几个手动档的值会被自动档顶掉，
// 所以关档必须自己把指令发下去（见下面 btnManualCfg.onclick）
//---------------------------------------------------------------------
function setManualMode(on, opts) {
  opts = opts || {};
  S.mqManual = !!on;
  // R2: 手动档专属的行 + 「保存」按钮随档位整行显隐。用 body 上的 class
  // 驱动（CSS 里 body:not(.mq-manual) .manual-only），比逐个写
  // style.display 干净：.form-row 的 flex 不会被内联样式盖掉
  document.body.classList.toggle('mq-manual', S.mqManual);
  // Step 2i: 删 btnManualCfg (冗余), 不再有"开/关手动配置"按钮, 档位切**换**走**保**存**时**一**起**做
  syncPullCfgBtn();
  // 关档时把手动档那几项整行藏掉。留着已填的值不清 —— R:MQTT 回来会按
  // manual_on 重填，期间留着只是看不见，不会误发
  if (S.mqManual && opts.refill) refillManual();
  // 换内容等于换了一遍表单，必须重新取基线，否则会误报"有未保存更改"
  if (opts.snap !== false) snapMqClean();
}

function refreshMqDirty() {
  const d = S.mqSnap !== null && mqSnap() !== S.mqSnap;
  if (d === S.mqDirty) return;
  S.mqDirty = d;
  // MQTT 页和首页各有一个保存按钮，两边都要显示未保存标记
  // Step 2n: manual tab 的 mBtnMqttSave 也加上, 之前只切了 tabPoll 的
  // (Step 2a 拆 tab 时漏了, 跟 2m 的 btn 绑定漏是同根问题)
  el.btnMqttSave.textContent = d ? '保存 *' : '保存';
  el.btnMqttSave.classList.toggle('dirty', d);
  if (el.mBtnMqttSave) {
    el.mBtnMqttSave.textContent = d ? '保存 *' : '保存';
    el.mBtnMqttSave.classList.toggle('dirty', d);
  }
  if (el.btnHomeMqttSave) {
    el.btnHomeMqttSave.textContent = d ? '保存并重连 *' : '保存并重连';
    el.btnHomeMqttSave.classList.toggle('dirty', d);
  }
  if (d) status('有未保存的 MQTT 更改，点「保存」生效', false);
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
      // 用户在那边改的上报周期/会话管理只能靠首页这下保存带走。
      // 不带的话表单值会被 c(设备现值)覆盖, 用户等于白改
      ssl: el.mqSsl.checked,
      interval_s: parseInt(el.mqInterval.value, 10) || 0,
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

//=====================================================================
// MQTT 配置
//=====================================================================
function renderMqtt() {
  const r = S.mqtt || {};
  const c = r.cfg || {};
  // Step 2b: 取当前档位 prefix (m-/p-/), 业务用 E() 写对应 tab 内元素
  const pre = mqttPrefix();
  if (c.host !== undefined) {
    // 正在输入的框不能抢：readMqtt 会在点"MQTT配置"子标签/刷新时触发，
    // 应答落地时把用户打到一半的字冲掉，表现为"输入框改不动"。
    if (fillOk(E(pre, 'mqHost'))) E(pre, 'mqHost').value = c.host || '';
    if (fillOk(E(pre, 'mqPort'))) E(pre, 'mqPort').value = c.port != null ? c.port : 1883;
    const sslEl = E(pre, 'mqSsl'); if (sslEl) sslEl.checked = !!c.ssl;
    if (fillOk(E(pre, 'mqUser'))) E(pre, 'mqUser').value = c.user || '';
    if (fillOk(E(pre, 'mqPass'))) E(pre, 'mqPass').value = c.pass || '';
    if (fillOk(E(pre, 'mqClientId'))) E(pre, 'mqClientId').value = c.client_id || '';
    // Step 2k: pub_topic/sub_topic 留空 = 设备不订不发表头 (M.default 已删默认路径)
    // 设备端 publish()/build_subs() 对空串各自有守卫, 这里直接照填 c.pub_topic
    if (fillOk(E(pre, 'mqPub'))) E(pre, 'mqPub').value = c.pub_topic || '';
    if (fillOk(E(pre, 'mqSub'))) E(pre, 'mqSub').value = c.sub_topic || '';
    // user/client_id 留空是故意的: 设备兜底填 SN (user→SN, client_id→SN_)
    // sniff 页面简版: 同步 broker 地址/端口 (只读) + 周期 (可编辑)
    // snMqHost/Port/Interval 是 sniff 页面独立元素, 跟 m/p 无关
    // ⚠️ 不能走 fillOk: 它有"所在 tab-pane 不可见就不填"的回显守卫, 而切入
    //   sniff 档时的自动刷新 (readMqtt) 常在 sniff 面板还没显示时落地 ——
    //   结果表现为"进 sniff 有时刷新有时没刷" (2026-10 实测定性)。这三栏
    //   是只读回显, 不可编辑, 只防"焦点正在上面时被冲字"即可
    if (document.activeElement !== el.snMqHost) el.snMqHost.value = c.host || '';
    if (document.activeElement !== el.snMqPort) el.snMqPort.value = c.port != null ? c.port : 1883;
    if (document.activeElement !== el.snMqInterval) el.snMqInterval.value = c.interval_s != null ? c.interval_s : 120;
    // topic 留空也是故意的: Step 2k 起不再有默认路径, 设备不订不发
    // 显示空属正常。实际生效值看下面的连接状态面板。
    if (fillOk(E(pre, 'mqInterval'))) E(pre, 'mqInterval').value = c.interval_s != null ? c.interval_s : 120;
    // QoS 已从界面移除：设备端发布/订阅固定用 QoS 1，
    // 这里不再显示也不再下发（设备 normalize 会退回默认值 1）。
    // 18-fix: 删除 no_SN 建连 字段后, 也不再有 allow_no_sn 下发
    // MQTT 会话管理（select）：'1'=持久会话  '0'=离线自动销毁（默认）
    const keepEl = E(pre, 'mqKeepSession'); if (keepEl) keepEl.value = c.keep_session ? '1' : '0';
  }
  // sniff 页面简版: 同步 broker 地址/端口 (只读) + 周期 (可编辑)
  // snMqHost/Port/Interval 是 sniff 页面独立元素, 跟 m/p 无关
  // ⚠️ 不能走 fillOk: 它有"所在 tab-pane 不可见就不填"的回显守卫, 而切入
  //   sniff 档时的自动刷新 (readMqtt) 常在 sniff 面板还没显示时落地 ——
  //   结果表现为"进 sniff 有时刷新有时没刷" (2026-10 实测定性)。这三栏
  //   是只读回显, 不可编辑, 只防"焦点正在上面时被冲字"即可
  // ⚠️ 放在 c.host !== undefined 守卫【外面】: 守卫不成立(设备回的 cfg 没
  //   host 字段)时若跟着跳过, 面板就一直空着, 看着像"没刷新"
  if (document.activeElement !== el.snMqHost) el.snMqHost.value = c.host || '';
  if (document.activeElement !== el.snMqPort) el.snMqPort.value = c.port != null ? c.port : 1883;
  if (document.activeElement !== el.snMqInterval) el.snMqInterval.value = c.interval_s != null ? c.interval_s : 120;
  const s = r.stat || {};
  // Step 2b: 17 字段状态写 m/p 各自 tab
  setKvPre(pre, 'mqStConn', s.connected ? '已连接' : (s.want_run ? '连接中/已断开' : '未启动'), !s.connected);
  setKvPre(pre, 'mqStClientId', s.client_id || s.device_id || s.sn || '');
  setKvPre(pre, 'mqStUser', s.user || s.device_id || s.sn || '');
  setKvPre(pre, 'mqStDevId', s.device_id || s.sn || '');
  // 生效发布/生效订阅：当前档次实际在用的两条 topic 成品（{SN} 已代入）。
  // 手动档 = 本页填的模板代出来的；自动档 = PLATFORM_* 固定常量。
  // 只在连上后有值（未建连时 S.pub/S.sub 是 nil，profile 兜底算的那份要用
  // 设备号，没有 SN 时也是空）
  //
  // 32-fix: 优先用 s.pub_topics (设备返回的实际发送 topic 列表, 平台档带
  //   -{n} 后缀). 老设备没这个字段时回退到 s.pub (向后兼容).
  // 设备只告诉前端 "我发这些", 前端不构造
  // 没配 topic 时设备回的是 [""] (空串), 过滤掉; 两栏口径统一:
  //   有效值就显示值, 没有值一律 '--' (红)。原来发布栏显示 '--'、订阅栏显示
  //   "未连接", 同一件事两种说法(2026-10 用户报出)。"未连接"字面上又跟
  //   上面那行"连接状态"撞车, 干脆统一用 '--'
  const pubTopics = ((s.pub_topics && s.pub_topics.length)
    ? s.pub_topics
    : (s.pub ? [s.pub] : [])).filter(Boolean);
  const pubText = pubTopics.length ? pubTopics.join('\n') : '--';
  const subText = s.sub || '--';
  setKvPre(pre, 'mqStPub', pubText, !pubTopics.length);
  setKvPre(pre, 'mqStSub', subText, !s.sub);
  // 22-fix: 手动档额外生效的 topic (U1 hello + U2 meta).
  // 24-fix: 平台档也加 (U1/U2/U3/U5/U6/U7 + D2/D2n/D3/D4, 共 10 条;
  //         D2 服务调用已改 service/invoke, D2n 是子设备级 {sn}-N).
  //   走 topics.js 的 VKBoxTopics.manualExtraTopics / platformExtraTopics 拼.
  //   sniff tab 的 2 条 D2/D2n 由 renderSnStatus 拼到 snStExtraTopics (见那头).
  //   用 id 后缀 'ExtraTopics' 区分 manual tab
  //   的 mMqStExtraTopics (m- 前缀) vs platform 的 pMqStExtraTopics.
  //   注: setKvPre 会把 className 整个重置, 会冲掉 <pre> 的 .kv-pre 样式,
  //   所以这里直接拿 el 操作, 保留 .kv-pre class.
  if (window.VKBoxTopics) {
    const did = s.device_id || s.sn || '';
    const isManualTab = pre === 'm';
    const isPlatformTab = pre === 'p';
    let extras = [];
    let placeholder = '（无额外生效 topic）';
    if (isManualTab) {
      extras = VKBoxTopics.manualExtraTopics(did);
      placeholder = '（手动档无额外生效 topic）';
    } else if (isPlatformTab) {
      // s.sub_list = 设备回报的真实订阅清单 → D2n 那条显示真值(…-1)
      extras = VKBoxTopics.platformExtraTopics(did, s.sub_list);
      placeholder = '（平台档无额外生效 topic）';
    }
    const txt = extras.length ? VKBoxTopics.formatListAsLines(extras) : placeholder;
    const fullId = pre ? (pre + 'mqStExtraTopics'[0].toUpperCase() + 'mqStExtraTopics'.slice(1)) : 'mqStExtraTopics';
    const n = document.getElementById(fullId);
    if (n) {
      n.textContent = txt;
      n.classList.toggle('bad', !extras.length);
    }
  }
  // 当前档次: 手动 = 用本页填的凭证；自动 = 首页那份凭证 + SN
  setKvPre(pre, 'mqStMode', c.manual_on ? '手动配置' : '自动（设备拼接）', !!c.manual_on);
  setKvPre(pre, 'mqStSubed', s.subscribed ? '是' : '否', !s.subscribed);
  // Step 2i: 17 字段 → 9 字段, 删 8 个 setKvPre (面板也对应删了):
  //  - mqStSubs 订阅Topic / mqStReplied 配置回执 / mqStPubed 已上报条数
  //  - mqStFailed 失败次数 / mqStLast 最近上报 / mqStBackoff 重连退避
  //  - mqStErr 最近错误 (走 status 底**部**条**) / mqStSn SN 状**态** (设**备**编**号**就**是** SN)
  // 保留: mqStConn / mqStClientId / mqStUser / mqStDevId / mqStMode /
  //        mqStPub / mqStSub / mqStSubed / mqStKeepSession
  setKvPre(pre, 'mqStKeepSession',
        s.keep_session == null ? '--' : (s.keep_session ? '持久会话' : '离线自动销毁'));
  renderHome();
  // sniff-3 fix: 把同样的 stat 数据同步填到 sniff 面板的"状态"卡片
  //   snStXxx 元素是 sniff tab 独立, 跟 m/p prefix 无关, 这里直接用 el
  renderSnStatus(s, c, pubTopics);
  // 只在第一次渲染时套一次模式：只读属性/颜色/回显来源都要跟 S.mqManual 走。
  // 后面每次 readMqtt 都重套会覆盖用户在本次会话里点的「手动配置」
  if (S._mqModeInit !== true) {
    S._mqModeInit = true;
    setManualMode(S.mqManual);
  }
}

// sniff-3 fix: 把 R:MQTT 的 stat/cfg 数据填到 sniff 面板的"状态"卡片 (snStXxx)
//   在 renderMqtt 末尾被调用, 跟 m/p 状态卡片共享 stat 字段, 但展示形式不同:
//     - 11 字段, 没有手动/自动档区别 (sniff 模式只看设备实际生效值)
//     - 生效发布 = pubTopics[0] (主 topic);  其他生效 Topic = 平台档同款
//       10 条 code 标签列表 (U1..D4, 见 platformExtraTopics)
//   设备没 pub_topics 字段时 (老设备), 回退到 s.pub 单条填 snStPub, snStExtraTopics='--'
//   显示格式跟 manual 档的 mMqStXxx 一致 (kv-grid + kv + pre), 字段名也对齐
//   (snStDevId / snStSubed / snStExtraTopics)
function renderSnStatus(s, c, pubTopics) {
  if (!el.snStConn) return;
  // 连接状态: 跟 m/p 卡片同套 (connected → '已连接'; want_run → '连接中/已断开'; else '未启动')
  setKv('snStConn', s.connected ? '已连接' : (s.want_run ? '连接中/已断开' : '未启动'), !s.connected);
  setKv('snStClientId', s.client_id || s.device_id || s.sn || '--');
  setKv('snStUser', s.user || s.device_id || s.sn || '--');
  setKv('snStDevId', s.device_id || s.sn || '--');
  // 当前档次: 跟 m/p 卡片同步, 但 sniff 模式下都是设备实际生效值
  //   c.manual_on=true 表示手动档在跑 (本页填的凭证/topic), false=自动档 (首页 MQTT + SN 拼)
  setKv('snStMode', c.manual_on ? '手动配置' : '自动（设备拼接）', !!c.manual_on);
  // 2026-10: "手动配置"字段已从 sniff 状态卡删掉 (设备端切 sniff 会复位
  //   manual_on → sniff 恒为自动档, 那行永远是"否")
  // 生效发布: pubTopics[0] (主 topic); 没配/没连一律 '--' (与 m/p 档同口径)
  const pubValid = (pubTopics || []).filter(Boolean);
  if (pubValid.length) {
    setKv('snStPub', pubValid[0], false);
    // 其他生效 Topic: 与平台档 (p 档) pMqStExtraTopics 完全一致 —— 10 条
    //   U1/U2/U3/U5/U6/U7 + D2/D2n/D3/D4 code 标签列表。
    //   （原 pubTopics[1..] 多余从机上报位并入去: 主 -1 已在"生效发布"行,
    //     单从机时本为空; 现场按 p 档同一版式核对订阅关系）
    //   s.sub_list = 设备回报的真实订阅清单 → D2n 那条显示真值(…-1),
    //   不再显示模板(…-N); 老固件没这个字段就退回模板
    const did = s.device_id || s.sn || '';
    const extras = (window.VKBoxTopics && did)
      ? VKBoxTopics.formatListAsLines(VKBoxTopics.platformExtraTopics(did, s.sub_list))
      : '';
    // 不能走 setKv: 它会把 className 整个重置, 冲掉 <pre> 的 .kv-pre
    // 绿色样式 (m/p 档 mMqSt/pMqStExtraTopics 同款坑, 直接拿 el 操作)
    if (el.snStExtraTopics) {
      el.snStExtraTopics.textContent = extras || '--';
      el.snStExtraTopics.className = extras ? 'kv-pre' : 'kv-pre bad';
    }
  } else {
    setKv('snStPub', '--', true);
    setKv('snStExtraTopics', '--', true);
  }
  // 生效订阅: 与"生效发布"同一口径 (没值就 '--', 不用"未连接" ——
  // 那字面跟上面"连接状态"栏撞车, 而且两栏说法不一致看着别扭)
  setKv('snStSub', s.sub || '--', !s.sub);
  setKv('snStSubed', s.subscribed ? '是' : '否', !s.subscribed);
  setKv('snStKeepSession',
        s.keep_session == null ? '--' : (s.keep_session ? '持久会话' : '离线自动销毁'));
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
    // 串口单未决(上一条指令还没回)时 sendCmd 直接失败 → sniff 面板的
    // "MQTT 服务器地址/端口"就一直是空的(2026-10 实测"有时刷新有时没刷")。
    // 撞上的那条指令通常几百毫秒内就回, 等一下重试一次
    if (/尚未返回/.test(e.message || '')) {
      await new Promise(r => setTimeout(r, 400));
      try {
        const r2 = await sendCmd(Protocol.Enc.mqtt(), 'MQTT');
        S.mqtt = r2.data;
        renderMqtt();
        snapMqClean();
        return;
      } catch (e2) { /* 仍失败就落到下面的提示 */ }
    }
    // Step 2i fix: 之前 setKvPre(mqttPrefix(), 'mqStErr', ...), 但 mqStErr
    // 字段已从面板删除, 改成走 status 底部条 (用户看得到, 又不依赖字段)
    status('读取 MQTT 状态失败：' + e.message, false);
  }
}

async function saveMqtt() {
  // Step 2b: 用 E(pre) 读当前 tab 的 input, 不再固定 el.mqXxx
  const pre = mqttPrefix();
  const host = E(pre, 'mqHost').value.trim();
  if (!host) { toast('MQTT 服务器地址不能为空'); return; }
  const cfg = {
    host: host,
    port: parseInt(E(pre, 'mqPort').value, 10) || 1883,
    ssl: E(pre, 'mqSsl').checked,
    user: E(pre, 'mqUser').value.trim(),
    pass: E(pre, 'mqPass').value,
    client_id: E(pre, 'mqClientId').value.trim(),
    // 手动档专属。自动档下这两个键省掉不发。
    // Step 2k: 留空 = 设备不订不发 (M.default 已删默认路径)
    pub_topic: S.mqManual ? E(pre, 'mqPub').value.trim() : undefined,
    sub_topic: S.mqManual ? E(pre, 'mqSub').value.trim() : undefined,
    interval_s: parseInt(E(pre, 'mqInterval').value, 10) || 0,
    // QoS 界面已移除，不再下发；设备端固定用 QoS 1
    // select: '1'=持久会话  '0'=离线自动销毁（默认）
    keep_session: E(pre, 'mqKeepSession').value === '1',
    // 当前档次。false 时设备端清空手动凭证和手动 topic，改回 SN 用户名
    // + 首页那份 MQTT凭证密码 (topic 由 PLATFORM_* 固定常量接管, 跟手动模板无关)
    manual_on: S.mqManual
  };
  // {SN} 占位符必须有 SN 才代得出来。填了 {SN} 但设备没烧号 = 保存一个
  // 永远代不出成品 topic 的模板，连上了也发不出去，不如当场拦住
  if (S.mqManual) {
    const d = S.mqtt && S.mqtt.stat && (S.mqtt.stat.device_id || S.mqtt.stat.sn);
    for (const [k, v] of [['pub_topic', cfg.pub_topic], ['sub_topic', cfg.sub_topic]]) {
      if (v && v.indexOf('{SN}') >= 0 && !d) {
        toast(`「${k}」含 {SN} 占位符，但设备未烧号，请先烧号或改用完整 topic`);
        return;
      }
    }
  }
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
// 4-fix: 加上 mMqPass (manual) 和 mBtnMqttPassEye (manual 的眼睛按钮).
//   原代码只切 mqPass + hMqPass + btnMqttPassEye + btnHomeMqttPassEye,
//   manual tab 的 mMqPass 密码框 + 眼睛按钮漏了 (Step 2a 拆 tab 时漏,
//   跟 2m/2n/2o/2p/2q 同根). 烧测时发现, 计划.md "小问题清单" 记的.
function togglePassEye() {
  const show = el.mqPass.type === 'password';
  [el.mqPass, el.mMqPass, el.hMqPass].forEach(inp => {
    if (!inp) return;
    inp.type = show ? 'text' : 'password';
  });
  [el.btnMqttPassEye, el.mBtnMqttPassEye, el.btnHomeMqttPassEye].forEach(btn => {
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
