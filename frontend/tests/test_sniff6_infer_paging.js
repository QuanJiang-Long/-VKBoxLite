// test_sniff6_infer_paging.js
//
// 12-fix-9: 推断表【分页】
//
// 背景 (现场 2026-10-29 09:14~09:19, SN VL20261019001):
//   64 个地址时整表应答是 8158 字节的 JSON, 而那会儿 Lua 池已经
//   294448/307192 = 95.8% → "alloc 8147 failed" → json encode out of
//   memory → RET:INFER={} → 系统池也见底 →
//   "E/uart system is out of memory!!!" → 整机卡死(09:19:03 + ramdump)。
//
// 所以:
//   设备端: R:INFER=off,n 只回一页(最多 32 行), 主动推送也推当前页
//   前端:   按页取 + 显示页码, 序号用全局下标(off+i+1)
//   名字:   12-fix-9 起名字挂顶层 names 表(行一个字段都不加)
//
// 本测试钉住这几条:
//   1. protocol.js 的 infer 编码带 off,n
//   2. index.html 有翻页控件(上一页/下一页/页码), 且在推断表之后
//   3. app.js 按页取: Protocol.Enc.infer(off, size)
//   4. app.js 序号用全局下标 off+i+1 (不是每页从 1 开始)
//   5. app.js 名字走 names 表, 查不到退回 reg<addr>
//   6. app.js 翻页按钮有绑定, 复位时页码归 1
//   7. 设备端: mon 有分页接口, cmd 解析 off,n, 一次最多 32 行

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const protoJs = fs.readFileSync(path.join(__dirname, '..', 'protocol.js'), 'utf8');
const repo = path.join(__dirname, '..', '..');
const monLua = fs.readFileSync(path.join(repo, 'lua', 'bus', 'mon.lua'), 'utf8');
const cmdLua = fs.readFileSync(path.join(repo, 'lua', 'svc', 'cmd.lua'), 'utf8');

// sniff 嗅探 panel 范围
const sniffStart = html.indexOf('id="tabSniff"');
const sniffEnd = html.indexOf('MQTT连接', sniffStart);
const sniffBody = html.substring(sniffStart, sniffEnd);

// === 1. protocol.js: infer 带 off,n ===
assertEq(/infer:\s*\(off,\s*n\)\s*=>/.test(protoJs), true,
  'sniff-6: protocol.js 的 Enc.infer 收 (off, n)');
assertEq(/'R:INFER'\s*\+/.test(protoJs), true,
  'sniff-6: Enc.infer 拼的是 R:INFER=off,n');

// === 2. index.html: 翻页控件 ===
assertEq(/id="inferPager"/.test(sniffBody), true,
  'sniff-6: 翻页容器 inferPager 在 sniff 面板内');
assertEq(/id="btnInferPrev"/.test(sniffBody), true,
  'sniff-6: 上一页按钮 btnInferPrev 在 sniff 面板内');
assertEq(/id="btnInferNext"/.test(sniffBody), true,
  'sniff-6: 下一页按钮 btnInferNext 在 sniff 面板内');
assertEq(/id="inferPageInfo"/.test(sniffBody), true,
  'sniff-6: 页码信息 inferPageInfo 在 sniff 面板内');
assertEq(/上一页/.test(sniffBody) && /下一页/.test(sniffBody), true,
  'sniff-6: 翻页按钮上有中文标签');
// 控件在表格之后
const tbodyIdx = sniffBody.indexOf('id="inferTbody"');
const pagerIdx = sniffBody.indexOf('id="inferPager"');
assertEq(tbodyIdx > 0 && pagerIdx > tbodyIdx, true,
  'sniff-6: 翻页控件在推断表之后 (DOM 顺序)');

// === 3. app.js: 按页取 ===
assertEq(/Protocol\.Enc\.infer\(off,\s*size\)/.test(appJs), true,
  'sniff-6: 前端按页取 (Enc.infer(off, size))');
assertEq(/inferPageSize:\s*32/.test(appJs), true,
  'sniff-6: 每页行数 32 (跟设备硬上限一致)');
assertEq(/async function fetchInferPage/.test(appJs), true,
  'sniff-6: 有 fetchInferPage');
assertEq(/async function gotoInferPage/.test(appJs), true,
  'sniff-6: 有 gotoInferPage (翻页)');

// === 4. app.js: 序号用全局下标 ===
assertEq(/\(off \+ i \+ 1\)/.test(appJs), true,
  'sniff-6: 序号 = 全局下标 (off + i + 1), 不是每页从 1 开始');

// === 5. app.js: 名字走 names 表 ===
assertEq(/S\.inferNames\[akey\]/.test(appJs), true,
  'sniff-6: 显示名字时查 names 表');
assertEq(/nm && nm\.id/.test(appJs) && /nm && nm\.name/.test(appJs), true,
  'sniff-6: names 表里取 id/name, 查不到退回 reg<addr>');
assertEq(/Object\.assign\(S\.inferNames/.test(appJs), true,
  'sniff-6: 名字表跨页累积 (每页只带自己那页的)');

// === 6. app.js: 按钮绑定 + 复位 ===
assertEq(/el\.btnInferPrev\.onclick/.test(appJs), true,
  'sniff-6: 上一页按钮有绑定');
assertEq(/el\.btnInferNext\.onclick/.test(appJs), true,
  'sniff-6: 下一页按钮有绑定');
assertEq(/S\.inferPage = 1;/.test(appJs), true,
  'sniff-6: 复位时页码归 1');

// === 7. 设备端 ===
assertEq(/local INFER_PAGE_MAX = 32/.test(monLua), true,
  'sniff-6: mon.lua 一次最多 32 行 (INFER_PAGE_MAX)');
assertEq(/function M\.infer_page/.test(monLua), true,
  'sniff-6: mon.lua 有 infer_page(off, n)');
assertEq(/function M\.set_infer_view/.test(monLua), true,
  'sniff-6: mon.lua 记住前端在看哪一页');
assertEq(/mon\.set_infer_view\(off,\s*n\)/.test(cmdLua), true,
  'sniff-6: cmd.lua 收到 R:INFER=off,n 后记住视图');
assertEq(/arg:match\("\^\(%d\*\)%s\*,%s\*\(%d\*\)"\)/.test(cmdLua), true,
  'sniff-6: cmd.lua 解析 off,n');
assertEq(/reply_big\("RET:INFER="/.test(cmdLua), true,
  'sniff-6: cmd.lua 用 reply_big 发大应答 (省一次拷贝)');

console.log('PASS: sniff-6 推断表分页 (设备一页 32 行 / 前端按页取+页码 / 序号全局 / 名字走 names 表)');
