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
// sniff-3 g: 标题简化 "推断结果" (删了 "（从监听到的请求帧反推）")
assertEq(/推断结果/.test(sniffBody), true,
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
// sniff-3 g: 推断结果标题简化 "推断结果", 用 btnInfer 位置作为推断结果子分段锚点
//   避免注释里 "推断结果" 字样干扰
const btnInferIdx2 = sniffBody.indexOf('id="btnInfer"');
const frameLogIdx = sniffBody.indexOf('id="frameLog"');
assertEq(btnInferIdx2 > 0 && frameLogIdx > 0 && btnInferIdx2 < frameLogIdx, true,
  'sniff-3 e: 推断结果子分段 (含 btnInfer) 在总线报文 (frameLog) 之前 (DOM 顺序)');

// 7. 总线报文工具栏前有分隔线 (margin-top + border-top, 在 frame-toolbar 之前)
// sniff-3 f/g: 总线报文子分段用 flex 含 [刷新] [清空] + 滑动开关, "总线报文" 后面
//   不是直接 </div>. 找 border-top:1px solid 字符串位置 (可能多种 flex 组合)
const sepIdx = sniffBody.indexOf('border-top:1px solid #dde2ea');
const toolbarRealIdx = sniffBody.indexOf('<div class="frame-toolbar">');
assertEq(sepIdx > 0, true, 'sniff-3 e: 总线报文子分段含 border-top');
assertEq(toolbarRealIdx > 0 && sepIdx < toolbarRealIdx, true,
  'sniff-3 e: 总线报文子分段 (含 border-top) 在 frame-toolbar 之前');
// border-top 字符串本身在 sepIdx 附近 (就是 <div style="..."> 里那部分)
const sepWindow = sniffBody.substring(sepIdx, sepIdx + 500);
assertEq(/总线报文/.test(sepWindow), true,
  'sniff-3 e: 总线报文子分段 (含 border-top) 内有"总线报文"文字');

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
