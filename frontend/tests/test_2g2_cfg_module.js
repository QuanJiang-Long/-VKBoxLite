// test_2g2_cfg_module.js
//
// 回归: 2g-2 拆 cfg.js, 15 个 cfg 函数从 app.js 移到 cfg.js
// Bug 风险: 物理拆分可能漏函数 / 顺序错 / 语法错 / 加载顺序错
// 修:  cfg.js 独立文件, 在 index.html 里 mqtt.js 之后, app.js 之前加载
//
// 测什么:
// 1. cfg.js 文件存在 + 语法正确
// 2. 15 个 cfg 函数都在 cfg.js 里
// 3. 这 15 个函数都不在 app.js 里 (确认物理拆分)
// 4. index.html 里 cfg.js 加载顺序正确 (protocol → mqtt → cfg → app)

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { assertTrue, assertContains } = require('./setup');

const ROOT = path.join(__dirname, '..', 'renderer');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
const cfgJs = fs.readFileSync(path.join(ROOT, 'cfg.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// ---- 1. cfg.js 文件存在 + 语法正确 ----
assertTrue(fs.existsSync(path.join(ROOT, 'cfg.js')), 'cfg.js 文件存在');

const ctx = vm.createContext({});
try {
  vm.runInContext(cfgJs, ctx);
} catch (e) {
  throw new Error('cfg.js 语法错: ' + e.message);
}

// ---- 2. 15 个 cfg 函数都在 cfg.js 里 ----
const cfgFunctions = [
  'cfgPrefix',            // 走档位 (485/reg 段)
  'cfgSnap',              // 抓 485+reg 快照
  'snapClean',            // 设 485+reg 基线
  'refreshCfgDirty',      // dirty 提示
  'guardUnsaved',         // 整份覆盖前守卫
  'renderCfgSrcHint',     // cfg 源提示
  'setFormLocked',        // 锁档
  'readCfg',              // 读 485 cfg
  'readCfgSilent',        // 静默读
  'pullCfg',              // 拉取
  'fillFormFromPlatform', // 平台填表单
  'collectCfg',           // 收 485 字段
  'cfgErr',               // cfg 错码转人话
  'saveCfg',              // 保存 485
  'readVal',              // 读实时值
];

for (const fn of cfgFunctions) {
  const re = new RegExp(`function\\s+${fn}\\s*\\(`);
  assertTrue(re.test(cfgJs), `cfg.js 包含 ${fn}() 函数定义`);
}

// ---- 3. 这 15 个函数都不在 app.js 里 (物理拆分确认) ----
for (const fn of cfgFunctions) {
  const re = new RegExp(`^function\\s+${fn}\\s*\\(`, 'm');
  assertTrue(!re.test(appJs), `app.js 不应再有 ${fn}() 定义 (已搬到 cfg.js)`);
}

// ---- 4. index.html 加载顺序: protocol → mqtt → cfg → app ----
const protoIdx = indexHtml.indexOf('src="../protocol.js"');
const mqttIdx  = indexHtml.indexOf('src="mqtt.js"');
const cfgIdx   = indexHtml.indexOf('src="cfg.js"');
const appIdx   = indexHtml.indexOf('src="app.js"');
assertTrue(protoIdx > 0, 'index.html 加载 protocol.js');
assertTrue(mqttIdx > 0,  'index.html 加载 mqtt.js');
assertTrue(cfgIdx > 0,   'index.html 加载 cfg.js');
assertTrue(appIdx > 0,   'index.html 加载 app.js');
assertTrue(protoIdx < mqttIdx, 'protocol.js 在 mqtt.js 之前');
assertTrue(mqttIdx < cfgIdx,   'mqtt.js 在 cfg.js 之前 (cfg 调 mqtt 跨文件)');
assertTrue(cfgIdx < appIdx,    'cfg.js 在 app.js 之前');

console.log('PASS: 2g-2 - cfg.js 拆分完成, 15 函数都在, app.js 不再重复, 加载顺序正确');
