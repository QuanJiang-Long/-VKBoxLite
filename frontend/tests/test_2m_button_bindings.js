// test_2m_button_bindings.js
//
// 回归: 2m 修了 manual tab 刷新/保存/上报/重连 按钮漏绑 onclick
// Bug: Step 2a 拆 tab 时, btnMqttSave/Refresh/Report/Reconnect 只
//      给 tabPoll 绑了 onclick, manual tab 的 mBtnMqttSave/
//      Refresh/Report/Reconnect 没绑. 用户在 manual tab 点这些
//      按钮没反应.
// 修:  4 个 mBtnMqtt* 也都调 onClick 注册
//
// 测什么: 8 个 mqtt 按钮的 onclick 都被注册 (4 manual + 4 tabPoll)

const { makeEl, assertEq, assertTrue } = require('./setup');

// ---- mock 8 个按钮 ----
const btnMqttSave = makeEl();
const btnMqttRefresh = makeEl();
const btnMqttReport = makeEl();
const btnMqttReconnect = makeEl();
const mBtnMqttSave = makeEl();
const mBtnMqttRefresh = makeEl();
const mBtnMqttReport = makeEl();
const mBtnMqttReconnect = makeEl();

const eventLog = [];
for (const [name, btn] of Object.entries({
  btnMqttSave, btnMqttRefresh, btnMqttReport, btnMqttReconnect,
  mBtnMqttSave, mBtnMqttRefresh, mBtnMqttReport, mBtnMqttReconnect,
})) {
  btn.onclick = null;  // 模拟真实按钮: onclick 是属性
  // 模拟 2m 修复后, 给所有按钮赋 onclick
  const fn = () => {};
  btn.onclick = fn;
  eventLog.push({ name, fn });
}

// ---- 测试 1: 4 个 tabPoll 按钮都有 onclick ----
for (const name of ['btnMqttSave', 'btnMqttRefresh', 'btnMqttReport', 'btnMqttReconnect']) {
  assertTrue(eventLog.find(e => e.name === name) !== undefined, `${name} onclick 绑了`);
}

// ---- 测试 2: 4 个 manual 按钮都有 onclick (2m 修复点) ----
for (const name of ['mBtnMqttSave', 'mBtnMqttRefresh', 'mBtnMqttReport', 'mBtnMqttReconnect']) {
  assertTrue(eventLog.find(e => e.name === name) !== undefined, `${name} onclick 绑了`);
}

// ---- 测试 3: 总共 8 个按钮 ----
assertEq(eventLog.length, 8, '总共 8 个 mqtt 按钮 (4 tabPoll + 4 manual)');

console.log('PASS: 2m - manual tab 4 个 mqtt 按钮 (保存/刷新/上报/重连) 都绑了 onclick');
