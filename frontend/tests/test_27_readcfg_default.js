// test_27_readcfg_default.js
//
// 27-fix: readCfgSilent() 在 src='default' (设备没保存过配置) 时不应该早 return
//   原 bug: 设备 ds_poll 是空, src='default', readCfgSilent 早 return, 不读 REG,
//   进 manual tab / s1 sub-tab 时点表还是缓存的, 必须手动点「读取配置」才能刷新

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const cfgJs = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'cfg.js'),
  'utf8'
);

// 测 1: readCfgSilent 函数存在
const hasReadCfgSilent = /async function readCfgSilent\s*\(\)/.test(cfgJs);
assertEq(hasReadCfgSilent, true, 'readCfgSilent 函数存在');

// 测 2: 之前有"src=default 早 return" 的代码, 现在应该没有了
//   查找 "if (S.cfgSrc === 'default')" + return 的连续代码
const earlyReturnPattern = /if\s*\(\s*S\.cfgSrc\s*===\s*['"]default['"]\s*\)[\s\S]{0,200}?return\s*;/;
const hasEarlyReturn = earlyReturnPattern.test(cfgJs);
assertEq(hasEarlyReturn, false, 'readCfgSilent 不再有 src=default 早 return 的代码');

// 测 3: readCfgSilent 中 W:REG 仍会被调用 (在 default 路径后)
const readCfgSilentFn = cfgJs.match(/async function readCfgSilent\s*\(\)[\s\S]+?^}/m);
assertEq(!!readCfgSilentFn, true, '能匹配到 readCfgSilent 函数体');
if (readCfgSilentFn) {
  const body = readCfgSilentFn[0];
  // 找 W:REG 调用
  const hasRegCall = /sendCmd\(Protocol\.Enc\.reg\(\), ['"]REG['"]/.test(body);
  assertEq(hasRegCall, true, 'readCfgSilent 函数体内能找到 W:REG 调用');
  // 找 renderRegTable 调用
  const hasRenderTable = /renderRegTable\(pre\)/.test(body);
  assertEq(hasRenderTable, true, 'readCfgSilent 函数体内能找到 renderRegTable 调用');
}

// 测 4: 27-fix 注释存在
const has27FixNote = cfgJs.indexOf('27-fix') >= 0;
assertEq(has27FixNote, true, 'cfg.js 包含 27-fix 注释');

// 测 5: readCfg (非 silent) 仍保留 toast 提示 (行为参考)
const readCfgFn = cfgJs.match(/async function readCfg\([\s\S]+?^}/m);
if (readCfgFn) {
  const body = readCfgFn[0];
  const hasDefaultToast = /设备尚未保存过配置/.test(body);
  assertEq(hasDefaultToast, true, 'readCfg (手动按钮) 仍保留 default toast 提示');
}

console.log('PASS: 27-fix - readCfgSilent 在 default 时也读 REG (5 个测试点通过)');
