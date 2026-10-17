// test_sniff3f_button_relayout.js
//
// sniff-3 f: sniff 嗅探 卡片内 4 个按钮重布局
//   1. panel-title [刷新] 删除, [清空] 改绑推断结果 (id 改为 btnInferClear)
//   2. 推断结果子分段: 加 [推断轮询表] + [重新识别通讯参数] 按钮 (右对齐)
//   3. 总线报文子分段: 加 [刷新] + [清空] 按钮 (右对齐, 绑 frameLog)
//   4. frame-toolbar 内的 [推断轮询表] + [重新识别通讯参数] 删除
//
// app.js 绑定:
//   - el.btnFrameRefresh: 绑 frameLog (readFrames)
//   - el.btnFrameClear: 绑 frameLog (清空 S.frames + renderFrames + renderDetected)
//   - el.btnInferClear: 绑 inferTbody (清空推断表)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// sniff嗅探 panel 范围
const sniffStart = html.indexOf('id="tabSniff"');
const sniffEnd = html.indexOf('MQTT连接', sniffStart);
const sniffBody = html.substring(sniffStart, sniffEnd);

// 1. panel-title 改: [刷新] 删了, [清空] 改 id 为 btnInferClear
// 1a. panel-title 不再含 btnFrameRefresh
const titleMatch = sniffBody.match(/<div class="panel-title">sniff嗅探[\s\S]*?<\/div>\s*<\/div>/);
assertEq(titleMatch && !/id="btnFrameRefresh"/.test(titleMatch[0]), true,
  'sniff-3 f: panel-title 删了 [刷新] 按钮 (id="btnFrameRefresh" 不在 panel-title 里)');
// 1b. panel-title 含 btnInferClear ([清空] 改 id)
assertEq(titleMatch && /id="btnInferClear"/.test(titleMatch[0]), true,
  'sniff-3 f: panel-title [清空] 按钮 id 改为 btnInferClear');

// 2. 推断结果子分段: 加 [推断轮询表] [重新识别通讯参数] 在标题行
// sniff-3 g: 标题改 "推断结果" (删 "（从监听到的请求帧反推）")
//   "推断结果" 在注释里也出现 (line 890 等), 用 btnInfer 位置反查
const btnInferIdx = sniffBody.indexOf('id="btnInfer"');
const btnAutoIdx = sniffBody.indexOf('id="btnAutoDetect"');
assertEq(btnInferIdx > 0 && btnAutoIdx > 0, true,
  'sniff-3 f: 推断结果子分段含 [推断轮询表] (btnInfer) + [重新识别通讯参数] (btnAutoDetect) 按钮');
// 找 btnInfer 之前 500 字符, 看是否含 "推断结果" 标题 + "inferHint" 标志
const inferWindow = sniffBody.substring(Math.max(0, btnInferIdx - 500), btnInferIdx);
assertEq(/id="inferHint"/.test(inferWindow), true,
  'sniff-3 f: btnInfer 之前 500 字符含 inferHint (说明是推断结果子分段内)');
assertEq(/btnAutoDetect/.test(sniffBody.substring(btnInferIdx, btnInferIdx + 200)), true,
  'sniff-3 f: btnInfer 之后 200 字符含 btnAutoDetect (两按钮相邻)');
// 推断结果标题简化: 没有 "（从监听到的请求帧反推）"
assertEq(/推断结果（从监听到的请求帧反推）/.test(sniffBody), false,
  'sniff-3 g: 推断结果标题 "（从监听到的请求帧反推）" 已删');

// 3. 总线报文子分段: 加 [刷新] [清空]
// sniff-3 f: 总线报文子分段用 flex 容器, 标题 + 按钮容器嵌套, 用位置距离验证
//   找 "总线报文" 文字和 "btnFrameRefresh" "btnFrameClear" 三个位置关系
const txIdx = sniffBody.indexOf('总线报文');
const frefIdx = sniffBody.indexOf('id="btnFrameRefresh"');
const fclrIdx = sniffBody.indexOf('id="btnFrameClear"');
assertEq(txIdx > 0 && frefIdx > 0 && fclrIdx > 0, true,
  'sniff-3 f: sniff嗅探 panel 内含 "总线报文" + btnFrameRefresh + btnFrameClear');
