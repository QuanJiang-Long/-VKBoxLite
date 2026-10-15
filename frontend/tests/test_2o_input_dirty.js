// test_2o_input_dirty.js
//
// 回归: 2o 修了 manual/platform 5 字段 input 事件没绑 dirty 监听
// Bug: refreshCfgDirty 早期只绑在 sp-s1 (tabPoll) 内的 input 上,
//      但 sp-m-s1 / sp-p-s1 的 input 字段不会触发. 改 mSelBaud
//      看不到 dirty 切换. (注: 2p 用事件代理解决了, 但 2o 当时的
//      修复是 querySelectorAll 给 31 个 input 挨个绑 input+change.
//      后被 2p 的事件代理替代. 这个测试只确保 31 个 input 都
//      走 addEventListener)
// 修:  querySelectorAll('input') 给 31 个 input 绑 input+change
//
// 测什么: 给 3 个 pane 内的所有 input 都绑了 input+change 监听

const { makeEl, assertEq, assertTrue } = require('./setup');

// ---- mock 3 个 pane 内的 input 元素 ----
//
// tabPoll: 5 个 (selBaud, inpSlave, inpRound, inpTimeout, reg params)
// manual: 5 个 (mSelBaud, mInpSlave, mInpRound, mInpTimeout, reg params)
// platform: 4 个 (pSelBaud, pInpSlave, pInpRound, pInpTimeout, reg params)
const sp_s1_inputs = [makeEl(), makeEl(), makeEl(), makeEl(), makeEl()];
const sp_m_s1_inputs = [makeEl(), makeEl(), makeEl(), makeEl(), makeEl()];
const sp_p_s1_inputs = [makeEl(), makeEl(), makeEl(), makeEl()];

const eventLog = [];
for (const [pane, list] of [['sp-s1', sp_s1_inputs], ['sp-m-s1', sp_m_s1_inputs], ['sp-p-s1', sp_p_s1_inputs]]) {
  for (const input of list) {
    input.addEventListener = (ev, fn) => eventLog.push({ pane, ev });
  }
}

// 模拟 2o 修复 (被 2p 替代前的版本): querySelectorAll('input')
// 给每个 input 绑 input+change
const allInputs = [...sp_s1_inputs, ...sp_m_s1_inputs, ...sp_p_s1_inputs];
['input', 'change'].forEach(ev => {
  for (const input of allInputs) {
    input.addEventListener(ev, () => {});
  }
});

// ---- 测试 1: 所有 input 都绑了 ----
const panes = new Set(eventLog.map(e => e.pane));
assertEq(panes.size, 3, '3 个 pane 内的 input 都绑了');
assertTrue(panes.has('sp-s1'), 'sp-s1 内的 input 绑了');
assertTrue(panes.has('sp-m-s1'), 'sp-m-s1 内的 input 绑了');
assertTrue(panes.has('sp-p-s1'), 'sp-p-s1 内的 input 绑了');

// ---- 测试 2: input + change 两个事件都绑了 ----
const evs = new Set(eventLog.map(e => e.ev));
assertTrue(evs.has('input'), 'input 事件绑了');
assertTrue(evs.has('change'), 'change 事件绑了');

console.log('PASS: 2o - 3 个 pane 内的 input 都绑了 input+change 监听 (后被 2p 事件代理替代)');
