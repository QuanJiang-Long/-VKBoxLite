// test_2s_event_arg.js
//
// 回归: 2s 修了 pane 绑事件时漏传 Event 参数的 bug
// Bug: pane.addEventListener(ev, refreshCfgDirty) 写法, refreshCfgDirty
//      接收的 pre 参数是 Event 对象 (有 isTrusted 等属性), 不是档位
//      字符串. cfgSnap(pre) 内部走 E(pre, ...), E 判 !prefix 时
//      Event 对象 truthy, 走 el[pre] = undefined 分支, 退到
//      _nullStub, 所有字段返回空字符串. 后果:
//      - cur 总是 `{"b":"","db":"","p":"","sb":"","sl":"","iv":"","to":"","r":[]}`
//      - 跟 baseline 对比永远 != → dirty 永远 true
//      - 改 mSelBaud 19200→9600 后 "保存" 不变回蓝
// 修:  箭头函数包装: pane.addEventListener(ev, () => refreshCfgDirty())
//
// 测什么: refreshCfgDirty 不带 pre 调用 → cfgSnap 走 'm' prefix →
//        cur 有正确字段值, 改回原值后 dirty 能恢复 false

const { makeEl, makeIds, makeRadioGroup, makeRadioDoc, assertEq } = require('./setup');
const vm = require('vm');

// ---- mock 控件 ----
const ids = makeIds([
  'mSelBaud', 'mInpRound', 'mInpSlave', 'mInpTimeout', 'mParamTbody',
  'mBtnSaveCfg', 'btnSaveCfg', 'stMsg', 'mBtnMqttSave',
]);
ids.mSelBaud.value = '9600';
ids.mInpRound.value = '3000';
ids.mInpSlave.value = '1';
ids.mInpTimeout.value = '500';
ids.mParamTbody.querySelectorAll = () => [];

// 3 个 pane 的 radio (m- 前缀 manual 走 m-)
const allRadios = [];
allRadios.push(...makeRadioGroup('m-databits', ['8', '7'], '8'));
allRadios.push(...makeRadioGroup('m-parity', ['1', '2', '0'], '0'));
allRadios.push(...makeRadioGroup('m-stopbits', ['1', '2'], '1'));

const document = makeRadioDoc(allRadios);

// el 代理: prefix=空 走原 id, prefix='m' 走 mXxx, prefix='p' 走 pXxx
// _nullStub: 拿不到时返回空, 不抛错
const ctx = vm.createContext({ ids, document, console, Math, Number, String, JSON });
ctx.S = { mode: 'manual', cfgSnap: null, cfgDirty: false };
vm.runInContext(`
const el = {
  mSelBaud: ids.mSelBaud, mInpRound: ids.mInpRound, mInpSlave: ids.mInpSlave,
  mInpTimeout: ids.mInpTimeout, mParamTbody: ids.mParamTbody,
  mBtnSaveCfg: ids.mBtnSaveCfg, btnSaveCfg: ids.btnSaveCfg,
  mBtnMqttSave: ids.mBtnMqttSave,
  stMsg: { textContent: '' },
};
const _nullStub = { value: '', textContent: '', checked: false, className: '', hidden: false, addEventListener: () => {} };
function E(prefix, id) {
  if (!prefix) return el[id] || _nullStub;
  const n = el[prefix + id[0].toUpperCase() + id.slice(1)];
  return n || _nullStub;
}
function cfgPrefix() { return S.mode === 'manual' ? 'm' : (S.mode === 'platform' ? 'p' : ''); }
function radioVal(name, pre) {
  if (pre === undefined) pre = cfgPrefix();
  const p = pre ? pre + '-' : '';
  const r = document.querySelector('input[name="' + p + name + '"]:checked');
  return r ? r.value : '';
}
function cfgSnap(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  const rows = [];
  if (tbody.querySelectorAll) tbody.querySelectorAll('tr').forEach(() => {});
  return JSON.stringify({
    b: E(pre, 'selBaud').value, db: radioVal('databits', pre),
    p: radioVal('parity', pre), sb: radioVal('stopbits', pre),
    sl: E(pre, 'inpSlave').value, iv: E(pre, 'inpRound').value,
    to: E(pre, 'inpTimeout').value, r: rows,
  });
}
function snapClean(pre) { S.cfgSnap = cfgSnap(pre); }
function refreshCfgDirty(pre) {
  if (pre === undefined) pre = cfgPrefix();
  const d = S.cfgSnap !== null && cfgSnap(pre) !== S.cfgSnap;
  if (d === S.cfgDirty) return;
  S.cfgDirty = d;
}
`, ctx);

// ---- 测试 1: baseline ----
vm.runInContext(`S.mode='manual'; snapClean('m')`, ctx);
assertEq(vm.runInContext(`S.cfgDirty`, ctx), false, '初始 cfgDirty 应该是 false');
assertEq(vm.runInContext(`JSON.parse(S.cfgSnap).b`, ctx), '9600', 'baseline b=9600');

// ---- 测试 2: 改 19200 → dirty=true ----
vm.runInContext(`ids.mSelBaud.value = '19200'; refreshCfgDirty()`, ctx);  // 不传 pre
assertEq(vm.runInContext(`S.cfgDirty`, ctx), true, '改 19200 后 dirty 应该是 true');
assertEq(vm.runInContext(`JSON.parse(cfgSnap()).b`, ctx), '19200', 'cur.b=19200');

// ---- 测试 3: 改回 9600 → dirty=false (真正的修复点) ----
vm.runInContext(`ids.mSelBaud.value = '9600'; refreshCfgDirty()`, ctx);
assertEq(vm.runInContext(`S.cfgDirty`, ctx), false, '改回 9600 后 dirty 应该恢复 false (2s 修复点)');

// ---- 测试 4: cfgSnap 字段值正确 (不是空字符串) ----
const snap = vm.runInContext(`cfgSnap()`, ctx);
const parsed = JSON.parse(snap);
assertEq(parsed.b, '9600', 'cur.b 应该是 9600 (不是空字符串)');
assertEq(parsed.db, '8', 'cur.db 应该是 8 (radio 走 m-databits 隔离)');
assertEq(parsed.sl, '1', 'cur.sl 应该是 1');
assertEq(parsed.iv, '3000', 'cur.iv 应该是 3000');

console.log('PASS: 2s - refreshCfgDirty 不传 pre, cfgSnap 走 m- prefix, 字段值正确, dirty 改回原值能恢复');
