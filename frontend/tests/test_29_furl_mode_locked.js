// test_29_furl_mode_locked.js
//
// 29-fix: 3 项补充
//   1. fUrl 从 input 改为 span (只读显示)
//   2. mode-card 变灰 (.locked class) 而不只是点击拦截
//   3. btnExport 加入 setPortState 守卫

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'app.js'),
  'utf8'
);
const indexHtml = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'index.html'),
  'utf8'
);

// 测 1: fUrl 在 HTML 中是 span, 不是 input
const fUrlInHtml = indexHtml.match(/<[^>]*id="fUrl"[^>]*>/);
assertEq(!!fUrlInHtml, true, '能找到 fUrl 元素');
if (fUrlInHtml) {
  const tag = fUrlInHtml[0];
  assertEq(/^<span/.test(tag), true, 'fUrl 是 span 标签');
  assertEq(/^<input/.test(tag), false, 'fUrl 不是 input 标签');
  assertEq(/class="ro-val"/.test(tag), true, 'fUrl 有 ro-val class');
  assertEq(/title="配置服务器地址，可修改"/.test(tag), false, 'fUrl 没有 "可修改" title');
}

// 测 2: fUrl.value 改成 fUrl.textContent
const hasValue = /el\.fUrl\.value\s*=/.test(appJs);
assertEq(hasValue, false, 'JS 中不再用 el.fUrl.value (应该用 textContent)');
const hasTextContent = /el\.fUrl\.textContent\s*=/.test(appJs);
assertEq(hasTextContent, true, 'JS 中使用 el.fUrl.textContent');

// 测 3: .mode-card.locked CSS 存在
const hasLockedCss = /\.mode-card\.locked\s*\{[^}]*opacity\s*:\s*\.5/.test(indexHtml);
assertEq(hasLockedCss, true, 'CSS 有 .mode-card.locked { opacity: .5 }');

// 测 4: setPortState 把 .locked class 切到 4 个 mode-card
const setPortStateFn = appJs.match(/function setPortState[\s\S]+?^}/m);
assertEq(!!setPortStateFn, true, '能找到 setPortState');
if (setPortStateFn) {
  const body = setPortStateFn[0];
  // document.querySelectorAll('.mode-card') + classList.toggle('locked', ...)
  const hasQuery = /querySelectorAll\(['"]\.mode-card['"]\)/.test(body);
  const hasToggle = /classList\.toggle\(['"]locked['"]/.test(body);
  assertEq(hasQuery, true, 'setPortState 里有 querySelectorAll(".mode-card")');
  assertEq(hasToggle, true, 'setPortState 里有 classList.toggle("locked", ...)');
}

// 测 5: btnExport 加入 setPortState 数组
if (setPortStateFn) {
  const body = setPortStateFn[0];
  assertEq(body.indexOf('btnExport') >= 0, true, 'setPortState 数组包含 btnExport');
}

// 测 6: applyMode 兜底 (28-fix 已做, 不动)
const applyModeFn = appJs.match(/async function applyMode[\s\S]+?^}/m);
assertEq(!!applyModeFn, true, '能找到 applyMode');
if (applyModeFn) {
  const head = applyModeFn[0].slice(0, 500);
  const hasOpenCheck = /if\s*\(\s*!\s*S\.open\s*\)/.test(head);
  const hasToast = /toast\(['"]请先连接串口['"]\)/.test(applyModeFn[0]);
  assertEq(hasOpenCheck, true, 'applyMode 开头有 !S.open 检查 (28-fix 兜底)');
  assertEq(hasToast, true, 'applyMode 里有 toast 提示');
}

// 测 7: 29-fix 注释存在
const has29FixNote = appJs.indexOf('29-fix') >= 0;
assertEq(has29FixNote, true, 'app.js 包含 29-fix 注释');

console.log('PASS: 29-fix - fUrl 改 span + mode-card 变灰 + btnExport 加入守卫 (7 个测试点通过)');
