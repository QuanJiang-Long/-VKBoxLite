// test_sniff1_remove_diag.js
//
// sniff-1: 删除 sniff 面板的 "总线诊断" 卡片
//   - 前端: index.html / app.js / protocol.js 删掉相关 UI 和命令
//   - 设备: cmd.lua / mon.lua / poll.lua / README.md 删掉 R:SNIFF / W:TX 协议
//
// 验证:
//   1. 前端 HTML 不再有 "总线诊断" 标题 / btnBusSniff / busSniffMs / txHex / btnTx
//   2. 前端 app.js 不再有 el 绑定 / busSniff() / txHex() / onclick / W:TX= mock 回执
//   3. 前端 protocol.js 不再有 sniffBus / txHex
//   4. 设备 cmd.lua 不再有 R:SNIFF / W:TX
//   5. 设备 mon.lua 不再有 sniff_count
//   6. 设备 poll.lua 不再有 tx_raw
//   7. 设备 README.md 不再有 R:SNIFF / W:TX 文档

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs     = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const protocolJs = fs.readFileSync(path.join(__dirname, '..', 'protocol.js'), 'utf8');
const cmdLua    = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'svc', 'cmd.lua'), 'utf8');
const monLua    = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'mon.lua'), 'utf8');
const pollLua   = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'poll.lua'), 'utf8');
const readmeMd  = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'README.md'), 'utf8');

// 测 1: HTML 不再有 "总线诊断" / btnBusSniff / busSniffMs / txHex / btnTx
assertEq(indexHtml.indexOf('总线诊断') < 0, true, 'index.html 不再有 "总线诊断"');
assertEq(indexHtml.indexOf('btnBusSniff') < 0, true, 'index.html 不再有 btnBusSniff');
assertEq(indexHtml.indexOf('busSniffMs') < 0, true, 'index.html 不再有 busSniffMs');
assertEq(indexHtml.indexOf('txHex') < 0, true, 'index.html 不再有 txHex');
assertEq(indexHtml.indexOf('btnTx') < 0, true, 'index.html 不再有 btnTx');
assertEq(indexHtml.indexOf('静默侦听总线') < 0, true, 'index.html 不再有 "静默侦听总线"');
assertEq(indexHtml.indexOf('手动发帧') < 0, true, 'index.html 不再有 "手动发帧"');

// 测 2: app.js 清理
assertEq(appJs.indexOf('btnBusSniff') < 0, true, 'app.js 不再有 btnBusSniff');
assertEq(appJs.indexOf('busSniffMs') < 0, true, 'app.js 不再有 busSniffMs');
assertEq(appJs.indexOf('txHex') < 0, true, 'app.js 不再有 txHex');
assertEq(appJs.indexOf('btnTx') < 0, true, 'app.js 不再有 btnTx');
assertEq(appJs.indexOf('busSniff()') < 0, true, 'app.js 不再有 busSniff() 函数');
assertEq(appJs.indexOf('txHex()') < 0, true, 'app.js 不再有 txHex() 函数');
// mock 模式也不再有 W:TX= 回执
assertEq(appJs.indexOf("'W:TX='") < 0 && appJs.indexOf('"W:TX="') < 0, true,
  'app.js mock 模式不再有 W:TX= 回执');
assertEq(appJs.indexOf("'R:SNIFF='") < 0 && appJs.indexOf('"R:SNIFF="') < 0, true,
  'app.js mock 模式不再有 R:SNIFF= 回执');

// 测 3: protocol.js 清理
assertEq(protocolJs.indexOf('sniffBus') < 0, true, 'protocol.js 不再有 sniffBus');
// 协议层只用 R:SNIFF= / W:TX= (前端的"txHex"是函数名)
// 不检查 protocol.js 里 "txHex" (它作为函数名已删), 但要查 R:SNIFF 和 W:TX=
assertEq(protocolJs.indexOf('R:SNIFF=') < 0, true, 'protocol.js 不再有 R:SNIFF=');
assertEq(protocolJs.indexOf('W:TX=') < 0, true, 'protocol.js 不再有 W:TX=');

// 测 4: cmd.lua 清理
//   用单词边界 R:SNIFF= (等号, 避免匹配 R:SNIFFCFG)
assertEq(cmdLua.indexOf('R:SNIFF=') < 0, true, 'cmd.lua 不再有 R:SNIFF');
assertEq(cmdLua.indexOf('sniff_count') < 0, true, 'cmd.lua 不再调 sniff_count');
assertEq(cmdLua.indexOf('W:TX=') < 0, true, 'cmd.lua 不再有 W:TX= 协议注册');
assertEq(cmdLua.indexOf('tx_raw') < 0, true, 'cmd.lua 不再调 tx_raw');

// 测 5: mon.lua 清理
assertEq(monLua.indexOf('sniff_count') < 0, true, 'mon.lua 不再有 sniff_count 函数');

// 测 6: poll.lua 清理
assertEq(pollLua.indexOf('tx_raw') < 0, true, 'poll.lua 不再有 tx_raw 函数');

// 测 7: README.md 清理
//   R:SNIFF= (静默侦听, sniff-1 删的) vs R:SNIFFCFG (sniff 配置, 不要动)
//   W:TX= (裸发, sniff-1 删的) vs W:TX? (协议说明里可能出现的) - 用 W:TX= 加边界
assertEq(readmeMd.indexOf('R:SNIFF=') < 0, true, 'README.md 不再有 R:SNIFF= 文档');
assertEq(readmeMd.indexOf('W:TX=') < 0, true, 'README.md 不再有 W:TX= 文档');

console.log('PASS: sniff-1 - 总线诊断卡片完整删除 (前端 3 文件 + 设备 4 文件, 7 个分类 25 个测试点通过)');
