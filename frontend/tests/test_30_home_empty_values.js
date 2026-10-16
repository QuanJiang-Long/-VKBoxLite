// test_30_home_empty_values.js
//
// 30-fix: 串口未连接时, 首页 "状态总览" 4 个字段显示 "--" (而不是假值)
//
// 修前 (S.modeStat/S.stat/S.mqtt.stat 都是空 {}):
//   hMode   = 'idle'        (默认)  ← 看起来像真值
//   hMqtt   = '未连接'      (默认)  ← 看起来像真值
//   hWdt    = '未启用'      (默认)  ← 看起来像真值
//   stMqtt  = '未连接'      (默认)  ← 看起来像真值
//
// 修后:
//   hMode   = '--'    (没有 st.mode)
//   hMqtt   = '--'    (mq.connected == null)
//   hWdt    = '--'    (g.wdt_to == null)
//   stMqtt  = '--'    (mq.connected == null)
//
// 但有应答时仍然正常显示:
//   hMqtt = '已连接' (绿) / '未连接' (红)
//   hMode = 'manual' / 'platform' 等
//   hWdt  = '未启用' (wdt_to=0) / '正常' / '停滞!'

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'app.js'),
  'utf8'
);

const renderHomeFn = appJs.match(/function renderHome\(\)[\s\S]+?^}/m);
assertEq(!!renderHomeFn, true, '能找到 renderHome 函数');
if (renderHomeFn) {
  const body = renderHomeFn[0];

  // 测 1: hMode - 删掉了 "|| 'idle'" 默认值, 改成 '?'
  // 旧的: setKv('hMode', (st.mode || 'idle') + ...)
  // 新的: setKv('hMode', st.mode ? (...) : '--')
  assertEq(/setKv\('hMode',\s*st\.mode\s*\?/.test(body), true,
    'hMode 改成 st.mode ? ... : "--" 形式');
  // 排除注释行 (// 开头), 检查代码中不再用默认 'idle'
  const codeOnly = body.split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n');
  const hasIdleDefault = /st\.mode\s*\|\|\s*['"]idle['"]/.test(codeOnly);
  assertEq(hasIdleDefault, false, 'renderHome 代码 (排除注释) 不用 st.mode || "idle"');

  // 测 2: hMqtt - mq.connected == null 时显示 "--"
  // 旧的: setKv('hMqtt', mq.connected ? '已连接' : '未连接', !mq.connected);
  // 新的: setKv('hMqtt', mq.connected == null ? '--' : (mq.connected ? '已连接' : '未连接'), mq.connected === false);
  assertEq(/mq\.connected\s*==\s*null\s*\?\s*['"]--['"]/.test(body), true,
    'hMqtt mq.connected == null 时显示 "--"');
  assertEq(/mq\.connected\s*===\s*false/.test(body), true,
    'hMqtt red 标记用 === false (不是 !connected)');

  // 测 3: hWdt - g.wdt_to == null 时显示 "--"
  assertEq(/g\.wdt_to\s*==\s*null\s*\?\s*['"]--['"]/.test(body), true,
    'hWdt g.wdt_to == null 时显示 "--"');

  // 测 4: 顶栏 stMqtt 也改
  // 旧的: el.stMqtt.textContent = mq.connected ? '已连接' : '未连接';
  // 新的: el.stMqtt.textContent = mq.connected == null ? '--' : (mq.connected ? '已连接' : '未连接');
  assertEq(/el\.stMqtt\.textContent\s*=\s*mq\.connected\s*==\s*null/.test(body), true,
    'stMqtt 没应答时也显示 "--"');

  // 测 5: 30-fix 注释存在
  assertEq(body.indexOf('30-fix') >= 0, true, 'renderHome 包含 30-fix 注释');
}

console.log('PASS: 30-fix - 串口未连接时 4 个字段显示 "--" (5 个测试点通过)');
