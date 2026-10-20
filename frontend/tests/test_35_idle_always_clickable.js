// test_35_idle_always_clickable.js
//
// 35-fix: idle 永远是逃生口, 串口没开也能进. 平台档拉不到配置又不能
//   切回 idle, 用户就被卡死了.
//
// 改动:
//   - app.js: setPortState 时 mcIdle 不加 .locked class (视觉上也不灰)
//   - app.js: mode-card click handler 中 mcIdle 走单独分支, 不检查 locked
//   - iot.lua: 错误提示词 "或补用户名密码" → "或补用户密码/凭证密码"

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8')
  // 换行归一化: Windows 下 git autocrlf 检出 CRLF, 断言里的 '\n' 字面会全落空
  .replace(/\r\n/g, '\n');
const iotLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'iot', 'iot.lua'), 'utf8')
  .replace(/\r\n/g, '\n');

// === 测 1: setPortState 中 mcIdle 不加 .locked ===
// 用 indexOf 取完整函数 (regex 会被函数内的 } 干扰)
const psStart = appJs.indexOf('function setPortState');
const psEnd = appJs.indexOf('\nfunction ', psStart + 10);
assertEq(psStart > 0 && psEnd > 0, true, '能找到 setPortState 函数');
if (psStart > 0 && psEnd > 0) {
  const body = appJs.substring(psStart, psEnd);
  // locked 条件里排除 mcIdle
  assertEq(/locked['"]?,\s*!open\s*&&\s*c\.id\s*!==\s*['"]mcIdle['"]/.test(body), true,
    'setPortState: locked 条件排除 mcIdle (35-fix)');
}

// === 测 2: click handler 中 mcIdle 走单独分支, 不检查 locked ===
// 找 mode-card click handler (用 c.onclick 区分, 排除 setPortState 里的 forEach)
const clickHandler = appJs.match(/document\.querySelectorAll\(['"]\.mode-card['"]\)\.forEach[\s\S]+?c\.onclick[\s\S]+?\}\);/);
assertEq(!!clickHandler, true, '能找到 mode-card click handler (c.onclick)');
if (clickHandler) {
  const body = clickHandler[0];
  // mcIdle 单独分支存在
  assertEq(/m\s*===\s*['"]idle['"]/.test(body), true,
    'click handler: 检查 m === "idle"');
  // 非 idle 才有 locked 守卫 (用 c.classList.contains 调用, 排除注释里的 "locked")
  assertEq(/c\.classList\.contains\(['"]locked['"]\)/.test(body), true,
    'click handler: 非 idle 档有 c.classList.contains("locked") 守卫');
  // idle 分支有 applyMode(m); return; 早退 (绕过 locked 检查)
  const idleBranch = body.match(/m\s*===\s*['"]idle['"][\s\S]+?applyMode\(m\);\s*return;/);
  assertEq(!!idleBranch, true,
    'click handler: idle 分支有 applyMode(m); return; 早退 (35-fix)');
  // locked 调用 在 idle 早退之后 (用位置: locked 调用比 idle 早退靠后)
  const idleReturnPos = body.indexOf('applyMode(m);\n      return;');
  const lockedCheckPos = body.indexOf('classList.contains(\'locked\')');
  assertEq(idleReturnPos > 0 && lockedCheckPos > idleReturnPos, true,
    'click handler: locked 检查在 idle 早退之后 (35-fix)');
}

// === 测 3: 错误提示词已改 ===
// 之前: "或补用户名密码" (35-fix 改之前)
// 之后: "或补用户密码/凭证密码"
assertEq(/或补用户密码\/凭证密码/.test(iotLua), true,
  'iot.lua: 错误提示词改为 "或补用户密码/凭证密码"');
assertEq(/或补用户名密码/.test(iotLua), false,
  'iot.lua: 不再有旧的 "或补用户名密码" 提示词');

console.log('PASS: 35-fix idle 永远是逃生口 + 错误提示词改 (3 个分类通过)');
