// test_28_port_state_guards.js
//
// 28-fix: 串口未连接时, 首页 + 运行模式面板的功能按钮 + 顶部栏导入要变灰
//   5 个新按钮: btnImport / btnHomeRefresh / btnModeRefresh / selBootMode / btnSaveBoot
//   4 个 mode-card: 在 applyMode 开头拦截 + toast

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'app.js'),
  'utf8'
);

// 测 1: setPortState 包含 5 个新按钮
const setPortStateFn = appJs.match(/function setPortState[\s\S]+?^}/m);
assertEq(!!setPortStateFn, true, '能找到 setPortState 函数');
if (setPortStateFn) {
  const body = setPortStateFn[0];
  // 5 个新按钮名都必须在数组里
  for (const id of ['btnImport', 'btnHomeRefresh', 'btnModeRefresh', 'selBootMode', 'btnSaveBoot']) {
    assertEq(body.indexOf(id) >= 0, true, `setPortState 数组包含 ${id}`);
  }
  // 旧的 6 个还在
  for (const id of ['btnReadInfo', 'btnReadCfg', 'btnPullCfg', 'btnSaveCfg', 'btnReadVal', 'btnHomeMqttSave']) {
    assertEq(body.indexOf(id) >= 0, true, `setPortState 数组仍包含 ${id}`);
  }
}

// 测 2: btnImport 在 setPortState 里加了 OR 守卫
//   应有 "isPlatform(S.mode)" 出现在 setPortState 里
if (setPortStateFn) {
  const body = setPortStateFn[0];
  const hasIsPlatform = body.indexOf('isPlatform(S.mode)') >= 0;
  const hasOrCheck = /!\s*open\s*\|\|\s*isPlatform/.test(body);
  assertEq(hasIsPlatform, true, 'setPortState 里有 isPlatform(S.mode)');
  assertEq(hasOrCheck, true, 'setPortState 里有 "!open || isPlatform" OR 守卫');
}

// 测 3: syncTabs 也加了 OR 守卫
const syncTabsFn = appJs.match(/function syncTabs[\s\S]+?^}/m);
assertEq(!!syncTabsFn, true, '能找到 syncTabs 函数');
if (syncTabsFn) {
  const body = syncTabsFn[0];
  const hasOrCheck = /!\s*S\.open\s*\|\|\s*isPlatform/.test(body);
  assertEq(hasOrCheck, true, 'syncTabs btnImport 块里有 "!S.open || isPlatform" OR 守卫');
}

// 测 4: applyMode 开头加了 S.open 守卫
const applyModeFn = appJs.match(/async function applyMode[\s\S]+?^}/m);
assertEq(!!applyModeFn, true, '能找到 applyMode 函数');
if (applyModeFn) {
  const body = applyModeFn[0];
  // 检查前 200 字符内有 S.open 守卫 + toast
  const head = body.slice(0, 500);
  const hasOpenCheck = /if\s*\(\s*!\s*S\.open\s*\)/.test(head);
  const hasToast = /toast\(['"]请先连接串口['"]\)/.test(body);
  assertEq(hasOpenCheck, true, 'applyMode 开头有 if (!S.open) 检查');
  assertEq(hasToast, true, 'applyMode 里有 toast "请先连接串口" 提示');
}

// 测 5: 28-fix 注释存在
const has28FixNote = appJs.indexOf('28-fix') >= 0;
assertEq(has28FixNote, true, 'app.js 包含 28-fix 注释');

console.log('PASS: 28-fix - 串口未连接时 5 个新按钮 + 4 个 mode-card 守卫 (5 个测试点通过)');
