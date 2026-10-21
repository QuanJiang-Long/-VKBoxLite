// test_serial_utf8.js
//
// 串口数据必须按【流】解 UTF-8: 汉字的 3 个字节经常跨 chunk 边界, 逐块
// toString('utf8') 会把一个字变成 2~3 个替换符(乱码)。main.js 用
// StringDecoder 把不完整的尾巴缓存住, 下一块来时补齐。
//
// 现场症状 (2026-10 用户报出): 设备回的错误串偶发坏一个字 ——
//   "平台拒绝连接(CONACK 0x05 未授权), …"  →  "未接���, …"
//
// 测两件事: ① main.js 用的是流式解码 ② 流式解码在任意切点都能还原整行

const fs = require('fs');
const path = require('path');
const { StringDecoder } = require('string_decoder');
const { assertEq } = require('./setup');

const mainJs = fs.readFileSync(path.join(__dirname, '..', 'main.js'), 'utf8');

// === 1. main.js 用了流式解码 ===
assertEq(/require\(['"]string_decoder['"]\)/.test(mainJs), true,
  'utf8: main.js 引了 string_decoder');
assertEq(/utf8Decoder\.write\(chunk\)/.test(mainJs), true,
  'utf8: onData 用 utf8Decoder.write(chunk) 续解码');
assertEq(!/rxBuffer\s*\+=\s*chunk\.toString\(['"]utf8['"]\)/.test(mainJs), true,
  'utf8: 不再逐块 chunk.toString(\'utf8\')');

// === 2. 功能验证: 任意字节位置切开, 都能还原整行 ===
const line = '平台拒绝连接(CONACK 0x05 未授权), 检查地址/端口或补用户密码/凭证密码';
const bytes = Buffer.from(line, 'utf8');
let badAt = -1;
for (let cut = 1; cut < bytes.length; cut++) {
  const dec = new StringDecoder('utf8');
  const out = dec.write(bytes.subarray(0, cut)) + dec.write(bytes.subarray(cut));
  if (out !== line) { badAt = cut; break; }
}
assertEq(badAt, -1, 'utf8: StringDecoder 在任意字节切点都能还原整行 (坏点=' + badAt + ')');

// === 3. 反证: 逐块 toString 确实会坏 (否则上面那条测不出差别) ===
let naiveBrokenAt = -1;
for (let cut = 1; cut < bytes.length; cut++) {
  const out = bytes.subarray(0, cut).toString('utf8') + bytes.subarray(cut).toString('utf8');
  if (out !== line) { naiveBrokenAt = cut; break; }
}
assertEq(naiveBrokenAt >= 0, true,
  'utf8: 逐块 toString 确实会坏字 (第一个坏切点=' + naiveBrokenAt + ')');

console.log('PASS: utf8 串口流式解码 — main.js 用 StringDecoder, 任意切点可还原; 逐块解码会坏 (4 个测试点通过)');
