// test_2g3_reg_module.js
//
// 回归: 2g-3 拆 reg.js, 6 个 reg CRUD 函数从 app.js 移到 reg.js
// Bug 风险: 物理拆分可能漏函数 / 顺序错 / 语法错 / 加载顺序错
// 修:  reg.js 独立文件, 在 cfg.js 之后, app.js 之前加载
//
// 注: collectRegs() 和 badRegRow() 在 2g-2 时已被 cfg.js 带走
//     (它们跟 saveCfg 流程一起), 本测试不验这两个
//
// 测什么:
// 1. reg.js 文件存在 + 语法正确
// 2. 6 个 reg 函数都在 reg.js 里
// 3. 这 6 个函数都不在 app.js 里 (确认物理拆分)
// 4. index.html 加载顺序: protocol → mqtt → cfg → reg → app

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { assertTrue, assertContains } = require('./setup');

const ROOT = path.join(__dirname, '..', 'renderer');
const appJs = fs.readFileSync(path.join(ROOT, 'app.js'), 'utf8');
const regJs = fs.readFileSync(path.join(ROOT, 'reg.js'), 'utf8');
const indexHtml = fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8');

// ---- 1. reg.js 文件存在 + 语法正确 ----
assertTrue(fs.existsSync(path.join(ROOT, 'reg.js')), 'reg.js 文件存在');

const ctx = vm.createContext({});
try {
  vm.runInContext(regJs, ctx);
} catch (e) {
  throw new Error('reg.js 语法错: ' + e.message);
}

// ---- 2. 6 个 reg 函数都在 reg.js 里 ----
const regFunctions = [
  'renderRegTable',  // 渲染 reg 表
  'addRegRow',       // 加 reg 行
  'deleteRow',       // 删 reg 行
  'addParamRow',     // 弹窗里"新增"按钮
  'closeModal',      // 关弹窗
  'confirmAddReg',   // 弹窗里"确认新增"
];

for (const fn of regFunctions) {
  const re = new RegExp(`function\\s+${fn}\\s*\\(`);
  assertTrue(re.test(regJs), `reg.js 包含 ${fn}() 函数定义`);
}

// ---- 3. 这 6 个函数都不在 app.js 里 (物理拆分确认) ----
for (const fn of regFunctions) {
  const re = new RegExp(`^function\\s+${fn}\\s*\\(`, 'm');
  assertTrue(!re.test(appJs), `app.js 不应再有 ${fn}() 定义 (已搬到 reg.js)`);
}

// ---- 4. index.html 加载顺序: protocol → mqtt → cfg → reg → app ----
const protoIdx = indexHtml.indexOf('src="../protocol.js"');
const mqttIdx  = indexHtml.indexOf('src="mqtt.js"');
const cfgIdx   = indexHtml.indexOf('src="cfg.js"');
const regIdx   = indexHtml.indexOf('src="reg.js"');
const appIdx   = indexHtml.indexOf('src="app.js"');
assertTrue(protoIdx > 0, 'index.html 加载 protocol.js');
assertTrue(mqttIdx > 0,  'index.html 加载 mqtt.js');
assertTrue(cfgIdx > 0,   'index.html 加载 cfg.js');
assertTrue(regIdx > 0,   'index.html 加载 reg.js');
assertTrue(appIdx > 0,   'index.html 加载 app.js');
assertTrue(protoIdx < mqttIdx, 'protocol.js 在 mqtt.js 之前');
assertTrue(mqttIdx < cfgIdx,   'mqtt.js 在 cfg.js 之前');
assertTrue(cfgIdx < regIdx,    'cfg.js 在 reg.js 之前 (reg 调 cfg 的 cfgPrefix)');
assertTrue(regIdx < appIdx,    'reg.js 在 app.js 之前');

console.log('PASS: 2g-3 - reg.js 拆分完成, 6 函数都在, app.js 不再重复, 加载顺序正确');
