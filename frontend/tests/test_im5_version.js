// test_im5_version.js
//
// im-5 6a: version 从 window.__APP_VERSION__ 读
//   1. index.html 注入 window.__APP_VERSION__ = '1.0.0' (跟 package.json 同步)
//   2. exportCfgAsJson data.version 用 window.__APP_VERSION__ (不再 hardcode '2.0.0')
//
// im-5 6b: importCfg 加版本校验
//   3. JSON 导入时检查 data.version
//   4. 没 version 字段: 接受 (兼容老格式)
//   5. major 相同 (1.0.0 / 1.0.1): 接受; 1.x 与 2.x 互导也放行(版本重置, 格式一致)
//   6. major 不同 (1.x / 3.x): 拒绝 + 抛 "版本不兼容"
//   7. CSV 不校验

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'package.json'), 'utf8'));

// 1. index.html 注入 __APP_VERSION__
const injectMatch = html.match(/<script>\s*window\.__APP_VERSION__\s*=\s*['"]([^'"]+)['"]\s*;?\s*<\/script>/);
assertEq(!!injectMatch, true, 'im-5 6a: index.html 含 window.__APP_VERSION__ 注入');
// 跟 package.json 同步
assertEq(injectMatch[1] === pkg.version, true,
  'im-5 6a: 注入的版本号 (' + injectMatch[1] + ') 跟 package.json (' + pkg.version + ') 一致');

// 2. exportCfgAsJson 用 window.__APP_VERSION__ (不再 hardcode)
const exportFnMatch = appJs.match(/function\s+exportCfgAsJson\s*\(\s*pre\s*\)\s*\{[\s\S]*?toast\('配置已导出为 JSON'\);?\s*\}/);
assertEq(!!exportFnMatch, true, 'im-5 6a: 找到 exportCfgAsJson 函数');
assertEq(/version:\s*\(?window\.__APP_VERSION__\s*\|\|\s*'unknown'\)?/.test(exportFnMatch[0]), true,
  'im-5 6a: exportCfgAsJson data.version 用 window.__APP_VERSION__ || "unknown"');
// 不再 hardcode '2.0.0'
assertEq(!/version:\s*['"]2\.0\.0['"]/.test(exportFnMatch[0]), true,
  'im-5 6a: exportCfgAsJson data.version 不再 hardcode "2.0.0"');

// 3. importCfg 含版本校验
const importCfgMatch = appJs.match(/async\s+function\s+importCfg[\s\S]*?inp\.click\(\);?\s*\}/);
assertEq(!!importCfgMatch, true, 'im-5 6b: 找到 importCfg 函数体');
assertEq(/data\.version\s*!=\s*null/.test(importCfgMatch[0]) || /data\.version\s*!=\s*undefined/.test(importCfgMatch[0]),
  true, 'im-5 6b: importCfg 检查 data.version 不为 null/undefined');
assertEq(/curMajor/.test(importCfgMatch[0]) && /impMajor/.test(importCfgMatch[0]), true,
  'im-5 6b: importCfg 取 major version (curMajor / impMajor)');
assertEq(/版本不兼容/.test(importCfgMatch[0]), true,
  'im-5 6b: importCfg major 不同抛 "版本不兼容" 错误');

// 4. CSV 不校验 (importCfgMatch 里 fmt === 'JSON' 才校验)
assertEq(/fmt\s*===\s*['"]JSON['"]/.test(importCfgMatch[0]), true,
  'im-5 6b: importCfg 版本校验只在 fmt === "JSON" 时跑 (CSV 不校验)');

// 5. 老格式兼容: 没 version 字段也接受
//    测试代码: 注释说 "没 version 字段 (老格式): 接受, 兼容"
assertEq(/没\s*version\s*字段/.test(importCfgMatch[0]) || /兼容老格式/.test(importCfgMatch[0]), true,
  'im-5 6b: importCfg 注释说明"没 version 字段 (老格式): 接受"');

console.log('PASS: im-5 6a 从 window.__APP_VERSION__ 读版本号 + 6b importCfg 加版本校验 (major 拒, 老格式兼容)');
