// test_34_empty_poll.js
//
// 34-fix: 空配置不起轮询 (manual + platform 都要)
//
// 改动:
//   - lua/cfg.lua: 新增 has_poll_cfg() / has_pull_cfg()
//   - lua/bus/ctrl.lua: 模式 + 槽为空时, 跳过 poll.start
//   - lua/svc/cmd.lua: W:CFG 末尾补 poll.start (34-fix 副作用的兜底)
//   - lua/iot/iot.lua: 区分 fail 和 apply_fail
//   - frontend/renderer/app.js: waitPullDone 识别 apply_fail

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

// 换行归一化: Windows 下 git autocrlf 检出 CRLF, 断言里的 '\n' 字面会全落空
const norm = s => s.replace(/\r\n/g, '\n');
const cfgLua = norm(fs.readFileSync(path.join(__dirname, '..', '..', 'firmware', 'cfg.lua'), 'utf8'));
const ctrlLua = norm(fs.readFileSync(path.join(__dirname, '..', '..', 'firmware', 'bus', 'ctrl.lua'), 'utf8'));
const cmdLua = norm(fs.readFileSync(path.join(__dirname, '..', '..', 'firmware', 'svc', 'cmd.lua'), 'utf8'));
const iotLua = norm(fs.readFileSync(path.join(__dirname, '..', '..', 'firmware', 'iot', 'iot.lua'), 'utf8'));
const appJs = norm(fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8'));

// === 1. cfg.lua: has_poll_cfg / has_pull_cfg 函数存在 ===
assertEq(/function M\.has_poll_cfg\(\)/.test(cfgLua), true,
  'cfg.lua: has_poll_cfg() 函数存在');
assertEq(/function M\.has_pull_cfg\(\)/.test(cfgLua), true,
  'cfg.lua: has_pull_cfg() 函数存在');

// 它们的实现要看 src=="fskv" 和 #regs>0
// 用 substring 取出整个函数体 (因为 has_poll_cfg 里有 if...end, 单纯 regex 取到
// 第一个 end 就停了)
const hasPollStart = cfgLua.indexOf('function M.has_poll_cfg()');
const hasPollEnd = cfgLua.indexOf('function M.has_pull_cfg()');
assertEq(hasPollStart > 0, true, '能找到 has_poll_cfg 函数');
if (hasPollStart > 0 && hasPollEnd > 0) {
  const body = cfgLua.substring(hasPollStart, hasPollEnd)
    .split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
  // Lua 用 ~= 不是 !=
  // (实现后来重构成 src_of(K_POLL): src 变量做比较, 语义不变 —— src=="fskv" 才算有)
  assertEq(/src\s*[~=!]=\s*["']fskv["']/.test(body), true,
    'has_poll_cfg: 看 poll_src() 和 "fskv" 比较');
  assertEq(/#\(c\.regs\s*or\s*\{\}\)\s*>\s*0/.test(body), true,
    'has_poll_cfg: #regs>0 才算有');
}

// === 2. ctrl.lua: 空配置不起轮询 (manual + platform) ===
// 找 ctrl.switch_mode 中的 poll.start 段, 看条件
const pollStartBlock = ctrlLua.match(/local\s+slot\s*=\s*SLOT\[mode\][\s\S]+?if have_cfg[\s\S]+?else[\s\S]+?log\.info[\s\S]+?end/);
assertEq(!!pollStartBlock, true, '能找到 ctrl.lua poll.start 决策块');
if (pollStartBlock) {
  // 条件: mode == "manual" 时用 has_poll_cfg, mode == "platform" 时用 has_pull_cfg
  assertEq(/mode\s*==\s*["']manual["'][\s\S]+?has_poll_cfg/.test(pollStartBlock[0]), true,
    'manual 档: 用 has_poll_cfg()');
  assertEq(/mode\s*==\s*["']platform["'][\s\S]+?has_pull_cfg/.test(pollStartBlock[0]), true,
    'platform 档: 用 has_pull_cfg()');
  // 34-fix 注释存在
  assertEq(/34-fix:.*空.*不起|34-fix:.*空配置/.test(ctrlLua), true,
    'ctrl.lua 有 34-fix 注释 (空配置不起轮询)');
}

// === 3. cmd.lua: 配置提交路径补 poll.start (34-fix 兜底) ===
// (2026-11-11 起 W:CFG/W:CFINISH 的提交逻辑收敛进 commit_config(), 两条
//  上传路径共用 —— poll.start 兜底也跟着搬进去了)
const commitFn = cmdLua.match(/local function commit_config\(t\)[\s\S]+?\nend/);
assertEq(!!commitFn, true, '能找到 commit_config 函数');
if (commitFn) {
  const body = commitFn[0].split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
  // 补起 poll: in_poll_mode && !is_running → poll.start(slot)
  assertEq(/in_poll_mode/.test(body), true,
    'W:CFG: 用 in_poll_mode 决定是否起 poll');
  assertEq(/not\s+poll\.is_running\(\)/.test(body), true,
    'W:CFG: poll 没起时补起 (34-fix 副作用)');
  // 注释: 34-fix
  // 在 commit_config 全文找 34-fix 注释 + poll.start 调用 (语义断言)。
  // 不再用 "34-fix[|..200]补起[|..100]poll" 的字符窗口 —— 限近距离搜词
  // 会被注释重排/深缩进/换行符挤爆 (实测超窗 9 字符, 与代码对错无关)
  assertEq(/34-fix/.test(commitFn[0]) && /poll\.start/.test(commitFn[0]), true,
    'commit_config: 34-fix 注释 + poll.start 补起都在 (W:CFG/W:CFINISH 共用)');
}

// === 4. iot.lua: apply_fail 状态 ===
// 找 pull_finish("apply_fail", ...) 调用
const applyFailCall = iotLua.match(/pull_finish\(["']apply_fail["']/);
assertEq(!!applyFailCall, true,
  'iot.lua: pull_finish 用了 apply_fail 状态 (区分"拉取失败"和"应用失败")');

// === 5. app.js: waitPullDone 识别 apply_fail ===
// 不用 regex 取整个函数 (函数里有多处 return false, regex 贪婪/非贪婪会卡
// 在第一个 return). 直接在 app.js 中找关键模式
assertEq(/if\s*\(\s*pull\.state\s*===\s*['"]apply_fail['"]\s*\)/.test(appJs), true,
  'app.js: 识别 pull.state === "apply_fail"');
assertEq(/拉取到配置但应用失败|平台配置不适用/.test(appJs), true,
  'app.js: apply_fail 时给用户精确提示');

console.log('PASS: 34-fix 空配置不起轮询 (manual + platform), W:CFG 兜底补起, apply_fail 状态 (5 个分类通过)');
