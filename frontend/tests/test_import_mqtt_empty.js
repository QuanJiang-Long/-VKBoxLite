// test_import_mqtt_empty.js
//
// 2026-11-16: 修「未配 MQTT 的设备，导出 JSON 再导入会被拦下」。
//
// 现场症状:
//   设备没填 MQTT 服务器地址时, 导出的 JSON 里 mqtt.host 是空串。
//   再导入回去, 485 配置其实已经写进设备了, 界面却弹
//   "MQTT 服务器地址不能为空" —— 用户看到的是"导入失败"。
//
// 根因:
//   hasMqttData 用 m.host || m.port || m.user || ... 判定, port 缺省 1883
//   永远为真; importCfg 又用同样的或条件调 saveMqtt(), 被 host 非空校验拦下。
//
// 修法: 以 host 为准 —— 没有服务器地址就当作这份文件没有 MQTT 段,
//       表单不覆盖、也不写设备, 只给一句"已跳过"的提示。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const mqttJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'mqtt.js'), 'utf8');

// === 点 1: hasMqttData 只认 host ===
assertEq(/const hasMqttData = !!\(m\.host && String\(m\.host\)\.trim\(\)\)/.test(appJs), true,
  'applyParsedData: hasMqttData 以 host 为准');

// === 点 2: 旧的或条件判定已移除 ===
assertEq(/const hasMqttData = m\.host \|\| m\.port/.test(appJs), false,
  'applyParsedData: 旧的 host||port 判定已删除');

// === 点 3: importCfg 只在 host 非空时写 MQTT ===
assertEq(/const impMqttHost = data\.mqtt && data\.mqtt\.host \? String\(data\.mqtt\.host\)\.trim\(\) : ''/.test(appJs), true,
  'importCfg: 先从文件里取 host');
assertEq(/if \(importMqtt && impMqttHost\) \{\s*await saveMqtt\(\);/.test(appJs), true,
  'importCfg: host 非空才调 saveMqtt');
assertEq(/data\.mqtt\.host \|\| data\.mqtt\.port \|\| data\.mqtt\.user/.test(appJs), false,
  'importCfg: 旧的或条件调用已删除');

// === 点 4: 跳过时给明确提示, 不是报错 ===
assertEq(/该文件没有 MQTT 服务器地址，已跳过 MQTT 配置/.test(appJs), true,
  'importCfg: 跳过 MQTT 时有明确提示');

// === 点 5: saveMqtt 自己的 host 校验要保留(用户手动点保存仍应拦) ===
assertEq(/if \(!host\) \{ toast\('MQTT 服务器地址不能为空'\); return; \}/.test(mqttJs), true,
  'saveMqtt: host 非空校验保留');

console.log('PASS: 未配 MQTT 的配置往返导入不再误报 (5 个测试点通过)');
