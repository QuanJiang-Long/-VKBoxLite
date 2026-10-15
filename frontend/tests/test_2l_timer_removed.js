// test_2l_timer_removed.js
//
// 回归: 2l 拿了 homeTimer 里调 readMqtt(true) 的部分
// Bug: homeTimer 5s 跑 readHome + readMqtt(true), 5s 跑 readMqtt
//      → renderMqtt → 填 mMqXxx 5 字段, fillOk 只跳过当前聚焦的
//      1 个 input, 其余 4 个会被设备应答覆盖. 用户填到一半发现
//      前面的字没了.
// 修:  homeTimer 只跑 readHome, 拿掉 readMqtt(true). 仍有 timer
//      (跑 readHome 5s 抓设备状态/看门狗)
//
// 测什么: homeTimer 5s 定时器里只调 readHome, 不再调 readMqtt(true)

const fs = require('fs');
const path = require('path');
const { assertTrue, assertContains } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// ---- 测试 1: homeTimer 5s setInterval 还在 (跑 readHome) ----
assertTrue(/homeTimer\s*=\s*setInterval/.test(appJs),
  'homeTimer 5s setInterval 仍存在 (跑 readHome 抓设备状态)');

// ---- 测试 2: setInterval 的回调里**不**再**调** readMqtt(true) ----
//
// 找 homeTimer = setInterval(async () => { ... }, 5000) 整个块,
// 检查里面没有 readMqtt(true) 或 await readMqtt(true) 之类的调用
const timerBlock = appJs.match(/homeTimer\s*=\s*setInterval\(async\s*\(\)\s*=>\s*\{([\s\S]*?)\},\s*5000\)/);
assertTrue(timerBlock !== null, 'homeTimer setInterval 块存在');
assertTrue(!/readMqtt\s*\(\s*true\s*\)/.test(timerBlock[1]),
  'homeTimer 块里不应该调 readMqtt(true) (这是 2l 的修复点)');
assertTrue(/readHome\s*\(\s*\)/.test(timerBlock[1]),
  'homeTimer 块里仍调 readHome() 抓设备状态');

// ---- 测试 3: readHome 函数本身保留 ----
assertTrue(/async function readHome|function readHome/.test(appJs),
  'readHome 函数本身保留 (手动 + 5s timer 都用)');

console.log('PASS: 2l - homeTimer 5s 只调 readHome 不调 readMqtt(true), 用户 MQTT 输入不会被覆盖');

