// test_26_manual_tab_refresh.js
//
// 26-fix: 手动档点 manual tab / s1 sub-tab 时, 参数表要刷新
//   原 bug: activateTab 钩子只判 isPlatform(S.mode), 手动档进 manual tab 时
//   不调 readCfgSilent(), 点表信息一直是空的

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'app.js'),
  'utf8'
);

// 测 1: activateTab 钩子包含 manual 档判断
//   找 readCfgSilent 附近的 tabManual 分支 (不是所有 tabManual)
const m = appJs.match(/tabId === 'tabManual' \|\| tabId === 'tabPlatform'\) && S\.open[\s\S]{0,400}?readCfgSilent\(\);/);
assertEq(!!m, true, '能找到 activateTab 的 tabManual 钩子 (含 readCfgSilent)');
if (m) {
  const seg = m[0];
  const hasIsManual = seg.indexOf('isManual(S.mode)') >= 0;
  const hasIsPlatform = seg.indexOf('isPlatform(S.mode)') >= 0;
  assertEq(hasIsManual, true, 'activateTab tabManual 钩子包含 isManual(S.mode)');
  assertEq(hasIsPlatform, true, 'activateTab tabManual 钩子仍包含 isPlatform(S.mode)');
}

// 测 2: serial-tab 切换的 s1 钩子包含 manual 档判断
//   找 "key === 's1'" + isManual + readCfgSilent 整体
const m2 = appJs.match(/key === 's1'[\s\S]{0,300}?readCfgSilent\(\);/);
assertEq(!!m2, true, '能找到 serial-tab s1 readCfgSilent 钩子');
if (m2) {
  const seg = m2[0];
  const hasIsManual = seg.indexOf('isManual(S.mode)') >= 0;
  const hasIsPlatform = seg.indexOf('isPlatform(S.mode)') >= 0;
  assertEq(hasIsManual, true, 'serial-tab s1 钩子包含 isManual(S.mode)');
  assertEq(hasIsPlatform, true, 'serial-tab s1 钩子仍包含 isPlatform(S.mode)');
}

// 测 3: 26-fix 注释存在
const has26FixNote = appJs.indexOf('26-fix') >= 0;
assertEq(has26FixNote, true, 'app.js 包含 26-fix 注释');

// 测 4: 没有"只判 isPlatform"的情况残留
//   单独 isPlatform 然后直接 readCfgSilent, 不能有 || ... 在前面
//   形如 "if (xxx) isPlatform(S.mode)) readCfgSilent();" 视为残留
//   正则: 没有 "||" 或 "&&" 在 isPlatform 之前, 然后直接 readCfgSilent
const stillOnlyPlatform = /\(\s*isPlatform\(S\.mode\)\s*\)\s*readCfgSilent\(\);/.test(appJs);
assertEq(stillOnlyPlatform, false, '没有残留 "只判 isPlatform 然后 readCfgSilent" 的代码');

console.log('PASS: 26-fix - 手动档点 manual tab / s1 时参数表能刷新 (6 个测试点通过)');
