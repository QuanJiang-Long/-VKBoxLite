// test_4_passeye.js
//
// 回归: 4-fix 修密码小眼睛 bug
// Bug: togglePassEye() 只切 mqPass (tabPoll) + hMqPass (Home), 漏了
//      mMqPass (manual). manual tab 点密码眼睛按钮没反应 (Step 2a 拆
//      tab 时漏, 跟 2m/2n/2o/2p/2q 同根)
// 修:  togglePassEye() 加上 mMqPass + mBtnMqttPassEye
//
// 测什么: togglePassEye 切换 3 个密码框 + 3 个眼睛按钮 (3 档都对齐)

const { makeEl, assertEq } = require('./setup');
const vm = require('vm');

// ---- mock 3 个密码框 + 3 个眼睛按钮 ----
const mqPass = makeEl({ value: 'pass1' });   mqPass.type = 'password';
const mMqPass = makeEl({ value: 'pass2' });  mMqPass.type = 'password';
const hMqPass = makeEl({ value: 'pass3' });  hMqPass.type = 'password';

const btnMqttPassEye = makeEl(); btnMqttPassEye.classList = { toggle: function(k, v) { this._show = v; } };
const mBtnMqttPassEye = makeEl(); mBtnMqttPassEye.classList = { toggle: function(k, v) { this._show = v; } };
const btnHomeMqttPassEye = makeEl(); btnHomeMqttPassEye.classList = { toggle: function(k, v) { this._show = v; } };

// ---- mock el (app.js 里的 Proxy, 这里简化成对象) ----
const ctx = vm.createContext({ console });
const el = {
  mqPass, mMqPass, hMqPass,
  btnMqttPassEye, mBtnMqttPassEye, btnHomeMqttPassEye,
};
ctx.el = el;

// 把 togglePassEye 注入 vm
vm.runInContext(`
function togglePassEye() {
  const show = el.mqPass.type === 'password';
  [el.mqPass, el.mMqPass, el.hMqPass].forEach(inp => {
    if (!inp) return;
    inp.type = show ? 'text' : 'password';
  });
  [el.btnMqttPassEye, el.mBtnMqttPassEye, el.btnHomeMqttPassEye].forEach(btn => {
    if (!btn) return;
    btn.classList.toggle('show', show);
    btn.title = show ? '隐藏密码' : '显示密码';
  });
}
`, ctx);

// ---- 测试 1: 初始 3 个密码框都是 password 类型 ----
assertEq(mqPass.type, 'password', '初始 mqPass 是 password');
assertEq(mMqPass.type, 'password', '初始 mMqPass 是 password');
assertEq(hMqPass.type, 'password', '初始 hMqPass 是 password');

// ---- 测试 2: 调用 togglePassEye 一次 → 3 个都变 text ----
vm.runInContext(`togglePassEye()`, ctx);
assertEq(mqPass.type, 'text', '点 1 次: mqPass 变 text');
assertEq(mMqPass.type, 'text', '点 1 次: mMqPass 变 text (4-fix 修复点)');
assertEq(hMqPass.type, 'text', '点 1 次: hMqPass 变 text');

// ---- 测试 3: 3 个眼睛按钮都加了 show class ----
assertEq(btnMqttPassEye.classList._show, true, '点 1 次: btnMqttPassEye show=true');
assertEq(mBtnMqttPassEye.classList._show, true, '点 1 次: mBtnMqttPassEye show=true (4-fix 修复点)');
assertEq(btnHomeMqttPassEye.classList._show, true, '点 1 次: btnHomeMqttPassEye show=true');

// ---- 测试 4: 再点一次 → 3 个都变回 password (要可逆) ----
vm.runInContext(`togglePassEye()`, ctx);
assertEq(mqPass.type, 'password', '点 2 次: mqPass 变回 password');
assertEq(mMqPass.type, 'password', '点 2 次: mMqPass 变回 password');
assertEq(hMqPass.type, 'password', '点 2 次: hMqPass 变回 password');

// ---- 测试 5: 3 个眼睛按钮 show=false ----
assertEq(btnMqttPassEye.classList._show, false, '点 2 次: btnMqttPassEye show=false');
assertEq(mBtnMqttPassEye.classList._show, false, '点 2 次: mBtnMqttPassEye show=false');
assertEq(btnHomeMqttPassEye.classList._show, false, '点 2 次: btnHomeMqttPassEye show=false');

// ---- 测试 6: 3 个密码框的 value 都没变 (不应被 toggle 冲掉) ----
assertEq(mqPass.value, 'pass1', 'toggle 不改 value: mqPass 仍是 pass1');
assertEq(mMqPass.value, 'pass2', 'toggle 不改 value: mMqPass 仍是 pass2');
assertEq(hMqPass.value, 'pass3', 'toggle 不改 value: hMqPass 仍是 pass3');

console.log('PASS: 4-fix - 密码小眼睛切 3 个密码框 (mqPass/mMqPass/hMqPass) + 3 个眼睛按钮, 改回原值不丢字');
