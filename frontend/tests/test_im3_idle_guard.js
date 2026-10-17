// test_im3_idle_guard.js
//
// im-3: idle 档导入/导出都禁用 + btnExport 加 mode 守卫
//   1. setPortState 守卫:
//      - btnImport blocked: !open || isPlatform || mode==='sniff' || mode==='idle'
//      - btnExport blocked: !open || isPlatform || mode==='idle'
//   2. syncTabs 守卫: 跟 setPortState 一致
//   3. btnExport 不再让 idle 档 enabled (避免 collectCfg('') 失败)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. setPortState 的 btnImport 守卫
const importBlockMatch = appJs.match(/if\s*\(el\.btnImport\)\s*\{[\s\S]*?S\.mode\s*===\s*'idle'\s*\?\s*'idle 档[\s\S]*?\}/);
assertEq(!!importBlockMatch, true, 'im-3: setPortState 里 btnImport 守卫块存在');
assertEq(/S\.mode\s*===\s*'idle'/.test(importBlockMatch[0]), true,
  'im-3: setPortState btnImport blocked 含 S.mode === "idle"');
assertEq(/idle 档无配置, 请先切到手动档/.test(importBlockMatch[0]), true,
  'im-3: setPortState btnImport title 提示"idle 档无配置, 请先切到手动档"');

// 2. setPortState 加了 btnExport 守卫块 (之前没有)
//   im-3 fix: platform 档允许导出, btnExport 守卫不含 isPlatform
const exportBlockMatch = appJs.match(/if\s*\(el\.btnExport\)\s*\{[\s\S]*?S\.mode\s*===\s*'idle'\s*\?\s*'idle 档[\s\S]*?\}/);
assertEq(!!exportBlockMatch, true, 'im-3: setPortState 里新增 btnExport 守卫块');
assertEq(/S\.mode\s*===\s*'idle'/.test(exportBlockMatch[0]), true,
  'im-3: setPortState btnExport blocked 含 S.mode === "idle"');
// im-3 fix: 平台档允许导出, 守卫不含 isPlatform
assertEq(/isPlatform\(S\.mode\)/.test(exportBlockMatch[0]), false,
  'im-3 fix: setPortState btnExport blocked 不含 isPlatform (平台档允许导出)');
// btnExport 不含 sniff 守卫 (sniff 档仍允许, im-2 已加)
assertEq(/S\.mode\s*===\s*'sniff'/.test(exportBlockMatch[0]), false,
  'im-3: setPortState btnExport blocked 不含 sniff (sniff 档仍允许导出 manual)');

// 3. syncTabs 守卫跟 setPortState 一致
//   syncTabs 段是 mode 切换时调, 看 syncTabs 段内 btnImport/btnExport 守卫
//   im-3 fix: syncTabs 段内 btnExport 守卫也不含 isPlatform (平台档允许导出)
const syncTabsBody = appJs.substring(
  appJs.indexOf('function syncTabs'),
  appJs.indexOf('function syncTabs') + 1500);
assertEq(/mode\s*===\s*'idle'/.test(syncTabsBody), true,
  'im-3: syncTabs 段内含 mode === "idle" 守卫');
assertEq(/mode\s*===\s*'sniff'/.test(syncTabsBody), true,
  'im-3: syncTabs 段内含 mode === "sniff" 守卫 (im-2 没删)');
// syncTabs 段内 btnExport 守卫: 只含 idle, 不含 isPlatform
//   提取 syncTabs 段内 btnExport 守卫块 (syncTabs 里用 mode 是函数参数)
const syncExportStart = syncTabsBody.indexOf('if (el.btnExport)');
assertEq(syncExportStart > 0, true, 'im-3 fix: syncTabs 段内有 btnExport 守卫块');
const syncExportBlock = syncTabsBody.substring(syncExportStart, syncExportStart + 500);
assertEq(!/isPlatform\(mode\)/.test(syncExportBlock), true,
  'im-3 fix: syncTabs btnExport 守卫不含 isPlatform (平台档允许导出)');

// 4. 整个 idle 档行为: 导入/导出都禁, user 提示明确
assertEq(/idle 档无配置, 请先切到手动档/.test(appJs), true,
  'im-3: app.js 含 "idle 档无配置, 请先切到手动档" 提示文字 (导入/导出都用)');

console.log('PASS: im-3 idle 档导入/导出都禁用 + btnExport 加 mode 守卫 (idle+platform 禁, manual+sniff 开)');
