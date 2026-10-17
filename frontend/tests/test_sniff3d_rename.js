// test_sniff3d_rename.js
//
// sniff-3 d: 卡片改名 + 推断结果隐藏
//   1. sniff 页面 "总线报文（旁听 sniff 模式）" -> "sniff嗅探"
//   2. 运行模式 485运行状态 中 "旁听 sniff" -> "sniff(嗅探)"
//   3. 推断结果卡片 DOM 保留但 hidden (id="snInferPanel", hidden 属性)

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

// 3. 推断结果卡片 DOM 保留但 hidden
assertEq(/id="snInferPanel"/.test(html), true,
  'sniff-3 d: 推断结果卡片有 id="snInferPanel"');
const panelMatch = html.match(/<div class="panel" id="snInferPanel"[^>]*>/);
assertEq(panelMatch && /hidden/.test(panelMatch[0]), true,
  'sniff-3 d: 推断结果卡片有 hidden 属性 (DOM 保留但不显示)');
// 3a. 推断结果 inner HTML 还在 (DOM 没删)
const panelStart = html.indexOf('id="snInferPanel"');
const panelEnd = html.indexOf('</div>', panelStart + 800);  // 跳过整个推断 panel
const panelBody = html.substring(panelStart, panelEnd + 5);
assertEq(/推断结果（从监听到的请求帧反推）/.test(panelBody), true,
  'sniff-3 d: 推断结果卡片内部 (标题+表格) 完整保留');
assertEq(/id="inferTbody"/.test(panelBody), true,
  'sniff-3 d: 推断结果表格 inferTbody 完整保留');

console.log('PASS: sniff-3 d 卡片改名 sniff嗅探 + 推断结果 DOM 保留只隐藏 + 旁听 sniff 改 sniff(嗅探)');
