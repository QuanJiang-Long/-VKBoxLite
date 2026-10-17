// test_37_poll_slot_uses_mode.js
//
// 37-fix: poll_slot() 必须用 ctrl 记下的 mode, 不能用 poll.cur_slot()
//
// 用户实测日志 (15:29 切 platform):
//   - 切 platform -> ctrl.poll.stop() 跑了 (36-fix 后 stop 清 regs/lastCfg),
//     但 curSlot 没被重置
//   - ds_pull 空 -> 34-fix 不起 poll, curSlot 残留默认 "poll"
//   - 平台推 4 条 -> auto_apply 走 if poll_slot() == "pull" 判断
//   - poll_slot() 读 p.cur_slot() = "poll", 跳过 if 块, 不调 apply_cfg/start
//   - 结果: ds_pull 有 4 条 (R:CFG 显示), R:REG 永远空 (用户看到的"参数列表-空")
//
// 修复:
//   1. iot.lua poll_slot() 改用 get_mode() (ctrl 的 S.cur), 不依赖 curSlot
//   2. iot.lua auto_apply needs_restart=true+is_running=false 分支兜底 start
//   3. iot.lua auto_apply needs_restart=false+is_running=false 分支兜底 start

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const iotLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'iot', 'iot.lua'), 'utf8');

// 修复 1: poll_slot() 改用 get_mode()
const slotStart = iotLua.indexOf('local function poll_slot()');
if (slotStart > 0) {
  // 找函数体 (下一个 \nend 单独一行的位置)
  let searchFrom = slotStart + 30;
  let endPos = -1;
  for (let i = 0; i < 20; i++) {
    const idx = iotLua.indexOf('\nend\n', searchFrom);
    if (idx < 0) break;
    // 验证这是 poll_slot 的 end: 前后没有更多语句
    const before = iotLua.substring(slotStart, idx);
    if ((before.match(/if .+ then return .+ end/g) || []).length === 2) {
      endPos = idx;
      break;
    }
    searchFrom = idx + 1;
  }
  const body = iotLua.substring(slotStart, endPos + 5);
  assertEq(/get_mode\(\)/.test(body), true,
    '37-fix: poll_slot() 改用 get_mode() (不再依赖 poll.cur_slot() - 切档时残留)');
  assertEq(/local\s+p\s*=\s*get_poll\(\)/.test(body), false,
    '37-fix: poll_slot() 不再 local p = get_poll() (切档时 curSlot 残留)');
}

// 修复 2: auto_apply needs_restart+is_running=false 兜底 start
const autoApplyStart = iotLua.indexOf('local function auto_apply');
const autoApplyBody = iotLua.substring(autoApplyStart, iotLua.indexOf('\nend\n', autoApplyStart + 100) + 5);
// 找 needs_restart 块
const needsIdx = autoApplyBody.indexOf('pe.needs_restart');
const stopBranch = autoApplyBody.indexOf('if pe.is_running()', needsIdx);
const endStopBranch = autoApplyBody.indexOf('\n                end', stopBranch + 10);
if (needsIdx > 0 && stopBranch > 0 && endStopBranch > 0) {
  const branch = autoApplyBody.substring(stopBranch, endStopBranch);
  // 找 else 分支 (is_running() 为 false)
  const elseIdx = branch.indexOf('else');
  if (elseIdx > 0) {
    const elseBranch = branch.substring(elseIdx);
    assertEq(/pe\.start\(.pull.\)/.test(elseBranch), true,
      '37-fix: auto_apply needs_restart+is_running=false 兜底 pe.start("pull") (切 platform ds_pull 空后拉到配置)');
  }
}

// 修复 3: auto_apply needs_restart=false 兜底 start
const elseIdx = autoApplyBody.indexOf('\n            else\n                pe.apply_cfg(n)');
if (elseIdx > 0) {
  const after = autoApplyBody.substring(elseIdx, autoApplyBody.indexOf('\n        end', elseIdx));
  assertEq(/if not pe\.is_running\(\) then pe\.start\(.pull.\) end/.test(after), true,
    '37-fix: auto_apply needs_restart=false 也兜底 start (平台推了和当前一样的 baud/slave)');
}

console.log('PASS: 37-fix poll_slot 用 get_mode + auto_apply 兜底 start (切 platform 拉到配置后 R:REG 正常)');
