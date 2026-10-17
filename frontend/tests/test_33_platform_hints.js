// test_33_platform_hints.js
//
// 33-fix: 撤掉 applyMode 切到 platform 前的 MQTT 拦截弹窗, 改为 platform 面板
//   顶部两个横条提示:
//   1. pMqttHint: MQTT 未连接时显示, 「知道了」关闭, 切到 tabPlatform 时重置
//   2. pPullOkHint: waitPullDone 拉取成功时显示, 「知道了」关闭, 一次性
//
// 改动:
//   - index.html: platform 面板新增 2 个 div (pMqttHint / pPullOkHint)
//   - index.html: 新增 2 个 CSS 类 (push-banner-ok / push-banner-warn)
//   - app.js: 删掉 applyMode 中的弹窗拦截
//   - app.js: 新增 renderPlatformHints()
//   - app.js: S 上新增 3 个状态字段
//   - app.js: el 上新增 5 个 DOM 引用
//   - app.js: 2 个「知道了」按钮的 onclick
//   - app.js: waitPullDone 成功时设置 platformPullOkPending
//   - app.js: renderHome 末尾调用 renderPlatformHints
//   - app.js: activateTab(tabPlatform) 时重置 mqttHintDismissed
//   - app.js: applyMode 切到非 platform 档时重置 3 个字段

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const indexHtml = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const appJs     = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// === HTML: 横条元素 ===

// 测 1: pMqttHint 存在 + push-banner-warn 类
assertEq(/id="pMqttHint"\s+class="push-banner push-banner-warn"/.test(indexHtml), true,
  'pMqttHint 元素存在 + 类名正确');

// 测 2: pMqttHint 包含文字 + 知道了按钮
assertEq(/id="pMqttHintText"[^>]*>MQTT 未连接, 无法拉取配置/.test(indexHtml), true,
  'pMqttHintText 文字正确');
assertEq(/id="pBtnMqttHintIgnore"[^>]*>知道了/.test(indexHtml), true,
  'pBtnMqttHintIgnore 知道了按钮存在');

// 测 3: pPullOkHint 存在 + push-banner-ok 类
assertEq(/id="pPullOkHint"\s+class="push-banner push-banner-ok"/.test(indexHtml), true,
  'pPullOkHint 元素存在 + 类名正确');
assertEq(/id="pPullOkHintText"[^>]*>已从平台拉取配置/.test(indexHtml), true,
  'pPullOkHintText 文字正确');
assertEq(/id="pBtnPullOkIgnore"[^>]*>知道了/.test(indexHtml), true,
  'pBtnPullOkIgnore 知道了按钮存在');

