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
const inferTitleMatch = sniffBody.match(/推断结果（从监听到的请求帧反推）[\s\S]*?<\/div>/);
assertEq(inferTitleMatch && /id="btnInfer"/.test(inferTitleMatch[0]), true,
  'sniff-3 f: 推断结果子分段含 [推断轮询表] 按钮 (id="btnInfer")');
assertEq(inferTitleMatch && /id="btnAutoDetect"/.test(inferTitleMatch[0]), true,
  'sniff-3 f: 推断结果子分段含 [重新识别通讯参数] 按钮 (id="btnAutoDetect")');

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
assertEq(fclrIdx > 0 && fclrIdx < toolbarIdx, true,
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
assertEq(/el\.btnFrameRefresh\.onclick\s*=\s*readFrames/.test(appJs), true,
  'sniff-3 f: app.js el.btnFrameRefresh.onclick = readFrames (绑 frameLog)');
assertEq(/el\.btnFrameClear\.onclick\s*=\s*\(\)\s*=>\s*\{[^}]*S\.frames\s*=\s*\[\]/.test(appJs), true,
  'sniff-3 f: app.js el.btnFrameClear.onclick 清空 S.frames (绑 frameLog)');

// 8. app.js: btnInferClear 绑 inferTbody (清空推断表)
assertEq(/el\.btnInferClear\.onclick/.test(appJs), true,
  'sniff-3 f: app.js el.btnInferClear.onclick 存在');
assertEq(/inferTbody/.test(appJs.split('el.btnInferClear.onclick')[1].split('\n}')[0]), true,
  'sniff-3 f: app.js btnInferClear onclick 体内引用 inferTbody');

console.log('PASS: sniff-3 f 4 个按钮重布局 (panel-title[清空]→btnInferClear, 推断结果[推断+重识], 总线报文[刷新+清空])');
