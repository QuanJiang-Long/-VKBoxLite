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
// sniff-3 f: 总线报文子分段现在用 flex (含 [刷新] [清空] 按钮), "总线报文" 后面不是直接 </div>
//   找 ">总线报文" 避免匹配注释里的 "总线报文" 字样
//   但 html 里 "总线报文" 在 <div> 内的换行后, 不是 ">总线报文", 所以改成
//   找包含 "border-top:1px solid #dde2ea" 的 <div> style 开头位置
const sepIdx = sniffBody.indexOf('border-top:1px solid #dde2ea;display:flex;');
const toolbarIdx = sniffBody.indexOf('frame-toolbar');
assertEq(sepIdx > 0, true, 'sniff-3 e: 总线报文子分段含 border-top + flex');
assertEq(toolbarIdx > 0 && sepIdx < toolbarIdx, true,
  'sniff-3 e: 总线报文子分段在 frame-toolbar 之前');
// border-top 字符串本身在 sepIdx 附近 (就是 <div style="..."> 里那部分)
//   sniff-3 f 改后, "总线报文" 在 <div style="..."> 内的换行后, sepIdx 找
//   border-top:1px solid 字符串位置, 直接检查 sepIdx 周围含 "总线报文"
const sepWindow = sniffBody.substring(sepIdx, sepIdx + 400);
assertEq(/总线报文/.test(sepWindow), true,
  'sniff-3 e: 总线报文子分段 (含 border-top + flex) 内有"总线报文"文字');

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
