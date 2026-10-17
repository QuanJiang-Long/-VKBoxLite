// test_sniff3e_infer_merge.js
//
// sniff-3 e: 推断结果合并到 sniff嗅探 卡片, 作为第一个子分段
//   1. sniff 页面 "总线报文（旁听 sniff 模式）" -> "sniff嗅探"
//   2. 推断结果 DOM 合并到 sniff嗅探 卡片里, 作为第一个子分段
//   3. 推断结果标题 "推断结果（从监听到的请求帧反推）" 在 sniff嗅探 里
//   4. 推断结果表格 inferTbody 在 sniff嗅探 里
//   5. 总线报文工具栏 + 日志 在 sniff嗅探 里 (推断结果之后)
//   6. 总线报文工具栏前有分隔线 (margin-top + border-top)
//   7. 旧的独立 snInferPanel div 已删

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

// sniff嗅探 panel 内容范围: tabSniff 开始, 到 MQTT连接 panel 标题前
const sniffStart = html.indexOf('id="tabSniff"');
const sniffEnd = html.indexOf('MQTT连接', sniffStart);  // 下一个 panel 标题
const sniffBody = html.substring(sniffStart, sniffEnd);

// 1. sniff 页面标题 "sniff嗅探"
assertEq(/<div class="panel-title">sniff嗅探\s*</.test(sniffBody), true,
  'sniff-3 e: sniff 页面 "总线报文（旁听 sniff 模式）" 改为 "sniff嗅探"');

// 2. 推断结果标题在 sniff嗅探 里
assertEq(/推断结果（从监听到的请求帧反推）/.test(sniffBody), true,
  'sniff-3 e: 推断结果标题在 sniff嗅探 panel 内');

// 3. 推断结果表格在 sniff嗅探 里
assertEq(/id="inferTbody"/.test(sniffBody), true,
  'sniff-3 e: 推断结果表格 inferTbody 在 sniff嗅探 panel 内');

// 4. hint 元素也在 sniff嗅探 里
assertEq(/id="inferHint"/.test(sniffBody), true,
  'sniff-3 e: inferHint hint 在 sniff嗅探 panel 内');
assertEq(/id="detectHint"/.test(sniffBody), true,
  'sniff-3 e: detectHint hint 在 sniff嗅探 panel 内');

// 5. 总线报文工具栏也在 sniff嗅探 里
assertEq(/id="btnFrameRefresh"/.test(sniffBody), true,
  'sniff-3 e: 总线报文刷新按钮 btnFrameRefresh 在 sniff嗅探 panel 内');
assertEq(/id="frameLog"/.test(sniffBody), true,
  'sniff-3 e: 总线报文 frameLog 在 sniff嗅探 panel 内');

// 6. 推断结果在总线报文之前 (DOM 顺序)
const inferIdx = sniffBody.indexOf('推断结果（从监听到的请求帧反推）');
const frameLogIdx = sniffBody.indexOf('id="frameLog"');
assertEq(inferIdx > 0 && frameLogIdx > 0 && inferIdx < frameLogIdx, true,
  'sniff-3 e: 推断结果在总线报文 (frameLog) 之前 (DOM 顺序)');

// 7. 总线报文工具栏前有分隔线 (margin-top + border-top, 在 frame-toolbar 之前)
const sepIdx = sniffBody.indexOf('总线报文</div>');
const toolbarIdx = sniffBody.indexOf('frame-toolbar');
assertEq(sepIdx > 0 && toolbarIdx > 0 && sepIdx < toolbarIdx, true,
  'sniff-3 e: 总线报文子分段在 frame-toolbar 之前');
// border-top 在 <div style="..."> 上, 往前查 300 字符
const sepChunk = sniffBody.substring(Math.max(0, sepIdx - 300), sepIdx);
assertEq(/border-top:\s*1px\s+solid/.test(sepChunk), true,
  'sniff-3 e: 总线报文子分段前有 border-top 分隔线');

// 8. 旧的独立 snInferPanel div 已删
assertEq(/id="snInferPanel"/.test(html), false,
  'sniff-3 e: 旧的独立 snInferPanel div 已删 (内容合并到 sniff嗅探 里)');
assertEq(/<div class="panel-title">推断结果（从监听到的请求帧反推）/.test(html), false,
  'sniff-3 e: 旧的 panel-title 形式 "推断结果..." 已删 (现在是子分段, 不是 panel-title)');

// 9. 旧 frame-line 提示词也改成 sniff(嗅探) (跟 sniff-3 d 改名一致)
assertEq(/切到"运行模式"页选择"sniff\(嗅探\)"后/.test(html), true,
  'sniff-3 e: frame-line 提示词改为 "sniff(嗅探)" (跟 mcSniff 卡片一致)');
assertEq(/切到"运行模式"页选择"旁听 sniff"后/.test(html), false,
  'sniff-3 e: frame-line 旧提示词 "旁听 sniff" 已删');

console.log('PASS: sniff-3 e 推断结果合并到 sniff嗅探 第一个子分段 (DOM 顺序 + 分隔线 + 提示词更新)');
