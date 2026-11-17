// test_e2e_tools.js
//
// 2026-11-16: 真机/模拟器跑测脚本（tools/e2e + tools/*_e2e.js）的冒烟测试。
//
// 脚本本身不进 Electron, 但同样是"会被现场直接用"的代码, 至少守住:
//   1. 6 个文件语法都能过（曾经因为模板字符串写错, 整个 journey 加载失败）;
//   2. journey 导出 runJourney, 且 SKIP 是个独立错误类型;
//   3. 真机脚本没给 --port 时给明确提示 + 退出码 2（而不是崩栈）;
//   4. --help 能打印用法;
//   5. 两份手册存在, 且互相引用。

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { assertEq } = require('./setup');

const root = path.join(__dirname, '..', '..');
const files = [
  path.join(root, 'tools', 'e2e', 'cdp.js'),
  path.join(root, 'tools', 'e2e', 'journey.js'),
  path.join(root, 'tools', 'e2e', 'cli.js'),
  path.join(root, 'tools', 'real_device_e2e.js'),
  path.join(root, 'tools', 'sim_e2e.js'),
  path.join(root, 'tools', 'mem_scale_e2e.js'),
];

// === 点 1: 文件存在 + 语法通过 ===
for (const f of files) {
  assertEq(fs.existsSync(f), true, '存在: ' + path.relative(root, f));
  const r = spawnSync(process.execPath, ['--check', f], { encoding: 'utf8' });
  assertEq(r.status, 0, '语法通过: ' + path.relative(root, f)
    + (r.status ? ' :: ' + (r.stderr || '').trim() : ''));
}

// === 点 2: journey 导出 ===
const journey = require(path.join(root, 'tools', 'e2e', 'journey.js'));
assertEq(typeof journey.runJourney, 'function', 'journey 导出 runJourney');
assertEq(typeof journey.Skip, 'function', 'journey 导出 Skip');
assertEq(journey.Skip.prototype instanceof Error, true, 'Skip 是 Error 子类（统一按 SKIP 计）');

// 步骤名清单: 真机手册里的编号必须和代码里的 step 名对得上
const src = fs.readFileSync(path.join(root, 'tools', 'e2e', 'journey.js'), 'utf8');
const steps = (src.match(/await step\('(\d+)/g) || []).length;
assertEq(steps >= 19, true, '至少 19 个步骤（当前 ' + steps + '）');

// === 点 3: 真机脚本缺 --port 时友好退出 ===
const noPort = spawnSync(process.execPath, [path.join(root, 'tools', 'real_device_e2e.js')], {
  encoding: 'utf8', cwd: root, timeout: 20000,
});
assertEq(noPort.status, 2, '没给 --port 时退出码 2');
assertEq(/--port/.test((noPort.stderr || '') + (noPort.stdout || '')), true, '提示里指出 --port');

// === 点 4: --help ===
const help = spawnSync(process.execPath, [path.join(root, 'tools', 'real_device_e2e.js'), '--help'], {
  encoding: 'utf8', cwd: root, timeout: 20000,
});
assertEq(help.status, 0, '--help 退出码 0');
assertEq(/真机全流程跑测/.test(help.stdout || ''), true, '--help 有用法说明');

// === 点 5: 手册存在且互链 ===
const realDoc = path.join(root, 'docs', 'real-device-e2e.md');
const simDoc = path.join(root, 'docs', 'simulator-e2e.md');
assertEq(fs.existsSync(realDoc), true, 'docs/real-device-e2e.md 存在');
assertEq(fs.existsSync(simDoc), true, 'docs/simulator-e2e.md 存在');
assertEq(/real-device-e2e\.md/.test(fs.readFileSync(simDoc, 'utf8')), true,
  '模拟器手册链到真机手册');
assertEq(/simulator-e2e\.md/.test(fs.readFileSync(realDoc, 'utf8')), true,
  '真机手册链到模拟器手册');
assertEq(/--expect-slave/.test(fs.readFileSync(realDoc, 'utf8')), true,
  '真机手册写了 SKIP 升级开关');
assertEq(/mem_scale_e2e\.js/.test(fs.readFileSync(realDoc, 'utf8')), true,
  '真机手册写了内存规模测试脚本');

// === 点 6: 内存规模脚本缺 --port 时退出码 2 ===
const noPort2 = spawnSync(process.execPath, [path.join(root, 'tools', 'mem_scale_e2e.js')], {
  encoding: 'utf8', cwd: root, timeout: 20000,
});
assertEq(noPort2.status, 2, 'mem_scale: 没给 --port 时退出码 2');
assertEq(/--port/.test((noPort2.stderr || '') + (noPort2.stdout || '')), true, 'mem_scale: 提示里指出 --port');

console.log('PASS: 跑测脚本冒烟（6 文件语法 + 参数/帮助 + 手册互链，15 个测试点通过）');
