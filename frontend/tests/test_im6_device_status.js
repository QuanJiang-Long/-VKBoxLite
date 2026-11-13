// test_im6_device_status.js
//
// im-6: device_status 段与导出的关系
//   历史行为: exportCfgAsJson data 里带 device_status: S.stat ? {mode,data,guard} : null
//   2026-11-04 (1aca52e "调整导出配置范围"): 有意去掉 —— 同 im-4,
//   设备运行态 (R:STAT 的 mode/data/guard) 不进配置文件
//   现在的行为:
//   1. exportCfgAsJson 不含 device_status
//   2. exportCfgAsCsv 同样不含
//   3. 设备运行态仍然活着: R:STAT 照常拉 (S.stat), 只是随配置文件一起走

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. 找到 exportCfgAsJson
const exportFnMatch = appJs.match(/function\s+exportCfgAsJson\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 JSON'\);?\s*\}/);
assertEq(!!exportFnMatch, true, 'im-6: 找到 exportCfgAsJson 函数');

// 2. JSON 导出不含 device_status (运行时状态, 1aca52e 有意去掉)
assertEq(!/device_status/.test(exportFnMatch[0]), true,
  'im-6: exportCfgAsJson 不含 device_status (运行态不进配置文件)');

// 3. CSV 导出同样不含
const csvFnMatch = appJs.match(/function\s+exportCfgAsCsv\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 CSV'\);?\s*\}/);
assertEq(!!csvFnMatch, true, 'im-6: 找到 exportCfgAsCsv 函数');
assertEq(!/device_status|device-status|deviceStat/i.test(csvFnMatch[0]), true,
  'im-6: exportCfgAsCsv 不含 device_status');

// 4. 设备运行态本身没被砍: R:STAT 仍拉回 S.stat (首页/状态卡在用)
assertEq(/S\.stat\s*=/.test(appJs), true,
  'im-6: R:STAT 仍写入 S.stat (运行态只是不进导出文件, 功能本身还在)');

console.log('PASS: im-6 导出不含 device_status 运行态 (1aca52e 调整), R:STAT 采集本身保留');
