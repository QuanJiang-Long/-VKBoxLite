// test_34b_mode_tracking.js
//
// 34b-fix: ctrl.get_mode() 必须返回真实的 mode, 不能只靠 poll.is_running() 推导.
//   34-fix 让 poll 在槽空时不起, 此时 旧 get_mode() 会把 platform/manual 误报为 idle
//   现象: 切到 platform 后 R:MODE 还显示 mode=idle, 前端看不到进档
//
// 改动:
//   - lua/bus/ctrl.lua: 加 S.cur 记录当前 mode
//   - switch_mode 4 个成功返回点都设 S.cur
//   - get_mode() 改为 return S.cur (去掉 poll.is_running 推导)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const ctrlLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'ctrl.lua'), 'utf8');

// === 测 1: S.cur 存在 ===
assertEq(/local\s+S\s*=\s*\{\s*cur\s*=\s*["']idle["']\s*\}/.test(ctrlLua), true,
  'ctrl.lua: S.cur 默认值是 "idle"');

// === 测 2: get_mode() 改成 return S.cur (不再靠 poll.is_running 推导) ===
const getMode = ctrlLua.match(/function M\.get_mode\(\)[\s\S]+?\nend/);
assertEq(!!getMode, true, '能找到 get_mode 函数');
if (getMode) {
  const body = getMode[0].split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
  assertEq(/return\s+S\.cur/.test(body), true,
    'get_mode() 返回 S.cur');
  // 不再靠 poll.is_running() 推导
  assertEq(/poll\.is_running\(\)/.test(body), false,
    'get_mode() 不再靠 poll.is_running() 推导 (34b-fix)');
  assertEq(/mon\.is_running\(\)/.test(body), false,
    'get_mode() 不再靠 mon.is_running() 推导');
}

// === 测 3: switch_mode 4 个成功返回点都设 S.cur ===
// 4 个 S.cur 赋值点 (不一定按顺序出现, 用单独的 S.cur 出现来验证)
const sCurAssigns = (ctrlLua.match(/S\.cur\s*=\s*["'](idle|manual|platform|sniff)["']/g) || []);
const sCurValues = sCurAssigns.map(s => s.match(/["'](idle|manual|platform|sniff)["']/)[1]).sort();
assertEq(JSON.stringify(sCurValues), JSON.stringify(['idle', 'idle', 'manual', 'platform', 'platform', 'sniff']),
  'switch_mode: S.cur 赋值点包含 manual/platform/sniff/idle (idle 出现 2 次: 默认值 + idle 档赋值)');

// === 测 4: 4 个 S.cur 赋值点都存在 (总共 4 个) ===
// 把 34b-fix 注释以外的所有 S.cur 赋值都数一遍
const sCurMatches = ctrlLua.match(/S\.cur\s*=\s*["'][a-z]+["']/g) || [];
assertEq(sCurMatches.length >= 4, true,
  'S.cur 赋值点 >= 4 个 (manual/platform/sniff/idle + 默认值)');

console.log('PASS: 34b-fix get_mode 用 S.cur 显式记录 mode, 不再靠 poll/mon 推导 (4 个分类通过)');
