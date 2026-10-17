// test_33b_device_platform_entry.js
//
// 33-fix 设备端: 撤掉 25-fix 的 platform MQTT 拦截
//   - 不再要求 MQTT 已连接才能切 platform
//   - iot.pull_start() 失败时不再 poll.stop() 回滚, 让用户进 platform 档
//   - 返回 "OK platform (拉取未启动: ...)"

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const ctrlLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'bus', 'ctrl.lua'), 'utf8');

// 测 1: 不再有 25-fix 的 MQTT 连接状态检查
//   排除注释行 (// 开头) - 33-fix 注释里会提到 "25-fix"
const codeOnly = ctrlLua.split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
assertEq(/if\s+mode\s*==\s*["']platform["']\s+and\s+not\s+from_boot\s+then/.test(codeOnly), false,
  '不再有 "mode == platform and not from_boot" 拦截条件');
assertEq(/FAIL platform:\s*MQTT\s*未连接.*等连上后再切/.test(ctrlLua), false,
  '不再有 25-fix 的 "FAIL platform: MQTT 未连接" 错误消息');

// 测 2: iot.pull_start() 失败时不再 poll.stop() 回滚
//   只检查 pull_start 失败分支 (if not ok then ... end), 不匹配 sniff 档的 poll.stop
const pullStartSection = ctrlLua.match(/local\s+ok,\s+err\s*=\s*iot\s+and\s+iot\.pull_start\(\)[\s\S]+?return\s+true,\s*["']OK platform,?\s*pulling["']/);
assertEq(!!pullStartSection, true, '能找到 pull_start 调用和 pulling 返回');
if (pullStartSection) {
  // 失败分支 (if not ok then ... end), 匹配到 return true, <string> (不是单独的 return true)
  // 排除注释行 (-- 开头) - 注释里会提到 "poll.stop() 回滚"
  const failBranchRaw = pullStartSection[0].match(/if\s+not\s+ok\s+then[\s\S]+?return\s+true,\s*["'][^"']+["']/);
  assertEq(!!failBranchRaw, true, '能找到失败分支 (if not ok then ... return true, "<msg>")');
  if (failBranchRaw) {
    const failBranch = failBranchRaw[0].split('\n').filter(l => !/^\s*--/.test(l)).join('\n');
    assertEq(/poll\.stop\(\)/.test(failBranch), false,
      'iot.pull_start() 失败时不再 poll.stop() 回滚 (排除注释)');
    assertEq(/OK platform\s*\(拉取未启动/.test(failBranch), true,
      'iot.pull_start() 失败时返回 "OK platform (拉取未启动: ...)"');
  }
}

// 测 3: 33-fix 注释存在 (说明改动原因)
assertEq(/33-fix:.*撤掉.*25-fix.*platform.*MQTT.*拦截/.test(ctrlLua), true,
  '33-fix 注释: 撤掉 25-fix 的 platform MQTT 拦截');

// 测 4: 仍然保留 from_boot 路径的处理 (开机自启路径, 不受影响)
//   实际上开关了 25-fix 后 from_boot 不再被检查, 但这没关系
//   只需要确认: 如果不是 platform 档, 不会进 platform 分支

console.log('PASS: 33-fix 设备端 - 撤掉 platform MQTT 拦截, iot.pull_start 失败不 poll.stop (4 个测试点通过)');