assertEq(frefIdx > txIdx && fclrIdx > frefIdx, true,
  'sniff-3 f: 总线报文文字 → btnFrameRefresh → btnFrameClear 顺序正确 (DOM 顺序)');
// 三个都在 frame-toolbar 之前
const toolbarIdx = sniffBody.indexOf('frame-toolbar');
// sniff-3 g: frameBody 包裹 frame-toolbar, frameButtons 在 frameBody 之外的标题行
//   但 frame-toolbar class 在 .frame-toolbar{} CSS 里也出现 (line 170), 不在 sniffBody 内
//   改找 <div class="frame-toolbar"> 实体
const toolbarRealIdx = sniffBody.indexOf('<div class="frame-toolbar">');
assertEq(fclrIdx > 0, true, 'sniff-3 f: fclrIdx > 0');
assertEq(toolbarRealIdx > 0, true, 'sniff-3 f: toolbarRealIdx > 0');
assertEq(fclrIdx < toolbarRealIdx, true,
  'sniff-3 f: 总线报文按钮容器 (含 [清空]) 在 frame-toolbar 之前');

// 4. frame-toolbar 内不再有 btnInfer / btnAutoDetect
const toolMatch = sniffBody.match(/<div class="frame-toolbar">[\s\S]*?<\/div>/);
assertEq(toolMatch && !/id="btnInfer"/.test(toolMatch[0]), true,
  'sniff-3 f: frame-toolbar 删了 [推断轮询表] 按钮');
assertEq(toolMatch && !/id="btnAutoDetect"/.test(toolMatch[0]), true,
  'sniff-3 f: frame-toolbar 删了 [重新识别通讯参数] 按钮');

// 5. frame-toolbar 仍含类型筛选 + 自动刷新 (保留)
assertEq(toolMatch && /id="frameFilter"/.test(toolMatch[0]), true,
  'sniff-3 f: frame-toolbar 保留 [类型筛选] frameFilter');
assertEq(toolMatch && /id="frameAuto"/.test(toolMatch[0]), true,
  'sniff-3 f: frame-toolbar 保留 [自动刷新] frameAuto');

// 6. app.js: el 引用 btnInferClear
assertEq(/btnInferClear:\s*\$?\(['"]btnInferClear['"]\)/.test(appJs), true,
  'sniff-3 f: app.js 加 el.btnInferClear 引用');

// 7. app.js: btnFrameRefresh/btnFrameClear 绑 frameLog (readFrames / 清空 S.frames)
// sniff-3 i: btnFrameRefresh.onclick 改成 () => { if(...) return; readFrames() }
//   包含 frameSectionOn 检查 + readFrames() 调用
const refreshMatch = appJs.match(/el\.btnFrameRefresh\.onclick\s*=\s*[\s\S]{0,200}?;\s*\}/);
assertEq(!!refreshMatch && /readFrames\(\)/.test(refreshMatch[0]), true,
  'sniff-3 f: app.js el.btnFrameRefresh.onclick 调 readFrames (绑 frameLog)');
assertEq(/el\.btnFrameClear\.onclick\s*=\s*\(\)\s*=>\s*\{[^}]*S\.frames\s*=\s*\[\]/.test(appJs), true,
  'sniff-3 f: app.js el.btnFrameClear.onclick 清空 S.frames (绑 frameLog)');

// 8. app.js: btnInferClear 绑 inferTbody (清空推断表)
assertEq(/el\.btnInferClear\.onclick/.test(appJs), true,
  'sniff-3 f: app.js el.btnInferClear.onclick 存在');
assertEq(/inferTbody/.test(appJs.split('el.btnInferClear.onclick')[1].split('\n}')[0]), true,
  'sniff-3 f: app.js btnInferClear onclick 体内引用 inferTbody');

console.log('PASS: sniff-3 f 4 个按钮重布局 (panel-title[清空]→btnInferClear, 推断结果[推断+重识], 总线报文[刷新+清空])');
