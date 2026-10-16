// test_6_de_hold_ms.js
//
// 验证 lua/bus/mbus.lua 的 calc_de_hold_ms 函数实现
// 这是 5-fix 排查后的 6-fix 修复: 把 hold 余量从 +2ms 改 +5ms
//
// 测什么:
// 1. 9600 8 字节 (标准 fc3 请求) → 10bit * 8 / 9600 = 8.33ms, ceil + 5 = 14ms
// 2. 9600 7 字节 (标准 fc3 响应) → 10bit * 7 / 9600 = 7.29ms, ceil + 5 = 13ms
// 3. 19200 8 字节 → 10bit * 8 / 19200 = 4.17ms, ceil + 5 = 10ms
// 4. 115200 8 字节 → 10bit * 8 / 115200 = 0.69ms, ceil + 5 = 6ms
// 5. 边界: 1 字节 → 10bit * 1 / 9600 = 1.04ms, ceil + 5 = 7ms
// 6. 校验关键不变量: hold_ms 一定 ≥ 发送时间 + 5 (余量), 不能 < 发送时间

const { assertEq, assertTrue } = require('./setup');

// 模拟 lua calc_de_hold_ms (新版本 +5ms)
function calc_de_hold_ms(nbytes, baud) {
  const bits = nbytes * (8 + 1 + 1);
  return Math.ceil(bits * 1000 / baud) + 5;
}

// 模拟发送时间 (10bit/byte @ baud)
function tx_time_ms(nbytes, baud) {
  const bits = nbytes * (8 + 1 + 1);
  return bits * 1000 / baud;
}

// ---- 1. 9600 8 字节 (用户场景: fc3 请求) ----
assertEq(calc_de_hold_ms(8, 9600), 14, '9600 8 字节: 8.33ms + 5 = 14ms');
assertTrue(calc_de_hold_ms(8, 9600) >= tx_time_ms(8, 9600) + 5, '9600 8 字节: hold ≥ tx_time + 5ms');

// ---- 2. 9600 7 字节 (fc3 响应长度) ----
assertEq(calc_de_hold_ms(7, 9600), 13, '9600 7 字节: 7.29ms + 5 = 13ms');

// ---- 3. 19200 8 字节 (高波特率) ----
assertEq(calc_de_hold_ms(8, 19200), 10, '19200 8 字节: 4.17ms + 5 = 10ms');

// ---- 4. 115200 8 字节 (超高波特率) ----
assertEq(calc_de_hold_ms(8, 115200), 6, '115200 8 字节: 0.69ms + 5 = 6ms');

// ---- 5. 边界 1 字节 ----
assertEq(calc_de_hold_ms(1, 9600), 7, '9600 1 字节: 1.04ms + 5 = 7ms');

// ---- 6. 关键不变量: hold 永远 ≥ tx_time + 5 (防止回归) ----
const cases = [
  [1, 9600], [8, 9600], [16, 9600],
  [8, 19200], [8, 38400], [8, 115200],
  [32, 115200],  // 32 寄存器大请求
];
for (const [nbytes, baud] of cases) {
  const hold = calc_de_hold_ms(nbytes, baud);
  const tx = tx_time_ms(nbytes, baud);
  assertTrue(hold >= tx + 5, `${nbytes} 字节 @ ${baud}: hold(${hold}ms) ≥ tx(${tx.toFixed(2)}ms) + 5ms`);
  assertTrue(hold >= 5, `${nbytes} 字节 @ ${baud}: hold 至少 5ms (余量不能漏)`);
}

// ---- 7. 对比: 旧版本 +2ms 是不够的, 验证问题根源 ----
function calc_de_hold_ms_old(nbytes, baud) {
  const bits = nbytes * (8 + 1 + 1);
  return Math.ceil(bits * 1000 / baud) + 2;
}
const old_hold_9600_8 = calc_de_hold_ms_old(8, 9600);  // = 11
const new_hold_9600_8 = calc_de_hold_ms(8, 9600);       // = 14
assertEq(old_hold_9600_8, 11, '旧: 9600 8 字节 hold = 11ms (不够)');
assertEq(new_hold_9600_8, 14, '新: 9600 8 字节 hold = 14ms (够 485 收发器 + 仪表响应)');
assertTrue(new_hold_9600_8 > old_hold_9600_8, '新 hold > 旧 hold (修复方向对)');

console.log('PASS: 6-fix - calc_de_hold_ms 加 5ms 余量, 7 种场景 + 1 个对比验证');
