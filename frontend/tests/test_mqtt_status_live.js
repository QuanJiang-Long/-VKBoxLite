// test_mqtt_status_live.js
//
// 2026-10: 状态卡(连接状态/已订阅/生效 topic)要跟着设备实时状态走。
//   起因: 切 sniff 档时 MQTT 会断开重连, 那一刻读到的 connected=false;
//   而状态卡只在 readMqtt(读全量)时才重画 → 重连成功后卡片一直显示
//   "连接中/已断开", 用户切走再切回来才刷新(实测报出)。
//   修法: renderMqtt 拆成 renderMqttForm(写输入框) + renderMqttStatus(只画状态卡),
//   5s 定时器的 R:STAT 本来就带 mqtt 段, 并进 S.mqtt.stat 后重画状态卡即可,
//   不额外发指令, 也不碰用户正在编辑的表单。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const mqttJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'mqtt.js'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. renderMqtt 拆成两半
assertEq(/function renderMqttForm\(\)/.test(mqttJs), true, 'mqtt: 有 renderMqttForm (写输入框)');
assertEq(/function renderMqttStatus\(\)/.test(mqttJs), true, 'mqtt: 有 renderMqttStatus (只画状态卡)');
assertEq(/function renderMqtt\(\)\s*\{\s*renderMqttForm\(\);\s*renderMqttStatus\(\);/.test(mqttJs.replace(/\r\n/g, '\n')), true,
  'mqtt: renderMqtt = Form + Status');

// 2. 状态部分不写输入框 (不能出现 .value = )
const st = mqttJs.substring(mqttJs.indexOf('function renderMqttStatus()'),
  mqttJs.indexOf('function renderMqttStatus()') + 3000);
assertEq(!/\.value\s*=/.test(st), true, 'mqtt: renderMqttStatus 不写任何输入框');

// 3. 5s 定时器的 readHome 里调用 renderMqttStatus (R:STAT 已带 mqtt 段)
assertEq(/renderMqttStatus\(\)/.test(appJs), true, 'app: readHome 会调 renderMqttStatus 重画状态卡');

// 3b. 定时器不能在串口忙时整轮跳过 (2026-10 用户实测: 识别期间前端每秒轮询
//     R:AUTODETECT, 串口几乎一直忙, 跳过就意味着状态卡永远不重画)
const timer = appJs.substring(appJs.indexOf('homeTimer = setInterval'),
  appJs.indexOf('homeTimer = setInterval') + 900);
assertEq(/while \(S\.pending && Date\.now\(\) - t0 < 3000\)/.test(timer), true,
  'app: 定时器等串口空闲(最多3s)而不是整轮跳过');
assertEq(!/if \(S\.pending\) return;/.test(timer), true,
  'app: 定时器不再"忙就整轮跳过"');

// 4. 状态卡的"当前档次"优先用 stat 段的 manual_on (R:STAT 5s 就更新, cfg 的慢)
assertEq(/const manualOn = \(s\.manual_on !== undefined\)/.test(mqttJs), true,
  'mqtt: 当前档次优先取 stat.manual_on (实时), cfg 兜底');

console.log('PASS: mqtt 状态卡跟随设备实时状态 (R:STAT 5s 刷新, 不碰表单) — 4 个测试点通过');
