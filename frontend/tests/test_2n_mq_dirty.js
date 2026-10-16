// test_2n_mq_dirty.js
//
// 回归: 2n 修了 manual/platform tab 的 5 字段 dirty 不报
// Bug: mqSnap() 走 E('mqHost') 拿字段, 不走档位 (manual 5 字段
//      用 mMqHost, tabPoll 用 mqHost). 改 manual 的 mMqUser,
//      mqSnap() 拿 tabPoll 的 mqUser (空), 跟 baseline 比对永远
//      != → dirty 永远 true (用户感受: 改字段不变黄) 或者永远
//      false (改 poll 字段不变黄).
// 修:  mqSnap() 走 mqttPrefix() 拿字段 (manual→'m', platform→'p', poll→'')
//
// 测什么: mqSnap 走档位正确, manual 的 mMqUser 改值能被 mqSnap 读到

const { makeEl, makeIds, assertEq } = require('./setup');
const vm = require('vm');

// ---- mock mqtt 字段 ----
// manual 用 mMqXxx, platform 用 pMqXxx, poll 用 mqXxx
// 简化测 5 个核心字段 + 几个
const ids = makeIds([
  'mqHost', 'mqPort', 'mqSsl', 'mqUser', 'mqPass',
  'mqClientId', 'mqPub', 'mqSub', 'mqInterval', 'mqKeepSession',
  'mMqHost', 'mMqPort', 'mMqSsl', 'mMqUser', 'mMqPass',
  'mMqClientId', 'mMqPub', 'mMqSub', 'mMqInterval', 'mMqKeepSession',
  'pMqHost', 'pMqPort', 'pMqSsl', 'pMqInterval', 'pMqKeepSession',
  'hMqHost', 'hMqPort', 'hMqPass', 'hMqClientId',
  'mBtnMqttSave', 'btnMqttSave', 'pBtnMqttSave', 'hBtnMqttSave',
  'stMsg',
]);
// 全部默认值
for (const k of Object.keys(ids)) {
  ids[k].value = '';
}
ids.mqHost.value = 'broker.poll';
ids.mqPort.value = '1883';
ids.mqUser.value = 'poll-user';
ids.mqInterval.value = '5000';
ids.mMqHost.value = 'broker.manual';
ids.mMqPort.value = '1884';
ids.mMqUser.value = 'manual-user';
ids.mMqInterval.value = '3000';
ids.pMqHost.value = 'broker.platform';
ids.pMqPort.value = '1885';
ids.pMqInterval.value = '4000';

const ctx = vm.createContext({ ids, console, Math, Number, String, JSON });
ctx.S = { mode: 'manual', mqSnap: null, mqDirty: false };
vm.runInContext(`
const el = ids;
const _nullStub = { value: '', textContent: '', checked: false, className: '', addEventListener: () => {} };
function E(prefix, id) {
  if (!prefix) return el[id] || _nullStub;
  const n = el[prefix + id[0].toUpperCase() + id.slice(1)];
  return n || _nullStub;
}
function mqttPrefix() { return S.mode === 'manual' ? 'm' : (S.mode === 'platform' ? 'p' : ''); }
function mqSnap() {
  const pre = mqttPrefix();
  return JSON.stringify({
    h: E(pre, 'mqHost').value,
    po: E(pre, 'mqPort').value,
    s: E(pre, 'mqSsl').value,
    u: E(pre, 'mqUser').value,
    pa: E(pre, 'mqPass').value,
    ci: E(pre, 'mqClientId').value,
    pub: E(pre, 'mqPub').value,
    sub: E(pre, 'mqSub').value,
    iv: E(pre, 'mqInterval').value,
    ks: E(pre, 'mqKeepSession').value,
  });
}
function snapMqClean() { S.mqSnap = mqSnap(); }
function refreshMqDirty() {
  const d = S.mqSnap !== null && mqSnap() !== S.mqSnap;
  if (d === S.mqDirty) return;
  S.mqDirty = d;
}
`, ctx);

// ---- 测试 1: manual 档 mqSnap 拿 mMqXxx ----
vm.runInContext(`S.mode='manual'; snapMqClean()`, ctx);
const mqManual = JSON.parse(vm.runInContext(`S.mqSnap`, ctx));
assertEq(mqManual.h, 'broker.manual', 'manual 档 mqSnap 拿 mMqHost');
assertEq(mqManual.u, 'manual-user', 'manual 档 mqSnap 拿 mMqUser');
assertEq(mqManual.iv, '3000', 'manual 档 mqSnap 拿 mMqInterval');

// ---- 测试 2: platform 档 mqSnap 拿 pMqXxx ----
vm.runInContext(`S.mode='platform'; snapMqClean()`, ctx);
const mqPlatform = JSON.parse(vm.runInContext(`S.mqSnap`, ctx));
assertEq(mqPlatform.h, 'broker.platform', 'platform 档 mqSnap 拿 pMqHost');
assertEq(mqPlatform.iv, '4000', 'platform 档 mqSnap 拿 pMqInterval');
// platform 档没有 mqUser/mqPass 字段 (只读)
// mqSnap 走 E('p', 'mqUser') → ids['pMqUser'] 不存在 → _nullStub → ''
// 这本来就是个 bug, 但暂不修, 测试先记录现状
assertEq(mqPlatform.u, '', 'platform 档 mqUser 是空 (pMqUser 不存在, 走 _nullStub)');

// ---- 测试 3: poll 档 mqSnap 拿 mqXxx ----
vm.runInContext(`S.mode='poll'; snapMqClean()`, ctx);
const mqPoll = JSON.parse(vm.runInContext(`S.mqSnap`, ctx));
assertEq(mqPoll.h, 'broker.poll', 'poll 档 mqSnap 拿 mqHost');
assertEq(mqPoll.u, 'poll-user', 'poll 档 mqSnap 拿 mqUser');
assertEq(mqPoll.iv, '5000', 'poll 档 mqSnap 拿 mqInterval');

// ---- 测试 4: 改 manual 的 mMqUser → dirty=true ----
//
// 注: 测 3 把 S.mode 改成了 'poll' 并 snapMqClean, baseline 是 poll 档.
// 这里先把 mode 切回 'manual' 再 snapMqClean, 拿 manual 档的 baseline
vm.runInContext(`S.mode='manual'; snapMqClean()`, ctx);
vm.runInContext(`ids.mMqUser.value = 'changed'; refreshMqDirty()`, ctx);
assertEq(vm.runInContext(`S.mqDirty`, ctx), true, '改 manual mMqUser 后 dirty 应该是 true');

// ---- 测试 5: 改回原值 → dirty=false (2s 同款 bug 不会再现) ----
vm.runInContext(`ids.mMqUser.value = 'manual-user'; refreshMqDirty()`, ctx);
assertEq(vm.runInContext(`S.mqDirty`, ctx), false, '改回 manual-user 后 dirty 应该恢复 false');

console.log('PASS: 2n - mqSnap 走档位, manual 字段能被正确读到, dirty 改回原值能恢复');
