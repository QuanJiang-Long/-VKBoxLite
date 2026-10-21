// test_sniff3_mqtt_panel.js
//
// sniff-3 fix: sniff 页面 MQTT 卡片改造:
//   1. 标题 "MQTT 连接手动配置" -> "MQTT连接"
//   2. 删除 btnSnMqttSave 保存按钮 + snMqttHint
//   3. snMqHost/snMqPort/snMqInterval 改为 ro-val 只读 (绿字灰底)
//   4. snMqInterval 加 ro-clickable, 点击弹窗修改 (复用 askEditInterval + saveMqtt)
//   5. 新增"状态"卡片: 11 字段, 从 R:MQTT.stat 映射

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const mqttJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'mqtt.js'), 'utf8');

// 1. 标题 "MQTT连接" (无"手动配置"字样)
assertEq(/<div class="panel-title">MQTT连接\s*</.test(html), true,
  'sniff-3: 卡片标题改为 "MQTT连接"');
assertEq(/MQTT\s*连接手动配置/.test(html), false,
  'sniff-3: 旧标题 "MQTT 连接手动配置" 已删除');

// 2. 删 btnSnMqttSave + snMqttHint
assertEq(/id="btnSnMqttSave"/.test(html), false,
  'sniff-3: HTML 删了 btnSnMqttSave 按钮');
assertEq(/id="snMqttHint"/.test(html), false,
  'sniff-3: HTML 删了 snMqttHint 提示');
assertEq(/btnSnMqttSave/.test(appJs), false,
  'sniff-3: app.js 删了 btnSnMqttSave 引用');
assertEq(/snMqttHint/.test(appJs), false,
  'sniff-3: app.js 删了 snMqttHint 引用');

// 3. snMqHost/snMqPort/snMqInterval 加 ro-val (绿字灰底, 只读样式)
const snMqHost = html.match(/<input id="snMqHost"[^>]*>/);
const snMqPort = html.match(/<input id="snMqPort"[^>]*>/);
const snMqInterval = html.match(/<input id="snMqInterval"[^>]*>/);
assertEq(snMqHost && /readonly/.test(snMqHost[0]) && /ro-val/.test(snMqHost[0]), true,
  'sniff-3: snMqHost 加 readonly + ro-val (跟 platform 档 pMqHost 同套)');
assertEq(snMqPort && /readonly/.test(snMqPort[0]) && /ro-val/.test(snMqPort[0]), true,
  'sniff-3: snMqPort 加 readonly + ro-val');
assertEq(snMqInterval && /readonly/.test(snMqInterval[0]) && /ro-val/.test(snMqInterval[0]), true,
  'sniff-3: snMqInterval 加 readonly + ro-val');
assertEq(snMqInterval && /ro-clickable/.test(snMqInterval[0]), true,
  'sniff-3: snMqInterval 加 ro-clickable (允许点击弹窗修改)');

// 3a. 上报周期提示词跟 platform 档一致: "🔒 点击修改"
const intervalHint = html.match(/<span class="hint"[^>]*>[^<]*点击修改[^<]*<\/span>/g);
const hasSnIntervalHint = intervalHint && intervalHint.some(s => s.indexOf('snMqInterval') < 0 && s.indexOf('🔒') >= 0);
// 找 snMqInterval 后的 hint (在它附近)
const snI = html.indexOf('snMqInterval');
const snHint = html.substring(snI, snI + 400).match(/<span class="hint"[^>]*>[^<]+<\/span>/);
assertEq(snHint && /✏️\s*点击修改/.test(snHint[0]), true,
  'sniff-3 c: snMqInterval 提示词改为 "✏️ 点击修改" (笔图标, 跟 platform 档 pMqInterval 同套)');
// 3c. 旧锁图标 🔒 已删
assertEq(/🔒\s*点击修改/.test(html), false,
  'sniff-3 c: 旧锁图标 🔒 已删除, 改用笔 ✏️');
// 3d. 平台档也同步改了 (pMqInterval 后的提示词)
assertEq(html.match(/✏️\s*点击修改/g).length >= 2, true,
  'sniff-3 c: platform 档 pMqInterval + sniff 档 snMqInterval 都用 "✏️ 点击修改"');
// 3b. 旧提示词 "U2-m / U3 res / U4 prop 共享" 已删
assertEq(/U2-m\s*\/\s*U3 res\s*\/\s*U4 prop/.test(html), false,
  'sniff-3 b: 旧提示词 "U2-m / U3 res / U4 prop 共享" 已删除');

