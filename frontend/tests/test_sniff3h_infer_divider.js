// test_sniff3h_infer_divider.js
//
// sniff-3 h: 推断结果上方加 border-top 分隔线 (跟总线报文那条同款)
//   1. sniff 嗅探 panel 内, panel-title 之后 + 推断结果子分段 之前, 有一条 border-top 分隔线
//   2. 这条线样式跟总线报文那条 (border-top:1px solid #dde2ea) 一致
//   3. 总线报文那条线仍存在 (sniff-3 e 加的, 不删)
//   4. 推断结果之前有且仅有这一条 (panel-title 直接跟分隔线, 紧接推断结果子分段)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

// sniff嗅探 panel 范围
const sniffStart = html.indexOf('id="tabSniff"');
const sniffEnd = html.indexOf('MQTT连接', sniffStart);
const sniffBody = html.substring(sniffStart, sniffEnd);

// 找 panel-title 结束位置 (sniff嗅探 标题 div 的 </div>)
const titleStart = sniffBody.indexOf('<div class="panel-title">sniff嗅探');
const titleEnd = sniffBody.indexOf('</div>', titleStart + 50);
const titleBody = sniffBody.substring(titleStart, titleEnd + 5);

// 找推断结果子分段位置
const inferStart = sniffBody.indexOf('id="btnInfer"');

// 1. 推断结果之前有 border-top 分隔线 (在 panel-title 和 推断结果 之间)
const gapChunk = sniffBody.substring(titleEnd, inferStart);
assertEq(/border-top:\s*1px\s+solid\s+#dde2ea/.test(gapChunk), true,
  'sniff-3 h: panel-title 和 推断结果 之间有 border-top:1px solid #dde2ea 分隔线');

// 2. 总线报文那条线仍存在 (sniff-3 e 加的, 不删)
const frameSepIdx = sniffBody.indexOf('border-top:1px solid #dde2ea', inferStart);
const toolbarRealIdx = sniffBody.indexOf('<div class="frame-toolbar">');
assertEq(frameSepIdx > 0 && toolbarRealIdx > 0 && frameSepIdx < toolbarRealIdx, true,
  'sniff-3 h: 总线报文那条 border-top 分隔线仍存在 (sniff-3 e 加的没删)');

// 3. sniff 嗅探 panel 内有 2 条 border-top 分隔线 (推断结果上方 + 总线报文标题上方)
const dividerCount = (sniffBody.match(/border-top:\s*1px\s+solid\s+#dde2ea/g) || []).length;
assertEq(dividerCount === 2, true,
  'sniff-3 h: sniff 嗅探 panel 内有 2 条 border-top 分隔线 (推断结果上方 1 + 总线报文标题上方 1)');

console.log('PASS: sniff-3 h 推断结果上方加 border-top 分隔线 (跟总线报文那条同款, panel 内共 2 条)');
