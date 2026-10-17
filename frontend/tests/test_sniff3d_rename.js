// test_sniff3d_rename.js
//
// sniff-3 d: 卡片改名 + 推断结果先隐藏 (sniff-3 e 之后已合并到 sniff嗅探 里)
//   1. sniff 页面 "总线报文（旁听 sniff 模式）" -> "sniff嗅探"
//   2. 运行模式 485运行状态 中 "旁听 sniff" -> "sniff(嗅探)"
//   注: sniff-3 d 之后 sniff-3 e 把推断结果合并到 sniff嗅探 卡片里, 此处
//        只验证 2 个改名, 推断结果 DOM 验证交给 sniff-3 e

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

// 1. sniff 页面标题 "sniff嗅探"
assertEq(/<div class="panel-title">sniff嗅探\s*</.test(html), true,
  'sniff-3 d: sniff 页面 "总线报文（旁听 sniff 模式）" 改为 "sniff嗅探"');
assertEq(/总线报文（旁听 sniff 模式）/.test(html), false,
  'sniff-3 d: 旧标题 "总线报文（旁听 sniff 模式）" 已删除');

// 2. 运行模式 mode-card 标题 "sniff(嗅探)"
assertEq(/<div class="m-title">sniff\(嗅探\)<\/div>/.test(html), true,
  'sniff-3 d: 运行模式 485运行状态 "旁听 sniff" 改为 "sniff(嗅探)"');
assertEq(/<div class="m-title">旁听 sniff<\/div>/.test(html), false,
  'sniff-3 d: 旧 m-title "旁听 sniff" 已删除');

// 3. frameLog 提示词改为 "sniff(嗅探)" (跟 sniff-3 d/e 改名一致)
assertEq(/切到"运行模式"页选择"sniff\(嗅探\)"后/.test(html), true,
  'sniff-3 d: frame-line 提示词改为 "sniff(嗅探)"');

console.log('PASS: sniff-3 d 卡片改名 sniff嗅探 + 旁听 sniff 改 sniff(嗅探) (推断结果合并到 sniff-3 e)');
