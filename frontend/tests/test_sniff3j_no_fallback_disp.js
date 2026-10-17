// test_sniff3j_no_fallback_disp.js
//
// sniff-3 j: renderDetected 兜底时不再显示兜底 baud, 只显示"待识别(未接总线或无流量)"
//   - d.fallback=true: el.detectHint.textContent = '待识别(未接总线或无流量)'
//   - d.fallback=false: 仍显示 "已识别: 9600/8/N/1 · 观测到从站 X" 或 "从站未观测到"

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. renderDetected 函数体内含 fallback 分支
const fnStart = appJs.indexOf('function renderDetected()');
const fnEnd = appJs.indexOf('\n}\n', fnStart);
const fnBody = appJs.substring(fnStart, fnEnd + 2);
assertEq(/d\.fallback/.test(fnBody), true,
  'sniff-3 j: renderDetected 含 d.fallback 判断');
assertEq(/待识别\(未接总线或无流量\)/.test(fnBody), true,
  'sniff-3 j: renderDetected fallback 时显示"待识别(未接总线或无流量)"');

// 2. 删了旧的 "⚠ 兜底 cfg.BAUD" 字面量 (不再混着显示兜底 baud)
assertEq(!/⚠ 兜底 cfg\.BAUD/.test(fnBody), true,
  'sniff-3 j: renderDetected 删了 "⚠ 兜底 cfg.BAUD" 字面量 (不再显示兜底 baud)');

// 3. 真识别 (fallback=false) 仍显示"已识别: " + serialDesc(d) + 从站信息
assertEq(/'已识别：'\s*\+\s*serialDesc\(d\)/.test(fnBody), true,
  'sniff-3 j: renderDetected 真识别仍显示"已识别: " + serialDesc(d)');
assertEq(/从站未观测到/.test(fnBody), true,
  'sniff-3 j: renderDetected 真识别仍含"从站未观测到"提示');
assertEq(/观测到从站/.test(fnBody), true,
  'sniff-3 j: renderDetected 真识别仍含"观测到从站"提示');

console.log('PASS: sniff-3 j 兜底时只显示"待识别(未接总线或无流量)", 不再混着显示兜底 baud');
