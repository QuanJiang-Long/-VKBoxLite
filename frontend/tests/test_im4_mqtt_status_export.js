// test_im4_mqtt_status_export.js
//
// im-4: exportCfgAsJson 加 mqtt_status 段
//   1. data 含 mqtt_status 字段
//   2. mqtt_status 值 = S.mqtt.stat (R:STAT mqtt 段, 设备运行态快照)
//   3. 字段: connected / want_run / subscribed / client_id / user /
//            device_id / sn / sub / pub_topics / keep_session
//   4. S.mqtt 不存在时 (没拉到) 返 null
//   5. CSV 不加 (sub/keep_session/pub_topics 不适合表格)
//   6. data 段顺序: tool/version/exported/serial/registers/mqtt/mqtt_status

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. exportCfgAsJson data 含 mqtt_status
const exportFnMatch = appJs.match(/function\s+exportCfgAsJson\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 JSON'\);?\s*\}/);
assertEq(!!exportFnMatch, true, 'im-4: 找到 exportCfgAsJson 函数');
assertEq(/mqtt_status:\s*\(S\.mqtt\s*&&\s*S\.mqtt\.stat\)\s*\|\|\s*null/.test(exportFnMatch[0]), true,
  'im-4: exportCfgAsJson data 含 mqtt_status: (S.mqtt && S.mqtt.stat) || null');

// 2. CSV 不加 mqtt_status (CSV 3 段: [serial] / [registers] / [mqtt])
const csvFnMatch = appJs.match(/function\s+exportCfgAsCsv\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 CSV'\);?\s*\}/);
assertEq(!!csvFnMatch, true, 'im-4: 找到 exportCfgAsCsv 函数');
assertEq(!/mqtt_status|mqtt-status|mqttStat/i.test(csvFnMatch[0]), true,
  'im-4: exportCfgAsCsv 不加 mqtt_status (sub/keep_session/pub_topics 不适合 CSV)');

// 3. 段顺序: tool/version/exported/serial/registers/mqtt/mqtt_status
//   找 mqtt: {...} 块结束位置, 看 mqtt_status 是不是在它之后
const mqttEnd = exportFnMatch[0].lastIndexOf('manual_on: S.mqManual');
const mqttStatusIdx = exportFnMatch[0].indexOf('mqtt_status', mqttEnd);
assertEq(mqttStatusIdx > mqttEnd, true,
  'im-4: mqtt_status 在 mqtt 段 (manual_on) 之后, 段顺序正确');

// 4. mqtt_status 值用 S.mqtt.stat (不是 S.mqtt 整个, 因为 S.mqtt 还有 cfg/auto_pass)
//   排除法: mqtt_status 应该是 (S.mqtt && S.mqtt.stat) || null
//   不能是 S.mqtt (包含 cfg)
assertEq(!/mqtt_status:\s*S\.mqtt\s*\|\|/.test(exportFnMatch[0]), true,
  'im-4: mqtt_status 不直接是 S.mqtt (只取 stat 段)');

// 5. 注释说明 CSV 不导 mqtt_status
//   注: 注释在 exportCfgAsJson 函数上方, exportFnMatch 可能不含
//   检查 appJs 整文件含 "CSV 不导" 字样
assertEq(/CSV\s*不\s*导/.test(appJs), true,
  'im-4: app.js 含 "CSV 不导" 注释');

console.log('PASS: im-4 exportCfgAsJson 加 mqtt_status 段 (设备 R:STAT mqtt 段, CSV 不导)');
