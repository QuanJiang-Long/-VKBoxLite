// test_sniff3g_toggle.js
//
// sniff-3 g: 推断结果标题简化 + 总线报文滑动开关
//   1. 推断结果标题 "（从监听到的请求帧反推）" 删除, 只剩 "推断结果"
//   2. 总线报文子分段加滑动开关 (id="frameSectionOn", type="checkbox", 默认 unchecked)
//   3. 开关在总线报文标题行 (.switch class)
//   4. 按钮容器 frameButtons (#frameButtons) + 内容容器 frameBody (#frameBody) 加 id
//   5. frameBody 包裹 frame-toolbar + frame-log
//   6. app.js 绑 frameSectionOn onchange 切换 frameButtons/frameBody hidden
//   7. 初始化时按 checked 状态调 applyFrameSection

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// sniff嗅探 panel 范围
const sniffStart = html.indexOf('id="tabSniff"');
const sniffEnd = html.indexOf('MQTT连接', sniffStart);
const sniffBody = html.substring(sniffStart, sniffEnd);

// 1. 推断结果标题简化
assertEq(/<div[^>]*>\s*推断结果\s*<span/.test(sniffBody), true,
  'sniff-3 g: 推断结果标题只剩 "推断结果" (后面紧跟 <span id="inferHint">)');
assertEq(/推断结果（从监听到的请求帧反推）/.test(sniffBody), false,
  'sniff-3 g: 旧标题 "推断结果（从监听到的请求帧反推）" 已删');

// 2. 总线报文子分段加滑动开关
assertEq(/id="frameSectionOn"/.test(sniffBody), true,
  'sniff-3 g: 总线报文子分段加滑动开关 id="frameSectionOn"');
// 2a. 默认 unchecked (没 checked 属性)
const switchMatch = sniffBody.match(/<input id="frameSectionOn"[^>]*>/);
assertEq(switchMatch && !/\bchecked\b/.test(switchMatch[0]), true,
  'sniff-3 g: 滑动开关 frameSectionOn 默认 unchecked (没 checked 属性)');
// 2b. .switch 包裹
const switchContainer = sniffBody.match(/<label class="switch"[^>]*>[\s\S]*?id="frameSectionOn"[\s\S]*?<\/label>/);
assertEq(switchContainer && /<span class="sl"><\/span>/.test(switchContainer[0]), true,
  'sniff-3 g: 滑动开关用 .switch class + .sl slider');

// 3. 按钮容器 + 内容容器加 id
assertEq(/id="frameButtons"/.test(sniffBody), true,
  'sniff-3 g: 按钮容器 id="frameButtons" (含 [刷新][清空])');
assertEq(/id="frameBody"/.test(sniffBody), true,
  'sniff-3 g: 内容容器 id="frameBody" (含 frame-toolbar + frame-log)');

// 4. frameBody 包裹 frame-toolbar + frame-log
const bodyMatch = sniffBody.match(/<div id="frameBody">[\s\S]*?<\/div>\s*<\/div>/);
assertEq(bodyMatch && /<div class="frame-toolbar">/.test(bodyMatch[0]), true,
  'sniff-3 g: frameBody 包裹 frame-toolbar');
assertEq(bodyMatch && /id="frameLog"/.test(bodyMatch[0]), true,
  'sniff-3 g: frameBody 包裹 frameLog');

// 5. app.js el 引用
assertEq(/frameSectionOn:\s*\$?\(['"]frameSectionOn['"]\)/.test(appJs), true,
  'sniff-3 g: app.js 加 el.frameSectionOn 引用');
assertEq(/frameButtons:\s*\$?\(['"]frameButtons['"]\)/.test(appJs), true,
  'sniff-3 g: app.js 加 el.frameButtons 引用');
assertEq(/frameBody:\s*\$?\(['"]frameBody['"]\)/.test(appJs), true,
  'sniff-3 g: app.js 加 el.frameBody 引用');

// 6. applyFrameSection 函数 + onchange 绑定
assertEq(/function\s+applyFrameSection\s*\(/.test(appJs), true,
  'sniff-3 g: app.js 加 applyFrameSection(on) 函数');
assertEq(/el\.frameSectionOn\.addEventListener\(['"]change['"]/.test(appJs), true,
  'sniff-3 g: app.js 绑 frameSectionOn change 事件');

// 7. applyFrameSection 体内: 切换 frameButtons + frameBody 显隐
// sniff-3 h fix: 不能用 hidden 属性, 因为 frameButtons 有内联 display:flex
//   优先级高于 [hidden]{display:none}. 改用 style.display 直接设
const afStart = appJs.indexOf('function applyFrameSection');
const afEnd = appJs.indexOf('\n}', afStart + 30);
const afBody = appJs.substring(afStart, afEnd + 5);
assertEq(/el\.frameButtons\.style\.display\s*=\s*disp/.test(afBody), true,
  'sniff-3 h fix: applyFrameSection 切 frameButtons.style.display (不能用 hidden 属性)');
assertEq(/el\.frameBody\.style\.display\s*=\s*disp/.test(afBody), true,
  'sniff-3 h fix: applyFrameSection 切 frameBody.style.display (不能用 hidden 属性)');
// 不能用 hidden 属性 (会被内联 display:flex 覆盖)
assertEq(/el\.frameButtons\.hidden\s*=\s*!on/.test(afBody), false,
  'sniff-3 h fix: applyFrameSection 不再用 frameButtons.hidden (内联 display 覆盖)');

// 8. 初始化时调 applyFrameSection
assertEq(/applyFrameSection\(!!el\.frameSectionOn\.checked\)/.test(appJs), true,
  'sniff-3 g: app.js 初始化时调 applyFrameSection(!!el.frameSectionOn.checked)');

console.log('PASS: sniff-3 g 推断结果标题简化 + 总线报文滑动开关 (默认关, 切换隐藏 frameButtons + frameBody)');
