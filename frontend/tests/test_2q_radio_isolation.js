// test_2q_radio_isolation.js
//
// 回归: 2q 修了 3 个 pane 的 radio 同名互相影响
// Bug: sp-s1 / sp-m-s1 / sp-p-s1 三个 pane 的 radio 全部用
//      name="databits" / "parity" / "stopbits", 同名 radio 在同一
//      文档里被浏览器合成一个 group, document.querySelector 永远
//      拿第 1 个匹配的 (tabPoll 的), 改 manual 的 radio 不会动
//      poll 的 (但视觉上像动了, 因为 document.checked 状态是
//      同一个的), readCfg 回填 manual 时 8 圆圈不显示 checked
// 修:  HTML 拆前缀 (m-databits / p-databits / databits),
//      radioVal/setRadio 加 pre 参数走档位
//
// 测什么: radioVal/setRadio 走档位正确, 改一个 group 不影响另一个

const path = require('path');
const { makeRadioGroup, makeRadioDoc, assertEq } = require('./setup');

const vm = require('vm');

// ---- mock 3 个 pane 的 radio ----
//
// 每个 pane 有 3 组 radio: databits (2 个值) / parity (3 个值) / stopbits (2 个值)
// 3 个 pane 各自独立 group (前缀不同), 互不干扰
const allRadios = [];
allRadios.push(...makeRadioGroup('databits',     ['8', '7'], '8'));  // sp-s1 (poll) 无前缀
allRadios.push(...makeRadioGroup('m-databits',   ['8', '7'], '8'));  // sp-m-s1 (manual) m- 前缀
allRadios.push(...makeRadioGroup('p-databits',   ['8', '7'], '8'));  // sp-p-s1 (platform) p- 前缀
allRadios.push(...makeRadioGroup('parity',       ['1', '2', '0'], '0'));
allRadios.push(...makeRadioGroup('m-parity',     ['1', '2', '0'], '0'));
allRadios.push(...makeRadioGroup('p-parity',     ['1', '2', '0'], '0'));
allRadios.push(...makeRadioGroup('stopbits',     ['1', '2'], '1'));
allRadios.push(...makeRadioGroup('m-stopbits',   ['1', '2'], '1'));
allRadios.push(...makeRadioGroup('p-stopbits',   ['1', '2'], '1'));

const document = makeRadioDoc(allRadios);
const ctx = vm.createContext({ document, console, Math, Number, String, JSON });
ctx.S = { mode: 'manual' };
vm.runInContext(`
function cfgPrefix() { return S.mode === 'manual' ? 'm' : (S.mode === 'platform' ? 'p' : ''); }
function radioVal(name, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = pre ? pre + '-' : '';
  const r = document.querySelector('input[name="' + p + name + '"]:checked');
  return r ? r.value : '';
}
function setRadio(name, val, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = pre ? pre + '-' : '';
  document.querySelectorAll('input[name="' + p + name + '"]').forEach(r => {
    r.checked = (r.value === String(val));
  });
}
`, ctx);

// ---- 测试 1: manual 档默认 checked = 8 ----
assertEq(vm.runInContext(`S.mode='manual'; radioVal('databits', 'm')`, ctx), '8',
  'manual 档默认 databits 应该是 8');

// ---- 测试 2: poll 档默认 checked = 8 ----
assertEq(vm.runInContext(`S.mode='poll'; radioVal('databits', '')`, ctx), '8',
  'poll 档默认 databits 应该是 8');

// ---- 测试 3: 改 manual 7, poll 不动 (隔离) ----
vm.runInContext(`S.mode='manual'; setRadio('databits', '7', 'm')`, ctx);
assertEq(vm.runInContext(`radioVal('databits', 'm')`, ctx), '7',
  '改 manual 7 后 manual 应该是 7');
assertEq(vm.runInContext(`radioVal('databits', '')`, ctx), '8',
  '改 manual 7 后 poll 应该仍是 8, 不被影响 (隔离成功)');
assertEq(vm.runInContext(`radioVal('databits', 'p')`, ctx), '8',
  '改 manual 7 后 platform 应该仍是 8, 不被影响 (隔离成功)');

// ---- 测试 4: 改 poll 7, manual 保持 ----
vm.runInContext(`S.mode='poll'; setRadio('databits', '7', '')`, ctx);
assertEq(vm.runInContext(`radioVal('databits', '')`, ctx), '7',
  '改 poll 7 后 poll 应该是 7');
assertEq(vm.runInContext(`radioVal('databits', 'm')`, ctx), '7',
  '改 poll 7 后 manual 保持之前的 7, 不被改');

// ---- 测试 5: parity 也隔离 ----
vm.runInContext(`S.mode='platform'; setRadio('parity', '1', 'p')`, ctx);
assertEq(vm.runInContext(`radioVal('parity', 'p')`, ctx), '1',
  '改 platform parity 1 后 platform 应该是 1');
assertEq(vm.runInContext(`radioVal('parity', 'm')`, ctx), '0',
  '改 platform parity 1 后 manual 仍是默认 0 (隔离成功)');
assertEq(vm.runInContext(`radioVal('parity', '')`, ctx), '0',
  '改 platform parity 1 后 poll 仍是默认 0 (隔离成功)');

// ---- 测试 6: stopbits 也隔离 ----
vm.runInContext(`S.mode='manual'; setRadio('stopbits', '2', 'm')`, ctx);
assertEq(vm.runInContext(`radioVal('stopbits', 'm')`, ctx), '2',
  '改 manual stopbits 2 后 manual 应该是 2');
assertEq(vm.runInContext(`radioVal('stopbits', '')`, ctx), '1',
  '改 manual stopbits 2 后 poll 仍是 1 (隔离成功)');

console.log('PASS: 2q - 3 pane radio group 互相隔离 (改一个不影响另一个)');
