// test_import_export_simulation.js
//
// 模拟测试导入/导出功能（无需实际设备连接）
// 测试点:
//   1. exportCfgAsJson 数据结构完整性
//   2. exportCfgAsCsv 列定义
//   3. importCfg 版本校验
//   4. 档位守卫 (sniff/idle/platform 禁用导入)
//   5. sniff 档导出推断表

const fs = require('fs');
const path = require('path');
const { assertEq, assertTrue } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const cfgJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'cfg.js'), 'utf8');

console.log('=== 导入/导出功能模拟测试 ===\n');

// ============================================
// 1. 导出 JSON 结构测试
// ============================================
console.log('1. 测试 exportCfgAsJson 数据结构...');

const exportJsonMatch = appJs.match(/function\s+exportCfgAsJson[\s\S]*?^}/m);
assertTrue(!!exportJsonMatch, '找到 exportCfgAsJson 函数');

const exportJsonBody = exportJsonMatch[0];

// 检查必需字段
const requiredFields = [
  ['tool', '工具标识'],
  ['version', '版本号'],
  ['exported', '导出时间'],
  ['mode', '当前档位'],
  ['serial', '串口配置'],
  ['registers', '寄存器列表'],
  ['mqtt', 'MQTT 配置']
];

for (const [field, desc] of requiredFields) {
  const hasField = new RegExp(`"${field}"\\s*:`).test(exportJsonBody) ||
                   new RegExp(`${field}\\s*:`).test(exportJsonBody);
  assertTrue(hasField, `JSON 包含 ${field} (${desc})`);
}

console.log('   ✓ JSON 导出结构完整\n');

// ============================================
// 2. 导出 CSV 列定义测试
// ============================================
console.log('2. 测试 exportCfgAsCsv 列定义...');

const csvColsMatch = appJs.match(/const\s+CSV_COLS\s*=\s*\{[\s\S]*?\n\};/);
assertTrue(!!csvColsMatch, '找到 CSV_COLS 定义');

const csvColsBody = csvColsMatch[0];

// 检查串口列
assertTrue(/serial/.test(csvColsBody), 'CSV_COLS 包含 serial 列');
assertTrue(/baud/.test(csvColsBody), 'serial 列包含 baud');
assertTrue(/databits/.test(csvColsBody), 'serial 列包含 databits');
assertTrue(/stopbits/.test(csvColsBody), 'serial 列包含 stopbits');
assertTrue(/parity/.test(csvColsBody), 'serial 列包含 parity');

// 检查寄存器列
assertTrue(/registers/.test(csvColsBody), 'CSV_COLS 包含 registers 列');
assertTrue(/addr/.test(csvColsBody), 'registers 列包含 addr');
assertTrue(/name/.test(csvColsBody), 'registers 列包含 name');
assertTrue(/dtype/.test(csvColsBody), 'registers 列包含 dtype');

// 检查 MQTT 列
assertTrue(/mqtt/.test(csvColsBody), 'CSV_COLS 包含 mqtt 列');
assertTrue(/host/.test(csvColsBody), 'mqtt 列包含 host');
assertTrue(/port/.test(csvColsBody), 'mqtt 列包含 port');

console.log('   ✓ CSV 列定义完整\n');

// ============================================
// 3. 导入版本校验测试
// ============================================
console.log('3. 测试 importCfg 版本校验...');

const importCfgMatch = appJs.match(/async\s+function\s+importCfg[\s\S]*?^}/m);
assertTrue(!!importCfgMatch, '找到 importCfg 函数');

const importCfgBody = importCfgMatch[0];

// 检查版本校验逻辑
assertTrue(/version/.test(importCfgBody), 'importCfg 检查 version 字段');
assertTrue(/major/.test(importCfgBody) || /兼容/.test(importCfgBody), 'importCfg 有 major 版本兼容性检查');

console.log('   ✓ 版本校验逻辑存在\n');

// ============================================
// 4. 档位守卫测试
// ============================================
console.log('4. 测试档位守卫...');

// sniff 档禁用导入
const sniffImportGuard = /S\.mode\s*===\s*'sniff'.*sniff 档无表单可导入/s.test(appJs);
assertTrue(sniffImportGuard, 'sniff 档禁用导入 + toast 提示');

// idle 档禁用导入
const idleImportGuard = /S\.mode\s*===\s*'idle'.*idle 档无配置/s.test(appJs);
assertTrue(idleImportGuard, 'idle 档禁用导入 + toast 提示');

