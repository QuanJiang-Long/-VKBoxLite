// test_im2_export_csv_sniff.js
//
// im-2: 导入/导出改动
//   1. CSV_COLS.serial 加 ['服务器地址', 'server'] 列
//   2. collectCfg 收集 server 字段 (el.fUrl.value)
//   3. sniff 档 btnImport 禁用 (sniff 档无表单可填)
//      - setPortState 守卫加 S.mode === 'sniff'
//      - syncTabs 守卫加 mode === 'sniff'
//   4. sniff 档 btnExport 走 manual 档 prefix ('m'), 弹 toast 提示
//   5. importCfg 加 sniff 档守卫, toast 提示禁用

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const cfgJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'cfg.js'), 'utf8');

// 1. CSV_COLS.serial 加 server 列
const csvColsMatch = appJs.match(/const CSV_COLS\s*=\s*\{[\s\S]*?serial:\s*\[([\s\S]*?)\],\s*registers:/);
assertEq(!!csvColsMatch, true, 'im-2: 找到 CSV_COLS.serial 数组');
const serialColBlock = csvColsMatch[1];
assertEq(/\[.*'服务器地址'.*,\s*'server'\s*\]/.test(serialColBlock), true,
  'im-2: CSV_COLS.serial 含 ["服务器地址", "server"] 列');

// 2. collectCfg (cfg.js) 收集 server 字段
const collectCfgMatch = cfgJs.match(/function\s+collectCfg\s*\(\s*pre\s*\)\s*\{[\s\S]*?\n\}/);
assertEq(!!collectCfgMatch, true, 'im-2: 找到 collectCfg 函数');
assertEq(/server:\s*el\.fUrl\.value\.trim\(\)/.test(collectCfgMatch[0]), true,
  'im-2: collectCfg 收集 server: el.fUrl.value.trim()');

// 3. setPortState 守卫加 sniff
const setPortStateMatch = appJs.match(/function\s+setPortState[\s\S]*?const\s+blocked\s*=\s*!open\s*\|\|[\s\S]*?\}\s*\n/);
assertEq(!!setPortStateMatch, true, 'im-2: 找到 setPortState 的 blocked 块');
assertEq(/S\.mode\s*===\s*'sniff'/.test(setPortStateMatch[0]), true,
  'im-2: setPortState blocked 含 S.mode === "sniff"');

// 4. syncTabs 守卫加 sniff
const syncTabsMatch = appJs.match(/const\s+blocked\s*=\s*!S\.open\s*\|\|[\s\S]*?\}\s*\n/);
assertEq(!!syncTabsMatch, true, 'im-2: 找到 syncTabs 的 blocked 块');
assertEq(/mode\s*===\s*'sniff'/.test(syncTabsMatch[0]), true,
  'im-2: syncTabs blocked 含 mode === "sniff"');

// 5. importCfg 加 sniff 档守卫
//   找 importCfg 体内 (从 async function importCfg 到 inp.click() + })
const importStart = appJs.indexOf('async function importCfg');
const importClick = appJs.indexOf('inp.click()', importStart);
const importEnd = importClick + 'inp.click();'.length;
const importCfgBody = appJs.substring(importStart, importEnd);
assertEq(importCfgBody.length > 0, true, 'im-2: 找到 importCfg 函数体');
assertEq(/S\.mode\s*===\s*'sniff'/.test(importCfgBody), true,
  'im-2: importCfg 体内含 S.mode === "sniff" 守卫');
assertEq(/sniff 档无表单可导入/.test(importCfgBody), true,
  'im-2: importCfg sniff 档守卫 toast 提示"sniff 档无表单可导入"');

// 6. exportCfg 加 sniff 档特判 (走 m prefix)
const exportStart = appJs.indexOf('async function exportCfg');
const exportEnd = appJs.indexOf('askExportFormat()', exportStart) + 'askExportFormat()'.length;
const exportCfgBody = appJs.substring(exportStart, exportEnd);
assertEq(exportCfgBody.length > 0, true, 'im-2: 找到 exportCfg 函数体');
assertEq(/S\.mode\s*===\s*'sniff'/.test(exportCfgBody), true,
  'im-2: exportCfg 体内含 S.mode === "sniff" 特判');
assertEq(/pre\s*=\s*'m'/.test(exportCfgBody), true,
  'im-2: exportCfg sniff 档特判把 pre 改 "m" (走手动档 prefix)');
assertEq(/sniff 档无表单, 导出当前手动档配置/.test(exportCfgBody), true,
  'im-2: exportCfg sniff 档 toast 提示"sniff 档无表单, 导出当前手动档配置"');

console.log('PASS: im-2 CSV 加 server 列 + sniff 档导入禁用/导出开启 (走 manual 档)');
