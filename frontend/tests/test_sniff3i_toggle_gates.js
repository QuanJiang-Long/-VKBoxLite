// test_sniff3i_toggle_gates.js
//
// sniff-3 i: 总线报文总开关 frameSectionOn 关时不跟设备交互
//   1. frameTimer setInterval: 关时不调 readFrames (不发 R:FRAMES)
//   2. btnFrameRefresh.onclick: 关时不调 readFrames (即使按钮可见, 代码层防御)
//   3. btnFrameClear (本地操作, 不发设备命令) 不动
//   4. 总开关开时: 行为不变 (跟 frameAuto + S.mode 配合)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. frameTimer 内含 frameSectionOn.checked 检查
const frameTimerMatch = appJs.match(/frameTimer\s*=\s*setInterval\(\s*\(\)\s*=>\s*\{[\s\S]*?\}\s*,\s*2000\s*\)\s*;/);
assertEq(!!frameTimerMatch, true, 'sniff-3 i: 找到 frameTimer setInterval 块');
assertEq(/el\.frameSectionOn/.test(frameTimerMatch[0]), true,
  'sniff-3 i: frameTimer 检查 el.frameSectionOn (总开关)');
assertEq(/el\.frameSectionOn\.checked/.test(frameTimerMatch[0]), true,
  'sniff-3 i: frameTimer 检查 frameSectionOn.checked');
// 顺序: S.pending → frameSectionOn → frameAuto → S.mode
//   "frameSectionOn" 这个子串在 "frameSectionOn.checked" 之前, 用更具体的子串
const condOrder = ['!S.pending', 'frameSectionOn &&', 'frameAuto.checked', "S.mode === 'sniff'"];
let lastIdx = -1;
const allInOrder = condOrder.every(cond => {
  const idx = frameTimerMatch[0].indexOf(cond);
  const ok = idx > lastIdx;
  lastIdx = idx;
  return ok;
});
assertEq(allInOrder, true,
  'sniff-3 i: frameTimer 条件检查顺序: S.pending → frameSectionOn → frameAuto → S.mode');

// 2. btnFrameRefresh.onclick 内含 frameSectionOn 检查
//   因为之前 sniff-3 f 改成 onClick=readFrames, sniff-3 i 改成 onClick=() => {if(...) return; readFrames()}
const btnFrameRefreshMatch = appJs.match(/el\.btnFrameRefresh\.onclick\s*=\s*[\s\S]{0,200}?;\s*\}/);
assertEq(!!btnFrameRefreshMatch, true, 'sniff-3 i: 找到 el.btnFrameRefresh.onclick 块');
assertEq(/frameSectionOn/.test(btnFrameRefreshMatch[0]), true,
  'sniff-3 i: btnFrameRefresh.onclick 检查 frameSectionOn');
assertEq(/!el\.frameSectionOn\.checked/.test(btnFrameRefreshMatch[0]), true,
  'sniff-3 i: btnFrameRefresh.onclick 关时 return (不发 R:FRAMES)');
// 后面还有 readFrames() 调用 (开时调)
assertEq(/readFrames\(\)/.test(btnFrameRefreshMatch[0]), true,
  'sniff-3 i: btnFrameRefresh.onclick 开时调 readFrames()');

// 3. btnFrameClear 不变 (本地操作, 不发设备命令)
const btnFrameClearMatch = appJs.match(/el\.btnFrameClear\.onclick\s*=\s*[\s\S]{0,200}?;/);
assertEq(!!btnFrameClearMatch, true, 'sniff-3 i: 找到 el.btnFrameClear.onclick 块');
assertEq(!/frameSectionOn/.test(btnFrameClearMatch[0]), true,
  'sniff-3 i: btnFrameClear.onclick 不检查 frameSectionOn (本地操作, 不发设备命令)');

console.log('PASS: sniff-3 i 总开关 frameSectionOn 关时不跟设备交互 (frameTimer + btnFrameRefresh 守门)');