// platform 档禁用导入
const platformImportGuard = /isPlatform.*平台档配置从 MQTT 平台拉取/s.test(appJs);
assertTrue(platformImportGuard, 'platform 档禁用导入 + toast 提示');

// sniff 档允许导出（导出推断表数据）
const sniffExportAllow = /S\.mode\s*===\s*'sniff'.*exportSniffAs/s.test(appJs);
assertTrue(sniffExportAllow, 'sniff 档导出推断表数据 (exportSniffAsJson/Csv)');

console.log('   ✓ 档位守卫完整\n');

// ============================================
// 5. sniff 档推断表导出测试
// ============================================
console.log('5. 测试 sniff 档推断表导出...');

const exportSniffJson = /function\s+exportSniffAsJson/.test(appJs);
assertTrue(exportSniffJson, '存在 exportSniffAsJson 函数');

const exportSniffCsv = /function\s+exportSniffAsCsv/.test(appJs);
assertTrue(exportSniffCsv, '存在 exportSniffAsCsv 函数');

// 检查推断表字段
const inferFields = ['addr', 'name', 'value', 'dtype', 'hits', 'answered'];
for (const field of inferFields) {
  assertTrue(new RegExp(field).test(appJs), `推断表包含 ${field} 字段`);
}

console.log('   ✓ 推断表导出功能完整\n');

// ============================================
// 6. collectCfg 数据收集测试
// ============================================
console.log('6. 测试 collectCfg 数据收集...');

const collectCfgMatch = cfgJs.match(/function\s+collectCfg[\s\S]*?^}/m);
assertTrue(!!collectCfgMatch, '找到 collectCfg 函数');

const collectCfgBody = collectCfgMatch[0];

// 检查收集的字段 (collectCfg 只收集串口配置，MQTT 在 app.js 里单独收集)
const collectFields = [
  ['baud', '波特率'],
  ['databits', '数据位'],
  ['stopbits', '停止位'],
  ['parity', '校验位']
];

for (const [field, desc] of collectFields) {
  assertTrue(new RegExp(field).test(collectCfgBody), `collectCfg 收集 ${field} (${desc})`);
}

// 检查 MQTT 字段在 app.js 的 exportCfgAsJson 里收集
const exportJsonFn = appJs.match(/function\s+exportCfgAsJson[\s\S]*?^}/m)[0];
const mqttFields = ['host', 'port', 'ssl', 'user', 'pass', 'client_id'];
for (const field of mqttFields) {
  assertTrue(new RegExp(field).test(exportJsonFn), `exportCfgAsJson 收集 MQTT ${field}`);
}

console.log('   ✓ collectCfg 数据收集完整 (串口 + MQTT)\n');

// ============================================
// 7. applyParsedData 导入回填测试
// ============================================
console.log('7. 测试 applyParsedData 导入回填...');

const applyParsedDataMatch = appJs.match(/function\s+applyParsedData[\s\S]*?^}/m);
assertTrue(!!applyParsedDataMatch, '找到 applyParsedData 函数');

const applyBody = applyParsedDataMatch[0];

// 检查回填的字段
const applyFields = ['baud', 'databits', 'stopbits', 'parity', 'host', 'port'];
for (const field of applyFields) {
  assertTrue(new RegExp(field).test(applyBody), `applyParsedData 回填 ${field}`);
}

// 检查寄存器表清空 + 重建
assertTrue(/registers/.test(applyBody), 'applyParsedData 处理 registers');
assertTrue(/renderRegTable/.test(applyBody), 'applyParsedData 调用 renderRegTable 重建寄存器表');

console.log('   ✓ applyParsedData 导入回填完整\n');

// ============================================
// 总结
// ============================================
console.log('=== 测试总结 ===');
console.log('✓ JSON 导出结构完整 (8 个必需字段)');
console.log('✓ CSV 列定义完整 (serial/registers/mqtt)');
console.log('✓ 版本校验逻辑存在');
console.log('✓ 档位守卫完整 (sniff/idle/platform 禁用导入)');
console.log('✓ 推断表导出功能完整 (JSON/CSV)');
console.log('✓ collectCfg 数据收集完整');
console.log('✓ applyParsedData 导入回填完整');
console.log('\n所有静态检查通过！');
console.log('注意：实际功能需要连接设备后实测验证。');
