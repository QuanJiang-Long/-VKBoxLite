// test_import_offtab_render.js
//
// 2026-11-17 真机联调挖出来的数据静默丢失问题：
//
// 现场症状:
//   用户在「模式」页（或首页）点顶部工具栏的「导入配置」，
//   界面提示"配置已导入 (JSON)：8 个寄存器"，但设备里还是老配置（甚至更少）。
//
// 根因:
//   renderRegTable(pre) 有两条"不重建 DOM"的保护：
//     ① 焦点在参数表里（别冲掉用户正在打的字）
//     ② 目标页签不可见 且 表里已有真实行（切走时焦点已 blur，只判焦点会漏）
//   导入路径从顶部工具栏进来，用户完全可能不在「手动配置」页 —— ② 命中后直接
//   return，S.regs 已经是新数据，但 DOM 还是旧表。
//   紧接着 importCfg 里 `await saveCfg()` 是按 DOM 收集寄存器的（collectRegs），
//   于是把【旧表】写进了设备：提示成功、数据没变/变少，没有报错，最难查。
//
// 修法:
//   renderRegTable(pre, force) —— force=true 时跳过两条保护；
//   applyParsedData 导入时传 true（导入本身就是"整表替换"，丢焦点可接受）。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const regJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'reg.js'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// === 点 1: renderRegTable 接受 force 参数 ===
assertEq(/function renderRegTable\(pre, force\)/.test(regJs), true,
  'renderRegTable: 带 force 形参');

// === 点 2: 两条保护都受 force 约束 ===
assertEq(/if \(!force && ae && ae\.closest && tbody\.contains && tbody\.contains\(ae\)\) return;/.test(regJs), true,
  'renderRegTable: 焦点保护在 force 时跳过');
assertEq(/if \(!force && pane && !pane\.classList\.contains\('active'\) && tbody\.querySelector && tbody\.querySelector\('\.c-addr'\)\) return;/.test(regJs), true,
  'renderRegTable: 不可见页签保护在 force 时跳过');

// === 点 3: 导入路径必须强制重建 ===
assertEq(/S\.regs = toArr\(regs\);\s*\n\s*\/\/[^\n]*\n(?:\s*\/\/[^\n]*\n)*\s*renderRegTable\(pre, true\);/.test(appJs), true,
  'applyParsedData: 导入后 renderRegTable(pre, true)');

// === 点 4: 非导入路径保持原行为（读配置/切页签不该抢焦点）===
const forced = appJs.match(/renderRegTable\(pre, true\)/g) || [];
assertEq(forced.length, 1, '只有导入路径强制重建（其它调用仍走保护）');

console.log('PASS: 非手动配置页导入不再写回旧表 (4 个测试点通过)');