// 4. app.js 绑定 snMqInterval 点击 -> askEditInterval + saveMqtt
assertEq(/el\.snMqInterval\.addEventListener\(['"]click['"]/.test(appJs), true,
  'sniff-3: app.js 绑 snMqInterval click 事件');
assertEq(/askEditInterval\(cur\)/.test(appJs), true,
  'sniff-3: 点击 snMqInterval 弹 askEditInterval 弹窗 (复用 platform 档)');
assertEq(/el\.snMqInterval\.value\s*=\s*String\(v\)/.test(appJs), true,
  'sniff-3: 弹窗确认后更新 snMqInterval.value');
assertEq(/el\.mqInterval\.value\s*=\s*String\(v\)/.test(appJs), true,
  'sniff-3: 同步到 tabPoll 的 mqInterval (saveMqtt 走 E("", mqInterval) 读)');
assertEq(/await\s+saveMqtt\(\)/.test(appJs), true,
  'sniff-3: 弹窗确认后调 saveMqtt 走 W:MQTT');

// 5. 状态卡片: 10 字段, 字段名跟 manual 档 mMqStXxx 对齐 (DevId/Subed/ExtraTopics)
//    2026-10: 原来是 11 个 (多一个"手动配置"snStManual), 那行删了 ——
//    设备端切 sniff 会复位 manual_on(ctrl.lua), sniff 恒为自动档, 那行永远是"否"
const statusFields = [
  'snStConn', 'snStClientId', 'snStUser', 'snStDevId', 'snStMode',
  'snStPub', 'snStSub', 'snStExtraTopics', 'snStSubed', 'snStKeepSession'
];
const allFields = statusFields.every(id => html.indexOf('id="' + id + '"') > 0);
assertEq(allFields, true,
  'sniff-3: 状态卡片 10 字段全有 (snStConn/ClientId/User/DevId/Mode/Pub/Sub/ExtraTopics/Subed/KeepSession)');
// 5b. "手动配置"字段已删 (2026-10)
assertEq(html.indexOf('id="snStManual"') < 0, true,
  'sniff-3: 状态卡片已删"手动配置"字段 (sniff 恒自动档)');
// 5a. 旧字段名 (snStSn/snStPubTopics/snStSubscribed) 都不应再出现
const oldIds = ['snStSn', 'snStPubTopics', 'snStSubscribed'];
const noOld = oldIds.every(id => html.indexOf('id="' + id + '"') < 0);
assertEq(noOld, true,
  'sniff-3: 旧字段名 (snStSn/snStPubTopics/snStSubscribed) 已重命名');

// 6. 显示格式: kv-grid 容器 + kv 单元 + pre 容器 (跟 manual 档 mMqStXxx 同套)
assertEq(/<div class="kv-grid">[\s\S]*snStConn[\s\S]*<\/div>\s*<\/div>/.test(html), true,
  'sniff-3: 状态卡片用 kv-grid 容器 (跟 manual 档 mMqStXxx 同套)');
assertEq(/<div class="kv"><b>连接状态<\/b><span id="snStConn">/.test(html), true,
  'sniff-3: 字段用 <div class="kv"><b>label</b><span id=...> 格式 (跟 manual 一致)');
assertEq(/<div class="kv kv-wide"><b>其他生效 Topic<\/b><pre id="snStExtraTopics" class="kv-pre">/.test(html), true,
  'sniff-3: 其他生效 Topic 用 kv-wide + pre (跟 manual 档 mMqStExtraTopics 同套)');

// 7. 字段 label 名称 (10 个)
const labels = [
  ['连接状态', 'snStConn'],
  ['ClientID', 'snStClientId'],
  ['用户名', 'snStUser'],
  ['设备编号', 'snStDevId'],
  ['当前档次', 'snStMode'],
  ['生效发布', 'snStPub'],
  ['生效订阅', 'snStSub'],
  ['其他生效 Topic', 'snStExtraTopics'],
  ['已订阅', 'snStSubed'],
  ['会话管理', 'snStKeepSession']
];
const allLabels = labels.every(([label, id]) => {
  // 找 <div class="kv"><b>label</b><span id="id">...</span></div> 这种模式
  // 其他生效 Topic 用 pre 而不是 span
  if (id === 'snStExtraTopics') {
    return new RegExp('<div class="kv kv-wide"><b>' + label + '<\\/b><pre id="' + id + '" class="kv-pre">').test(html);
  }
  return new RegExp('<div class="kv"><b>' + label + '<\\/b><span id="' + id + '">').test(html);
});
assertEq(allLabels, true,
  'sniff-3: 状态卡片 11 字段 label 名称正确 (连接状态/ClientID/...)');

// 8. 卡片标题 "状态"
assertEq(/<div class="panel-title">状态\s*</.test(html), true,
  'sniff-3: 状态卡片标题是 "状态"');

// 9. app.js el 引用: 新字段名, 旧字段名不引用
const oldRefs = ['snStSn:', 'snStPubTopics:', 'snStSubscribed:'];
const noOldRefs = oldRefs.every(r => appJs.indexOf(r) < 0);
assertEq(noOldRefs, true,
  'sniff-3: app.js el 引用改成 snStDevId/snStExtraTopics/snStSubed, 旧名不引用');
const newRefs = ['snStDevId:', 'snStExtraTopics:', 'snStSubed:'];
const hasNewRefs = newRefs.every(r => appJs.indexOf(r) > 0);
assertEq(hasNewRefs, true,
  'sniff-3: app.js el 引用含新名 (snStDevId/snStExtraTopics/snStSubed)');

// 10. mqtt.js 加 renderSnStatus 函数
assertEq(/function\s+renderSnStatus\s*\(/.test(mqttJs), true,
  'sniff-3: mqtt.js 加 renderSnStatus() 函数 (把 R:MQTT stat/cfg 填到 snStXxx)');
// 10a. renderMqtt 状态部分调用 (2026-10: renderMqtt 拆成 renderMqttForm +
//     renderMqttStatus 两半, renderSnStatus 现在在状态半边里)
const rMqtt = mqttJs.indexOf('function renderMqtt()');
let rEnd = -1;
for (let off = rMqtt + 50; off < mqttJs.length; off++) {
  if (mqttJs[off] === '\n' && /^function\s/.test(mqttJs.substring(off + 1, off + 20))) {
    rEnd = off; break;
  }
}
const rBody = mqttJs.substring(rMqtt, rEnd > 0 ? rEnd : rMqtt + 2000);
assertEq(/renderSnStatus\(s,\s*c,\s*pubTopics\)/.test(mqttJs), true,
  'sniff-3: renderMqtt 末尾调 renderSnStatus(s, c, pubTopics)');

// 11. renderSnStatus 内部: 11 字段映射 (新字段名)
const rsStart = mqttJs.indexOf('function renderSnStatus');
let rsEnd = -1;
for (let off = rsStart + 100; off < mqttJs.length; off++) {
  if (mqttJs[off] === '\n' && /^function\s/.test(mqttJs.substring(off + 1, off + 20))) {
    rsEnd = off; break;
  }
}
const rsBody = mqttJs.substring(rsStart, rsEnd > 0 ? rsEnd : rsStart + 2000);
const mappings = [
  ['snStConn', '已连接'],
  ['snStClientId', 'client_id'],
  ['snStUser', 'user'],
  ['snStDevId', 'device_id'],
  ['snStMode', 'manual_on'],
  ['snStPub', 'pubTopics'],
  ['snStSub', 'sub'],
  ['snStExtraTopics', 'platformExtraTopics'],
  ['snStSubed', 'subscribed'],
  ['snStKeepSession', 'keep_session'],
];
const allMapped = mappings.every(([id, hint]) => rsBody.indexOf(id) > 0 && rsBody.indexOf(hint) > 0);
assertEq(allMapped, true,
  'sniff-3: renderSnStatus 把 stat/cfg 10 字段映射到 snStXxx (新字段名)');
// 11a. 旧字段名不再用
const rsOldRefs = ['snStSn', 'snStPubTopics', 'snStSubscribed'];
const rsNoOld = rsOldRefs.every(id => rsBody.indexOf("'" + id + "'") < 0);
assertEq(rsNoOld, true,
  'sniff-3: renderSnStatus 不再用旧字段名 snStSn/snStPubTopics/snStSubscribed');

console.log('PASS: sniff-3 sniff 面板 MQTT 卡片改造 (改名+删保存+弹窗改周期+状态卡片格式与 manual 一致)');
