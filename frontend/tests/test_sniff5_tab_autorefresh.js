// test_sniff5_tab_autorefresh.js
//
// 2026-10: 每次切进 sniff 面板, 标题栏那个[刷新]的动作要自动做一遍
//   (自动重推一次推断表)。自动触发要【静默】—— 不弹 toast、不刷状态条,
//   否则每次切面板都跳一条提示太吵; 手动点按钮才带提示。
//   只在 sniff 档做: 别的档位推断表本来是空的。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. activateTab 里切 sniff 面板自动推一次推断表
assertEq(/if \(tabId === 'tabSniff' && S\.open && S\.mode === 'sniff'\) doInfer\(true\);/.test(appJs), true,
  'sniff5: 切 sniff 面板自动 doInfer(true) (静默)');

// 2. doInfer 支持 silent
const fn = appJs.substring(appJs.indexOf('async function doInfer'),
  appJs.indexOf('async function doInfer') + 1600);
assertEq(/async function doInfer\(silent\)/.test(fn), true,
  'sniff5: doInfer 接受 silent 参数');
assertEq(/if \(!silent\) toast\(/.test(fn), true,
  'sniff5: toast 受 silent 控制');
assertEq(/if \(!silent\) status\(/.test(fn), true,
  'sniff5: status 受 silent 控制');
assertEq(/if \(!silent\) \{[\s\S]{0,200}status\(/.test(fn), true,
  'sniff5: 空结果分支也受 silent 控制');

// 3. 手动按钮仍走非静默(有提示)
assertEq(/el\.btnInfer\.onclick = doInfer;/.test(appJs), true,
  'sniff5: 手动「推断轮询表」按钮仍是有提示的 doInfer');
assertEq(/el\.btnInferRefresh\.onclick = doInfer;/.test(appJs), true,
  'sniff5: 标题栏[刷新]按钮仍是有提示的 doInfer');

console.log('PASS: sniff5 切 sniff 面板自动重推推断表(静默) + 手动按钮保留提示 (6 个测试点通过)');
