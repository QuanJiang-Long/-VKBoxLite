// test_shard_fail_no_retry.js
//
// 2026-11-17 真机 60 点保存时抓到的报文（COM4 收发全记录）：
//
//   W:CFINISH=5,{...}
//     → RET:FAIL:CFG:分片5/5写入失败: fskv.set 拒写(共961B):
//       not enough memory for buffer allocation        ← 真正的原因：设备内存不够
//   W:CFINISH 重发 #1 → RET:FAIL:CFINISH:没有上传会话, 先发 W:CSHARD
//   W:CFINISH 重发 #2 → 同上
//   W:CSABORT
//
// 结果用户看到的是"保存失败：收尾失败：设备返回失败：没有上传会话"，
// 跟"内存不足"完全对不上号 —— 现场会去查串口线、查前端，永远查不到点子上。
//
// 修法：sendTry 只对【应答超时】重发；设备明确回 FAIL 时立刻把原话抛出去。
//   重发的唯一理由本来就是"应答在路上丢了"，设备已经把话说清楚就没有重发的意义。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const cfgJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'cfg.js'), 'utf8');

// === 点 1: 有 isTimeoutErr 判定 ===
assertEq(/function isTimeoutErr\(e\)/.test(cfgJs), true, 'sendTry: 有超时判定函数');
assertEq(/indexOf\('应答超时'\) >= 0/.test(cfgJs), true, 'sendTry: 认"应答超时"');

// === 点 2: 非超时错误直接抛，不再重发 ===
assertEq(/if \(!isTimeoutErr\(e\)\) throw e;/.test(cfgJs), true,
  'sendTry: 设备 FAIL 不重发（保住真原因）');

// === 点 3: 超时仍然重试（应答丢失的场景必须保留）===
assertEq(/for \(let k = 0; k < SHARD_TRIES; k\+\+\)/.test(cfgJs), true, 'sendTry: 保留重试循环');
assertEq(/if \(!isTimeoutErr\(e\)\) throw e;\s*\/\/[^\n]*\n\s*\}\s*\n\s*\}\s*\n\s*throw last;/.test(cfgJs), true,
  'sendTry: 重试耗尽后抛最后一次');

// === 点 4: 分片/收尾两条路都走 sendTry（否则修复覆盖不到 CFINISH）===
assertEq(/sendTry\(Protocol\.Enc\.cfgShard\(i, n, pieces\[i - 1\]\), 'CSHARD'\)/.test(cfgJs), true,
  'CSHARD 走 sendTry');
assertEq(/sendTry\(Protocol\.Enc\.cfgFinish\(n, fields\), 'CFINISH'\)/.test(cfgJs), true,
  'CFINISH 走 sendTry');

console.log('PASS: 分片/收尾只在超时重试，设备 FAIL 保留真原因 (4 个测试点通过)');
