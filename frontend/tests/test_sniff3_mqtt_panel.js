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

// 5. 状态卡片: 11 字段
const statusFields = [
  'snStConn', 'snStClientId', 'snStUser', 'snStSn', 'snStMode',
  'snStManual', 'snStPub', 'snStSub', 'snStPubTopics', 'snStSubscribed', 'snStKeepSession'
];
const allFields = statusFields.every(id => html.indexOf('id="' + id + '"') > 0);
assertEq(allFields, true,
  'sniff-3: 状态卡片 11 字段全有 (snStConn/ClientId/User/Sn/Mode/Manual/Pub/Sub/PubTopics/Subscribed/KeepSession)');

// 6. 字段 label 名称
const labels = [
  ['连接状态', 'snStConn'],
  ['ClientID', 'snStClientId'],
  ['用户名', 'snStUser'],
  ['设备编号', 'snStSn'],
  ['当前档次', 'snStMode'],
  ['手动配置', 'snStManual'],
  ['生效发布', 'snStPub'],
  ['生效订阅', 'snStSub'],
  ['其他生效 Topic', 'snStPubTopics'],
  ['已订阅', 'snStSubscribed'],
  ['会话管理', 'snStKeepSession']
];
const allLabels = labels.every(([label, id]) => {
  // 找 <tr><td>label</td><td id="id">...</td></tr> 这种模式
  const re = new RegExp('<td>' + label + '</td>\\s*<td[^>]*id="' + id + '"');
  return re.test(html);
});
assertEq(allLabels, true,
  'sniff-3: 状态卡片 11 字段 label 名称正确 (连接状态/ClientID/...)');

// 7. 卡片标题 "状态"
assertEq(/<div class="panel-title">状态</.test(html), true,
  'sniff-3: 状态卡片标题是 "状态"');

// 8. mqtt.js 加 renderSnStatus 函数
assertEq(/function\s+renderSnStatus\s*\(/.test(mqttJs), true,
  'sniff-3: mqtt.js 加 renderSnStatus() 函数 (把 R:MQTT stat/cfg 填到 snStXxx)');
// 8a. renderMqtt 末尾调用
const rMqtt = mqttJs.indexOf('function renderMqtt()');
const rEnd = mqttJs.indexOf('\n}', rMqtt + 50);
const rBody = mqttJs.substring(rMqtt, rEnd + 5);
assertEq(/renderSnStatus\(s,\s*c,\s*pubTopics\)/.test(rBody), true,
  'sniff-3: renderMqtt 末尾调 renderSnStatus(s, c, pubTopics)');

// 9. renderSnStatus 内部: 11 字段映射
const rsStart = mqttJs.indexOf('function renderSnStatus');
const rsEnd = mqttJs.indexOf('\n}', rsStart + 100);
const rsBody = mqttJs.substring(rsStart, rsEnd + 5);
const mappings = [
  ['snStConn', '已连接'],
  ['snStClientId', 'client_id'],
  ['snStUser', 'user'],
  ['snStSn', 'device_id'],
  ['snStMode', 'manual_on'],
  ['snStManual', 'manual_on'],
  ['snStPub', 'pubTopics'],
  ['snStSub', 'sub'],
  ['snStPubTopics', 'slice'],
  ['snStSubscribed', 'subscribed'],
  ['snStKeepSession', 'keep_session'],
];
const allMapped = mappings.every(([id, hint]) => rsBody.indexOf(id) > 0 && rsBody.indexOf(hint) > 0);
assertEq(allMapped, true,
  'sniff-3: renderSnStatus 把 stat/cfg 11 字段映射到 snStXxx');

console.log('PASS: sniff-3 sniff 面板 MQTT 卡片改造 (改名+删保存+弹窗改周期+状态卡片)');
