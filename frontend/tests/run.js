// tests/run.js
//
// 跑 tests/test_*.js 所有测试, 汇总 pass/fail 统计, 失败时 exit 1
//
// 为什么不直接 require test 文件?
//   - 测试里有 vm sandbox 创建, process 共享可能泄漏全局状态
//   - 失败时 test 文件会 throw, 整个 process 中断, 看不到其它 test 结果
//   - 子进程隔离干净, 一个挂了不影响其它
//
// 用法: node tests/run.js

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const testsDir = __dirname;
const files = fs.readdirSync(testsDir)
  .filter(f => /^test_.*\.js$/.test(f))
  .sort();

if (files.length === 0) {
  console.error('No test_*.js files found in', testsDir);
  process.exit(1);
}

console.log('=== Running', files.length, 'tests ===\n');

let passed = 0;
let failed = 0;
const failures = [];

for (const f of files) {
  const start = Date.now();
  const result = spawnSync(process.execPath, [path.join(testsDir, f)], {
    encoding: 'utf8',
    cwd: path.join(testsDir, '..'),  // frontend/, 让测试能找到 renderer/ 等
  });
  const ms = Date.now() - start;
  const stdout = (result.stdout || '').trim();
  const stderr = (result.stderr || '').trim();

  if (result.status === 0) {
    passed++;
    const firstLine = stdout.split('\n')[0] || '(no output)';
    console.log(`  PASS  ${f.padEnd(40)} ${ms}ms  ${firstLine}`);
  } else {
    failed++;
    failures.push({ file: f, stdout, stderr, code: result.status });
    const firstLine = stdout.split('\n')[0] || stderr.split('\n')[0] || '(no output)';
    console.log(`  FAIL  ${f.padEnd(40)} ${ms}ms  ${firstLine}`);
  }
}

console.log(`\n=== Result: ${passed} passed, ${failed} failed ===`);

if (failed > 0) {
  console.log('\n=== Failures detail ===');
  for (const fail of failures) {
    console.log(`\n--- ${fail.file} ---`);
    console.log('stdout:', fail.stdout);
    if (fail.stderr) console.log('stderr:', fail.stderr);
  }
  process.exit(1);
}

process.exit(0);
