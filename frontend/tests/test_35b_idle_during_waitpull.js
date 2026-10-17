// test_35b_idle_during_waitpull.js
//
// 35b-fix 系列: 让 idle 切档在 waitPullDone 期间也能响应, 不被 JS 守卫挡住,
//   也不被 .switching class 视觉灰
//
// 35b-fix:    applyMode 内部的 S.modeSwitching 守卫对 idle 放行
// 35b-fix v2: renderMode 的 .switching class 排除 mcIdle
// 35c-fix:    waitPullDone 用户切走后 (mode 不是 platform) 静默返回, 不弹"拉取失败"误提示

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// === 测 1: applyMode 内部的 modeSwitching 守卫, idle 时不挡 ===
const amStart = appJs.indexOf('async function applyMode');
const amEnd = appJs.indexOf('\nfunction ', amStart + 10);
assertEq(amStart > 0 && amEnd > 0, true, '能找到 applyMode 函数');
if (amStart > 0 && amEnd > 0) {
  const body = appJs.substring(amStart, amEnd);
  assertEq(/S\.modeSwitching\s*&&\s*mode\s*!==\s*['"]idle['"]/.test(body), true,
    '35b-fix: applyMode 中 modeSwitching 守卫对 idle 档放行');
}

// === 测 2: renderMode 中 .switching class 不加给 mcIdle ===
const rmStart = appJs.indexOf('function renderMode');
const rmEnd = appJs.indexOf('\nfunction ', rmStart + 10);
assertEq(rmStart > 0 && rmEnd > 0, true, '能找到 renderMode 函数');
if (rmStart > 0 && rmEnd > 0) {
  const body = appJs.substring(rmStart, rmEnd);
  assertEq(/c\.id\s*!==\s*['"]mcIdle['"][\s\S]{0,80}switching/.test(body), true,
    '35b-fix v2: renderMode .switching class 排除 mcIdle');
}

// === 测 3: click handler idle 分支没有 modeSwitching 检查 ===
const clickHandler = appJs.match(/document\.querySelectorAll\(['"]\.mode-card['"]\)\.forEach[\s\S]+?c\.onclick[\s\S]+?\}\);/);
assertEq(!!clickHandler, true, '能找到 mode-card click handler (c.onclick)');
if (clickHandler) {
  const body = clickHandler[0];
  const idleBranch = body.match(/m\s*===\s*['"]idle['"][\s\S]+?applyMode\(m\);\s*return;/);
  assertEq(!!idleBranch, true, '能找到 idle 分支');
  if (idleBranch) {
    assertEq(/S\.modeSwitching\s*\)[\s\S]{0,40}return/.test(idleBranch[0]), false,
      '35b-fix: idle 分支没有 S.modeSwitching 检查');
  }
}

// === 测 4: waitPullDone 检查 mode, 不是 platform 静默返回 ===
const wpStart = appJs.indexOf('async function waitPullDone');
const wpEnd = appJs.indexOf('\nfunction ', wpStart + 10);
assertEq(wpStart > 0 && wpEnd > 0, true, '能找到 waitPullDone 函数');
if (wpStart > 0 && wpEnd > 0) {
  const body = appJs.substring(wpStart, wpEnd);
  assertEq(/mode\s*!==\s*['"]platform['"][\s\S]{0,40}return\s+false/.test(body), true,
    '35c-fix: waitPullDone 检查 mode 不是 platform 时静默返回 (35b 漏了)');
}

console.log('PASS: 35b/c-fix applyMode 守卫 + renderMode .switching + waitPullDone 静默退出 (4 个分类通过)');
