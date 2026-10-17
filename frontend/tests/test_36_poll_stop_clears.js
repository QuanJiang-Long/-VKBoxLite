// test_36_poll_stop_clears.js
//
// 36-fix: poll.stop() 必须清空 regs/lastCfg/interval
//
// 问题: 用户测试报告 - manual 档填点表 → 切 idle → 切 manual,
//   软件参数列表还显示刚才填的寄存器. 但设备 ds_poll 已经被 reset_user
//   清空了, R:REG 应该返回空.
//
// 根因: lua/bus/poll.lua 的 M.stop() 只设 running=false, 不清 regs/
//   lastCfg/interval. R:REG = poll.get_regs() 直接返回这个 poll 模块的
//   本地变量, 所以切 idle 后 R:REG 还能返回上次的 2 个寄存器. 前端
//   readCfgSilent 读到 2 个, 显示 2 个.
//
// 修复: M.stop() 末尾加 regs, interval, lastCfg = {}, cfg.POLL_INTERVAL_MS, nil
//   下次 M.start(src) 调 reload_cfg(curSlot) 会从 fskv 重新 load.

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const pollLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'poll.lua'), 'utf8');

// 找 M.stop 函数体
const stopStart = pollLua.indexOf('function M.stop()');
const stopEnd = pollLua.indexOf('\nfunction ', stopStart + 10);
assertEq(stopStart > 0 && stopEnd > 0, true, '能找到 M.stop 函数');
if (stopStart > 0 && stopEnd > 0) {
  const body = pollLua.substring(stopStart, stopEnd);
  // 36-fix: 末尾清空 regs/lastCfg/interval
  assertEq(/regs,\s*interval,\s*lastCfg\s*=\s*\{\},\s*cfg\.POLL_INTERVAL_MS\s*,\s*nil/.test(body), true,
    '36-fix: M.stop() 末尾清空 regs/interval/lastCfg (修切 idle 后 R:REG 还能返回旧寄存器)');
  // 仍然返回 true
  assertEq(/return\s+true/.test(body), true, 'M.stop() 仍然返回 true');
}

console.log('PASS: 36-fix poll.stop() 清空 regs/interval/lastCfg (切 idle 后 R:REG 返回空)');