// 测 4: CSS 样式存在
assertEq(/\.push-banner\.push-banner-ok\{background:#ecf7ee/.test(indexHtml), true,
  'CSS push-banner-ok 样式存在');
assertEq(/\.push-banner\.push-banner-warn\{background:#fdf6ec/.test(indexHtml), true,
  'CSS push-banner-warn 样式存在');

// === app.js: 撤掉弹窗 ===

// 测 5: applyMode 中不再有 25-fix 的 "切到 platform 前预检 MQTT" 弹窗拦截
//   注: applyMode 里还有另一个 askConfirm (platform → manual 切档提示, line 755-759),
//   那个是另外的拦截, 不能撤. 只检查 25-fix 的 MQTT 预检部分
const applyModeMatch = appJs.match(/async function applyMode\(mode\)\s*\{[\s\S]+?\n\}/);
assertEq(!!applyModeMatch, true, '能找到 applyMode 函数');
if (applyModeMatch) {
  // 排除注释行 (以 // 开头, 排除行内 //)
  const body = applyModeMatch[0].split('\n').filter(l => !/^\s*\/\//.test(l)).join('\n');
  // 不再有 25-fix 的 "isPlatform(mode) && (!S.mqtt || ...) MQTT 未连接" 拦截块
  assertEq(/isPlatform\(mode\)\s*&&\s*\(\s*!S\.mqtt\s*\|\|/.test(body), false,
    'applyMode 中不再有 25-fix 的 "isPlatform && !S.mqtt" 拦截条件 (排除注释)');
  // 33-fix 注释应在 (说明撤掉了什么)
  const withComments = applyModeMatch[0];
  assertEq(/33-fix.*撤掉/.test(withComments), true,
    'applyMode 中有 33-fix 撤掉弹窗的说明性注释');
}

// === app.js: S 状态字段 ===

// 测 6: S 上有 3 个新字段
assertEq(/platformMqttHintDismissed:\s*false/.test(appJs), true,
  'S.platformMqttHintDismissed 字段存在');
assertEq(/platformPullOkHintDismissed:\s*false/.test(appJs), true,
  'S.platformPullOkHintDismissed 字段存在');
assertEq(/platformPullOkPending/.test(appJs), true,
  'S.platformPullOkPending 字段被使用');

// === app.js: renderPlatformHints 函数 ===

// 测 7: 函数定义存在
assertEq(/function renderPlatformHints\(\)/.test(appJs), true,
  'renderPlatformHints 函数定义存在');

// 测 8: 函数体关键逻辑
const rphMatch = appJs.match(/function renderPlatformHints\(\)\s*\{[\s\S]+?\n\}/);
assertEq(!!rphMatch, true, '能找到 renderPlatformHints 函数体');
if (rphMatch) {
  const body = rphMatch[0];
  // 包含 isPlatform 判定
  assertEq(/isPlatform\(S\.mode\)/.test(body), true, '包含 isPlatform 判定');
  // 包含 mqtt.connected 判定
  assertEq(/mq\.connected|connected/.test(body), true, '包含 mqtt.connected 判定');
  // 包含 tabPlatform active 判定
  assertEq(/tabPlatform.*active|active.*tabPlatform/.test(body), true, '包含 tabPlatform active 判定');
  // 包含两个 .hidden 切换 (mqttBox.hidden 和 pullOkBox.hidden)
  const hiddenSets = body.match(/Box\.hidden\s*=\s*!/g) || [];
  assertEq(hiddenSets.length >= 2, true, '两个 Box.hidden 切换 (mqttBox + pullOkBox)');
}

// === app.js: el 引用 ===

// 测 9: 5 个新 el 引用
assertEq(/pMqttHint:\s*\$\('pMqttHint'\)/.test(appJs), true, 'el.pMqttHint 引用');
assertEq(/pBtnMqttHintIgnore:\s*\$\('pBtnMqttHintIgnore'\)/.test(appJs), true, 'el.pBtnMqttHintIgnore 引用');
assertEq(/pPullOkHint:\s*\$\('pPullOkHint'\)/.test(appJs), true, 'el.pPullOkHint 引用');
assertEq(/pBtnPullOkIgnore:\s*\$\('pBtnPullOkIgnore'\)/.test(appJs), true, 'el.pBtnPullOkIgnore 引用');

// === app.js: 知道了按钮 onclick ===

// 测 10: 两个 onclick 绑定
assertEq(/pBtnMqttHintIgnore\.onclick[\s\S]{0,150}platformMqttHintDismissed\s*=\s*true/.test(appJs), true,
  'pBtnMqttHintIgnore.onclick 设置 platformMqttHintDismissed=true');
assertEq(/pBtnPullOkIgnore\.onclick[\s\S]{0,150}platformPullOkHintDismissed\s*=\s*true/.test(appJs), true,
  'pBtnPullOkIgnore.onclick 设置 platformPullOkHintDismissed=true');

// === app.js: waitPullDone 拉取成功设置 pending ===

// 测 11: waitPullDone 中 polling 起来时设置 platformPullOkPending
const waitPullMatch = appJs.match(/async function waitPullDone\(\)\s*\{[\s\S]+?return true;[\s\S]+?\}/);
assertEq(!!waitPullMatch, true, '能找到 waitPullDone 函数');
if (waitPullMatch) {
  const body = waitPullMatch[0];
  // 在 polling 起来的分支里有 platformPullOkPending = true
  const pollingBranch = body.match(/if \(polling\)[\s\S]+?return true;/);
  assertEq(!!pollingBranch, true, '能找到 polling 分支');
  if (pollingBranch) {
    assertEq(/platformPullOkPending\s*=\s*true/.test(pollingBranch[0]), true,
      'polling 起来时设置 platformPullOkPending=true');
    assertEq(/renderPlatformHints\(\)/.test(pollingBranch[0]), true,
      'polling 起来时调用 renderPlatformHints');
  }
}

// === app.js: renderHome 末尾调用 renderPlatformHints ===

// 测 12: renderHome 末尾有 renderPlatformHints
const renderHomeMatch = appJs.match(/function renderHome\(\)\s*\{[\s\S]+?\n\}/);
assertEq(!!renderHomeMatch, true, '能找到 renderHome 函数');
if (renderHomeMatch) {
  // 末尾是 renderPlatformHints() (在 renderPushBanner 之后)
  assertEq(/renderPlatformHints\(\);?\s*\}?\s*$/.test(renderHomeMatch[0]), true,
    'renderHome 末尾调用 renderPlatformHints');
}

// === app.js: activateTab 重置 mqttHintDismissed ===

// 测 13: 切到 tabPlatform 时重置 mqttHintDismissed
const activateTabMatch = appJs.match(/function activateTab\(tabId\)\s*\{[\s\S]+?\n\}/);
assertEq(!!activateTabMatch, true, '能找到 activateTab 函数');
if (activateTabMatch) {
  const body = activateTabMatch[0];
  assertEq(/tabId === 'tabPlatform'[\s\S]{0,200}platformMqttHintDismissed\s*=\s*false/.test(body), true,
    'activateTab(tabPlatform) 重置 platformMqttHintDismissed');
}

// === app.js: applyMode 切到非 platform 重置 3 字段 ===

// 测 14: applyMode 切到非 platform 档时重置
if (applyModeMatch) {
  const body = applyModeMatch[0];
  assertEq(/!isPlatform\(mode\)[\s\S]{0,300}platformMqttHintDismissed\s*=\s*false[\s\S]{0,150}platformPullOkHintDismissed\s*=\s*false[\s\S]{0,150}platformPullOkPending\s*=\s*false/.test(body), true,
    'applyMode 切到非 platform 档时重置 3 个字段');
}

console.log('PASS: 33-fix - platform 档 2 个提示横幅 + 撤掉 MQTT 拦截弹窗 (14 个测试点通过)');
