// test_im4_mqtt_status_export.js
//
// im-4: mqtt_status 段与导出的关系
//   历史行为: exportCfgAsJson data 里带 mqtt_status: (S.mqtt && S.mqtt.stat) || null
//   2026-11-04 (1aca52e "调整导出配置范围"): 有意去掉 —— 运行时状态不该
//   进配置文件 (配置文件用于跨设备导入, 拿着别台设备的运行态没意义)
//   现在的行为:
//   1. exportCfgAsJson 不含 mqtt_status (运行态不导出)
//   2. exportCfgAsCsv 同样不含
//   3. data 有 mode 字段记录当前档位 (1aca52e 补的)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. 找到 exportCfgAsJson
const exportFnMatch = appJs.match(/function\s+exportCfgAsJson\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 JSON'\);?\s*\}/);
assertEq(!!exportFnMatch, true, 'im-4: 找到 exportCfgAsJson 函数');

// 2. JSON 导出不含 mqtt_status (运行时状态, 1aca52e 有意去掉)
assertEq(!/mqtt_status/.test(exportFnMatch[0]), true,
  'im-4: exportCfgAsJson 不含 mqtt_status (运行态不进配置文件)');

// 3. CSV 导出同样不含 mqtt_status
const csvFnMatch = appJs.match(/function\s+exportCfgAsCsv\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 CSV'\);?\s*\}/);
assertEq(!!csvFnMatch, true, 'im-4: 找到 exportCfgAsCsv 函数');
assertEq(!/mqtt_status|mqtt-status|mqttStat/i.test(csvFnMatch[0]), true,
  'im-4: exportCfgAsCsv 不含 mqtt_status');

// 4. data 有 mode 字段记录当前档位 (1aca52e: 导出时记录来源档位)
assertEq(/mode:\s*S\.mode\s*\|\|\s*'manual'/.test(exportFnMatch[0]), true,
  'im-4: exportCfgAsJson data 含 mode: S.mode || "manual" (记录来源档位)');

// 5. app.js 保留 "CSV 不导" 相关注释语境 (历史说明, 防止误删 MQTT 静态配置)
assertEq(/manual_on:\s*S\.mqManual/.test(exportFnMatch[0]), true,
  'im-4: mqtt 段仍导出 manual_on (静态配置保留)');

console.log('PASS: im-4 导出不含 mqtt_status 运行态 (1aca52e 调整), JSON/CSV 一致, mode 来源档位保留');
