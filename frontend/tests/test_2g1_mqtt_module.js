// test_2g1_mqtt_module.js
//
// 回归: 2g-1 拆 mqtt.js, 14 个 mqtt 函数从 app.js 移到 mqtt.js
// Bug 风险: 物理拆分可能漏函数 / 顺序错 / 语法错 / 加载顺序错
// 修:  mqtt.js 独立文件, 在 index.html 里 protocol.js 之后, app.js 之前加载
//
// 测什么:
// 1. mqtt.js 文件存在 + 语法正确 (能 vm.runInContext 跑通)
// 2. 14 个 mqtt 函数都在 mqtt.js 里
// 3. 这 14 个函数都不在 app.js 里 (确认物理拆分)
// 4. index.html 里 mqtt.js 加载顺序正确 (protocol.js → mqtt.js → app.js)

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { assertTrue, assertContains, assertEq } = require('./setup');

const ROOT = path.join(__dirname, '..', 'renderer');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
const mqttJs = fs.readFileSync(path.join(ROOT, 'mqtt.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// ---- 1. mqtt.js 文件存在 + 语法正确 ----
assertTrue(fs.existsSync(path.join(ROOT, 'mqtt.js')), 'mqtt.js 文件存在');

// vm 跑一下, 没语法错
const ctx = vm.createContext({});
try {
  vm.runInContext(mqttJs, ctx);
} catch (e) {
  throw new Error('mqtt.js 语法错: ' + e.message);
}

// ---- 2. 14 个 mqtt 函数都在 mqtt.js 里 ----
const mqttFunctions = [
  'mqttPrefix',     // 取档位 prefix
  'mqSnap',         // 抓 mqtt 字段快照
  'snapMqClean',    // 设基线
  'refillManual',   // 开手动档时回填
  'setManualMode',  // 手动/平台档切换
  'refreshMqDirty', // dirty 提示
  'fillMqHome',     // 首页 mqtt 输入框回填
  'saveHomeMqtt',   // 首页 mqtt 保存
  'renderMqtt',     // 渲染 MQTT 配置面板
  'readMqtt',       // 读 mqtt 配置
  'saveMqtt',       // 保存 mqtt
  'reportNow',      // 立即上报
  'togglePassEye',  // 密码框小眼睛
  'mqttReconnect',  // 重连
];

for (const fn of mqttFunctions) {
  const re = new RegExp(`function\\s+${fn}\\s*\\(`);
  assertTrue(re.test(mqttJs), `mqtt.js 包含 ${fn}() 函数定义`);
}

// ---- 3. 这 14 个函数都不在 app.js 里 (物理拆分确认) ----
for (const fn of mqttFunctions) {
  const re = new RegExp(`^function\\s+${fn}\\s*\\(`, 'm');
  assertTrue(!re.test(appJs), `app.js 不应再有 ${fn}() 定义 (已搬到 mqtt.js)`);
}

// ---- 4. index.html 加载顺序: protocol.js → mqtt.js → app.js ----
const protoIdx = indexHtml.indexOf('src="../protocol.js"');
const mqttIdx  = indexHtml.indexOf('src="mqtt.js"');
const appIdx   = indexHtml.indexOf('src="app.js"');
assertTrue(protoIdx > 0, 'index.html 加载 protocol.js');
assertTrue(mqttIdx > 0,  'index.html 加载 mqtt.js');
assertTrue(appIdx > 0,   'index.html 加载 app.js');
assertTrue(protoIdx < mqttIdx, 'protocol.js 在 mqtt.js 之前加载');
assertTrue(mqttIdx < appIdx,   'mqtt.js 在 app.js 之前加载 (依赖 mqtt 函数在 app.js 用)');

console.log('PASS: 2g-1 - mqtt.js 拆分完成, 14 函数都在, app.js 不再重复, 加载顺序正确');
