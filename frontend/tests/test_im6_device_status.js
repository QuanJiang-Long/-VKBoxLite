// test_im6_device_status.js
//
// im-6: exportCfgAsJson 加 device_status 段 (R:STAT 4 段里的 mode + data + guard, 不含 mqtt)
//   1. data 含 device_status 字段
//   2. device_status 是对象: { mode, data, guard } (不含 mqtt)
//   3. mqtt_status 段保留 (im-4)
//   4. 字段值: S.stat.mode / S.stat.data / S.stat.guard
//   5. S.stat 不存在时: device_status = null
//   6. CSV 不加 device_status (对象, 不适合表格)
//   7. 段顺序: tool/version/exported/serial/registers/mqtt/mqtt_status/device_status

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. exportCfgAsJson data 含 device_status
const exportFnMatch = appJs.match(/function\s+exportCfgAsJson\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 JSON'\);?\s*\}/);
assertEq(!!exportFnMatch, true, 'im-6: 找到 exportCfgAsJson 函数');

// 2. device_status 段是对象 { mode, data, guard } 不含 mqtt
const deviceStatusMatch = exportFnMatch[0].match(/device_status:\s*S\.stat\s*\?\s*\{[\s\S]*?\}\s*:\s*null/);
assertEq(!!deviceStatusMatch, true, 'im-6: device_status 段是 S.stat ? {...} : null');
assertEq(/S\.stat\.mode/.test(deviceStatusMatch[0]), true,
  'im-6: device_status 含 S.stat.mode (mode 段)');
assertEq(/S\.stat\.data/.test(deviceStatusMatch[0]), true,
  'im-6: device_status 含 S.stat.data (data 段)');
assertEq(/S\.stat\.guard/.test(deviceStatusMatch[0]), true,
  'im-6: device_status 含 S.stat.guard (guard 段)');
// 不含 mqtt (mqtt 走 mqtt_status 段, 不重复)
assertEq(!/S\.stat\.mqtt/.test(deviceStatusMatch[0]), true,
  'im-6: device_status 不含 S.stat.mqtt (避免跟 mqtt_status 段重复)');

// 3. mqtt_status 段保留 (im-4 没删)
assertEq(/mqtt_status:\s*\(S\.mqtt\s*&&\s*S\.mqtt\.stat\)\s*\|\|\s*null/.test(exportFnMatch[0]), true,
  'im-6: mqtt_status 段保留 (im-4 没动)');

// 4. device_status 在 mqtt_status 之后 (段顺序)
const mqttStatusIdx = exportFnMatch[0].indexOf('mqtt_status:');
const deviceStatusIdx = exportFnMatch[0].indexOf('device_status:');
assertEq(mqttStatusIdx > 0 && deviceStatusIdx > mqttStatusIdx, true,
  'im-6: device_status 在 mqtt_status 之后 (段顺序: .../mqtt/mqtt_status/device_status)');

// 5. CSV 不加 device_status
const csvFnMatch = appJs.match(/function\s+exportCfgAsCsv\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 CSV'\);?\s*\}/);
assertEq(!!csvFnMatch, true, 'im-6: 找到 exportCfgAsCsv 函数');
assertEq(!/device_status|device-status|deviceStat/i.test(csvFnMatch[0]), true,
  'im-6: exportCfgAsCsv 不加 device_status (对象, 不适合 CSV)');

console.log('PASS: im-6 exportCfgAsJson 加 device_status 段 (R:STAT 3 段 mode+data+guard, 不含 mqtt, CSV 不导)');
