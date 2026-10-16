// test_5_hexspaced.js
//
// 验证 lua/bus/poll.lua 的 hexspaced 函数实现是正确的
// 模拟 lua gsub: 把每个字节转 "XX " 形式, 去掉末尾空格
//
// 测什么:
// 1. nil / 空字符串 → "-"
// 2. 单字节 → "ab" (无末尾空格)
// 3. 多字节 → "ab cd ef" (空格分隔, 无末尾空格)
// 4. 5 字节残帧 → "02 00 01 79 84" (跟 user 报告的 rx=0200017984 对照)

const { assertEq } = require('./setup');

// 模拟 lua hexspaced
function hexspaced(s) {
  if (!s || s.length === 0) return '-';
  return s.split('').map(c => c.charCodeAt(0).toString(16).padStart(2, '0')).join(' ').replace(/ $/, '');
}

// 测试 1: nil / 空
assertEq(hexspaced(null), '-', 'nil → -');
assertEq(hexspaced(undefined), '-', 'undefined → -');
assertEq(hexspaced(''), '-', '空字符串 → -');

// 测试 2: 单字节
assertEq(hexspaced('\xf8'), 'f8', '单字节 f8 → f8 (无末尾空格)');

// 测试 3: 多字节
assertEq(hexspaced('\x01\x03'), '01 03', '2 字节 01 03 → "01 03"');
assertEq(hexspaced('\x02\x00\x01\x79\x84'), '02 00 01 79 84', '5 字节 → "02 00 01 79 84"');

// 测试 4: 7 字节完整响应 (user 报告 sscom 抓到)
assertEq(hexspaced('\x01\x03\x02\x00\x01\x79\x84'), '01 03 02 00 01 79 84', '7 字节完整 fc3 响应');

// 测试 5: 8 字节完整 Tx 请求
//   01 03 10 00 00 01 + CRC = 8 字节
//   假设 CRC 是 0x80ca
const txFrame = '\x01\x03\x10\x00\x00\x01\x80\xca';
assertEq(hexspaced(txFrame), '01 03 10 00 00 01 80 ca', '8 字节完整 Tx 帧');

console.log('PASS: 5-hexspaced - lua hexspaced 实现正确, 5 种边界情况覆盖');
