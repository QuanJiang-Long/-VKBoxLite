// test_sniff5_tab_autorefresh.js
//
// 2026-10: 每次切进 sniff 面板, 标题栏那个[刷新]的动作要自动做一遍
//   (自动重推一次推断表)。自动触发要【静默】—— 不弹 toast、不刷状态条,
//   否则每次切面板都跳一条提示太吵; 手动点按钮才带提示。
//
// 踩过的坑 (2026-10 实测): 串口是【单未决】设计, 同一时刻只能有一条指令在途。
//   切面板时若把 刷MQTT/刷报文/刷推断 三条命令一起发, 后两条直接撞
//   "上一条指令尚未返回" 失败; doInfer 又是静默的 → 看着就是"自动刷新没生效"
//   (表一直空着)。所以必须串行排队, 且撞车时要重试一次。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. activateTab 里切 sniff 面板: 三条命令【串行】排队
assertEq(/if \(tabId === 'tabSniff' && S\.open\) \{[\s\S]{0,600}await readMqtt\(\);[\s\S]{0,300}await readFrames\(\);[\s\S]{0,300}await doInfer\(true\);/.test(appJs), true,
  'sniff5: 切 sniff 面板三条命令串行 (MQTT → 报文 → 推断)');
// 不能是并发的 fire-and-forget
assertEq(!/if \(tabId === 'tabSniff' && S\.open && S\.mode === 'sniff'\) doInfer\(true\);/.test(appJs), true,
  'sniff5: 不再有并发的 doInfer(会撞串口单未决)');

// 2. doInfer 撞"尚未返回"时重试一次
const fn = appJs.substring(appJs.indexOf('async function doInfer'),
  appJs.indexOf('async function doInfer') + 2200);
assertEq(/for \(let attempt = 0; attempt < 2; attempt\+\+\)/.test(fn), true,
  'sniff5: doInfer 有重试循环');
assertEq(/尚未返回/.test(fn) && /continue;/.test(fn), true,
  'sniff5: 撞"尚未返回"时 continue 重试');
assertEq(/return;\s*\/\/\s*成功就收工/.test(fn), true,
  'sniff5: 成功后 return, 不发第二条');
assertEq(/async function doInfer\(silent\)/.test(fn), true,
  'sniff5: doInfer 接受 silent 参数');
assertEq(/if \(!silent\) toast\(/.test(fn), true,
  'sniff5: toast 受 silent 控制');
assertEq(/if \(!silent\) status\(/.test(fn), true,
  'sniff5: status 受 silent 控制');

// 3. 手动按钮仍走非静默(有提示)
assertEq(/el\.btnInfer\.onclick = doInfer;/.test(appJs), true,
  'sniff5: 手动「推断轮询表」按钮仍是有提示的 doInfer');
assertEq(/el\.btnInferRefresh\.onclick = doInfer;/.test(appJs), true,
  'sniff5: 标题栏[刷新]按钮仍是有提示的 doInfer');

console.log('PASS: sniff5 切 sniff 面板自动重推推断表(串行+重试, 静默) + 手动按钮保留提示 (9 个测试点通过)');
