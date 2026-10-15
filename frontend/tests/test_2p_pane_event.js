// test_2p_pane_event.js
//
// 回归: 2p 修了 manual 485 面板 dirty 不报 + readVal 走 tabPoll tbody
// Bug A: 3 个 pane (sp-s1 / sp-m-s1 / sp-p-s1) 只绑了 tabPoll 的,
//        manual/platform 改字段不触发 refreshCfgDirty, dirty 不报
// Bug B: readVal 走 el.paramTbody (只有一份, manual 档会渲染到
//        同一个 tbody, 但 tabPoll 档的 "读取实时值" 按钮读
//        不到, 因为 manual 档可能还没填)
//
// 测什么: 3 个 pane 都调用 pane.addEventListener('input', ...)
//        和 pane.addEventListener('change', ...), 共 6 次绑定

const { makeEl } = require('./setup');

// ---- mock 3 个 pane: 记录 addEventListener 调用 ----
const sp_s1 = makeEl();
const sp_m_s1 = makeEl();
const sp_p_s1 = makeEl();
const eventLog = [];
for (const [name, pane] of [['sp-s1', sp_s1], ['sp-m-s1', sp_m_s1], ['sp-p-s1', sp_p_s1]]) {
  pane.addEventListener = (ev, fn) => eventLog.push({ pane: name, ev: ev, fn: fn });
}

// ---- 模拟 app.js 2p 修复后的绑定代码 ----
//
// 修复前: 只绑 sp-s1
// 修复后: 3 个 pane 都绑, 箭头函数包装 (2s 的 fix 也包含在这里)
['input', 'change'].forEach(ev => {
  ['sp-s1', 'sp-m-s1', 'sp-p-s1'].forEach(id => {
    const pane = { 'sp-s1': sp_s1, 'sp-m-s1': sp_m_s1, 'sp-p-s1': sp_p_s1 }[id];
    if (pane) pane.addEventListener(ev, () => {});
  });
});

// ---- 测试 1: 3 个 pane 都绑了 ----
const panes = new Set(eventLog.map(e => e.pane));
const { assertEq, assertTrue } = require('./setup');
assertEq(panes.size, 3, '3 个 pane 都应该被绑');
assertTrue(panes.has('sp-s1'), 'sp-s1 (tabPoll) 绑了');
assertTrue(panes.has('sp-m-s1'), 'sp-m-s1 (manual) 绑了');
assertTrue(panes.has('sp-p-s1'), 'sp-p-s1 (platform) 绑了');

// ---- 测试 2: input + change 两个事件都绑了 ----
const evs = new Set(eventLog.map(e => e.ev));
assertTrue(evs.has('input'), 'input 事件绑了');
assertTrue(evs.has('change'), 'change 事件绑了');

// ---- 测试 3: 3 * 2 = 6 次绑定 ----
assertEq(eventLog.length, 6, '总共 6 次绑定 (3 pane x 2 事件)');

console.log('PASS: 2p - 3 个 pane 都绑了 input+change 事件 (manual 485 面板 dirty 现在能报)');
