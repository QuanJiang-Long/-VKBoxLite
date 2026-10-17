// test_sniff2_stop_quick.js
//
// sniff-2 fix: mon.stop() 必须立刻停掉后台 auto_detect, 不让 sys.wait(2000)
//   闷头跑完剩余 baud, 还要 uart.close 防止后续 uart.setup 改 UART 寄存器
//
// 用户实测日志 (16:07):
//   - 16:07:35.964 W:MODE=idle -> 16:07:35.965 mon.stop() 设 running=false
//   - 但 auto_detect 正在某个 sys.wait(2000) 中, 醒来后还调 uart.setup
//     改分频 (16:07:36.780 Uart_ChangeBR), 破坏 mon.stop 已关闭的
//     uart.on("receive", nil) 效果
//   - 16:07:38.815 还在打 "check baud=9600..." 日志, 证明 auto_detect
//     主循环仍在跑
//
// 修复:
//   1. mon.stop() 立刻设 forceStop=true
//   2. mon.stop() 立刻 pcall(uart.close, mbus.UART_ID) 防止后续 uart.setup
//   3. auto_detect / detect_loop 用 sniff_wait 替代 sys.wait, 每 20ms 醒
//      来 check forceStop, 切档时最迟 20ms 内退出
//   4. mon.start() / auto_detect 入口清 forceStop, 否则再进 sniff 立即退

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const monLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'mon.lua'), 'utf8');

// 1. forceStop 标志存在
assertEq(/local\s+forceStop\s*=\s*false/.test(monLua), true,
  'sniff-2: mon.lua 加了 forceStop 局部变量');

// 2. sniff_wait 函数存在 (替代 sys.wait, 带 forceStop 检查)
const waitStart = monLua.indexOf('local function sniff_wait');
assertEq(waitStart > 0, true, 'sniff-2: sniff_wait() 函数存在 (替代 sys.wait)');
if (waitStart > 0) {
  const waitEnd = monLua.indexOf('\nend', waitStart + 50);
  const waitBody = monLua.substring(waitStart, waitEnd + 5);
  assertEq(/forceStop/.test(waitBody), true,
    'sniff-2: sniff_wait() 检查 forceStop, 每 20ms 醒来能立即退出');
}

// 3. mon.stop 设 forceStop + uart.close
const stopStart = monLua.indexOf('function M.stop()');
// 找下一个 "function M." 开头作为 body 终点
let stopEnd = -1;
for (let off = stopStart + 50; off < monLua.length; off++) {
  if (monLua[off] === '\n' && /^\s*(function M\.|--?)/.test(monLua.substring(off + 1, off + 20))) {
    // 找最近的 "function M." 或注释行
  }
  if (monLua[off] === '\n' && /^function M\./.test(monLua.substring(off + 1, off + 20))) {
    stopEnd = off;
    break;
  }
}
const stopBody = monLua.substring(stopStart, stopEnd > 0 ? stopEnd : stopStart + 600);
assertEq(/forceStop\s*=\s*true/.test(stopBody), true,
  'sniff-2: mon.stop() 设 forceStop=true (立刻让 auto_detect 退出)');
assertEq(/uart\.close\s*,\s*mbus\.UART_ID/.test(stopBody), true,
  'sniff-2: mon.stop() 立刻 pcall(uart.close) 防止后续 uart.setup 改分频');

// 4. mon.start / auto_detect 入口清 forceStop
const startFn = monLua.indexOf('function M.start(');
const startBody = monLua.substring(startFn, monLua.indexOf('\nend', startFn + 200));
assertEq(/forceStop\s*=\s*false/.test(startBody), true,
  'sniff-2: mon.start() 入口清 forceStop (避免再进 sniff 立即退)');

const adFn = monLua.indexOf('function M.auto_detect()');
const adBody = monLua.substring(adFn, monLua.indexOf('\nend', adFn + 1000));
assertEq(/forceStop\s*=\s*false/.test(adBody), true,
  'sniff-2: auto_detect() 入口也清 forceStop (detect_loop 复用 auto_detect)');

// 5. auto_detect 不再用 sys.wait (改 sniff_wait)
assertEq(/sys\.wait\(5000\)/.test(adBody), false,
  'sniff-2: auto_detect 不再用 sys.wait(5000) 改 sniff_wait (5s 等 UART 稳定)');
assertEq(/sys\.wait\(500\)/.test(adBody), false,
  'sniff-2: auto_detect 不再用 sys.wait(500) 改 sniff_wait (切 baud 复位)');

// 6. detect_loop 也用 sniff_wait
const loopFn = monLua.indexOf('local function detect_loop');
const loopBody = monLua.substring(loopFn, monLua.indexOf('\nend', loopFn + 500));
assertEq(/sniff_wait\(DETECT_RETRY_MS\)/.test(loopBody), true,
  'sniff-2: detect_loop 用 sniff_wait 替代 sys.wait (retry 间隔)');

// 7. 前端: applyMode 切 sniff 后, pollDetect 返 null 时检查 mode, 用户已
//   切走 (mode != sniff) 就不弹"识别未完成"toast
const appJs2 = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const applyStart2 = appJs2.indexOf('async function applyMode');
// 找 pollDetect 那一段
const pollDetectStart = appJs2.indexOf('const d = await pollDetect(25)');
if (pollDetectStart > 0) {
  // 取往后 30 行
  const chunk = appJs2.substring(pollDetectStart, pollDetectStart + 800);
  assertEq(/S\.mode\s*===\s*['"]sniff['"]/.test(chunk), true,
    'sniff-2: applyMode 弹"识别未完成"toast 前 check mode 是不是 sniff (用户已切走不弹)');
}

console.log('PASS: sniff-2 mon.stop 立刻停 auto_detect (forceStop + uart.close + sniff_wait) + applyMode 切走不弹误提示');
