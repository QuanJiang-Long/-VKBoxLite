// test_38_clrpull_on_switch.js
//
// 38-fix: 从 platform 切 manual/sniff 弹窗, 默认勾选"清空平台拉取配置",
//   确认后前端发 W:CLRPULL 后再 W:MODE, 设备端 W:CLRPULL handler 只清
//   ds_pull (不动 ds_poll / mqtt 凭证).
//
// 用户意图: platform 切走意味着"不再用平台配置", 不清 ds_pull 切回
//   platform 时会被 34-fix 当成"已有旧配置"直接起, 不重新拉, 跟用户
//   预期(切走就作废)不符.

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const cmdLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'svc', 'cmd.lua'), 'utf8');
const cfgLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'cfg.lua'), 'utf8');
const protocol = fs.readFileSync(path.join(__dirname, '..', 'protocol.js'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 设备端: W:CLRPULL handler 存在
assertEq(/M\.reg\(\s*['"]W:CLRPULL['"]/.test(cmdLua), true,
  '设备端: W:CLRPULL handler 已注册 (cmd.lua)');

// 设备端: handler 检查拉取中
const clrPullStart = cmdLua.indexOf('M.reg("W:CLRPULL"');
const clrPullEnd = cmdLua.indexOf('\n    end)\n', clrPullStart + 30);
if (clrPullStart > 0 && clrPullEnd > 0) {
  const body = cmdLua.substring(clrPullStart, clrPullEnd);
  assertEq(/iot\.pulling\(\)/.test(body), true,
    '38-fix: W:CLRPULL 在拉取中拒绝 (避免擦掉正在写的 ds_pull)');
  assertEq(/cfgstore\.clear_pull/.test(body), true,
    '38-fix: W:CLRPULL 调 cfgstore.clear_pull()');
}

// cfgstore: clear_pull 函数存在
assertEq(/function M\.clear_pull\s*\(\s*\)/.test(cfgLua), true,
  'cfgstore.clear_pull() 已实现 (只清 ds_pull, 不动 ds_poll/mqtt)');
const clearPullStart = cfgLua.indexOf('function M.clear_pull');
const clearPullEnd = cfgLua.indexOf('\nend\n', clearPullStart + 100);
if (clearPullStart > 0 && clearPullEnd > 0) {
  const body = cfgLua.substring(clearPullStart, clearPullEnd);
  assertEq(/K_PULL/.test(body), true,
    '38-fix: clear_pull 只动 K_PULL (ds_pull)');
  assertEq(/K_POLL/.test(body), false,
    '38-fix: clear_pull 不动 K_POLL (ds_poll 保留, 不影响手动档)');
}

// 协议: W:CLRPULL 已注册
assertEq(/clrPull:\s*\(\s*\)\s*=>\s*['"]W:CLRPULL['"]/.test(protocol), true,
  '协议: Protocol.Enc.clrPull() 已注册 (protocol.js)');

// 前端: 弹窗函数存在
assertEq(/function askConfirmCheck/.test(appJs), true,
  '前端: askConfirmCheck 弹窗函数已实现 (带复选框)');
assertEq(/cfCheckBox|cfCheck|cfCheckLabel/.test(appJs), true,
  '前端: 弹窗 DOM 引用存在');

// 前端: applyMode 在切 manual/sniff 且当前是 platform 时弹窗 + 发 W:CLRPULL
const applyStart = appJs.indexOf('async function applyMode(mode)');
// 找下一个 "async function " 或 "function " 的开头作为 body 终点
let bodyEnd = -1;
for (let off = applyStart + 50; off < appJs.length - 50; off++) {
  if (appJs[off] === '\n' && /^(async function |function )/.test(appJs.substring(off + 1, off + 20))) {
    bodyEnd = off;
    break;
  }
}
const applyBody = appJs.substring(applyStart, bodyEnd > 0 ? bodyEnd : applyStart + 3000);
assertEq(/askConfirmCheck/.test(applyBody), true,
  '38-fix: applyMode 在 platform → manual/sniff 时用 askConfirmCheck 弹窗');
assertEq(/clrPull/.test(applyBody), true,
  '38-fix: applyMode 勾选确认后发 W:CLRPULL');

console.log('PASS: 38-fix platform 切 manual/sniff 弹窗 + W:CLRPULL + cfgstore.clear_pull');
