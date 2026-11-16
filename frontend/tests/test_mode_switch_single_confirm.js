// test_mode_switch_single_confirm.js
//
// 2026-11-16: 修「切一次档弹两个确认框 + 点 idle 偶尔要点两次」。
//
// 现场症状:
//   1. 切到 sniff 时连弹两个框: 卡片 onclick 先弹一个通用"确定切换?"，
//      applyMode 里又弹一个"是否清空 ds_poll/ds_infer"。同一个动作问两遍。
//   2. sniff 在跑 R:AUTODETECT、首页 5s 定时在跑 R:STAT 时点 idle，
//      sendCmd 被单未决保护瞬拒，界面只闪一句"上一条指令尚未返回"，
//      用户得再点一次才切得过去。
//   3. 切完之后卡片还挂着 switching 类(灰掉 + 进度光标)，要等下一次
//      renderMode 才恢复。
//
// 修法:
//   - 非 idle 档不再单独弹通用确认，只留 applyMode 里那次"会丢什么"的确认;
//     idle 例外(会复位用户配置)，保留卡片上那一次确认。
//   - applyMode 发 W:MODE 前先 waitPortIdle 等在途指令落地,
//     并用 sendCmdQueued 在撞车时重试一次。
//   - finally 里清 modeSwitching 之后补一次 renderMode()。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

function sliceFn(src, name) {
  const start = src.indexOf(name);
  if (start < 0) return '';
  const rest = src.slice(start + name.length);
  const m = rest.match(/\n(?:async )?function /);
  return rest.slice(0, m ? m.index : rest.length);
}

// === 点 1: 非 idle 档点卡片不再弹通用确认 ===
const handlerMatch = appJs.match(/document\.querySelectorAll\(['"]\.mode-card['"]\)\.forEach[\s\S]+?c\.onclick[\s\S]+?\}\);/);
assertEq(!!handlerMatch, true, '能定位 mode-card click handler');
if (handlerMatch) {
  const handler = handlerMatch[0];
  const nonIdle = handler.slice(handler.indexOf('非 idle 档'));
  assertEq(nonIdle.length > 0, true, '能切出"非 idle 档"分支');
  assertEq(/askConfirm\(/.test(nonIdle), false, '非 idle 档分支不再弹通用确认');
  assertEq(/applyMode\(m\)/.test(nonIdle), true, '非 idle 档仍然交给 applyMode');
  // idle 分支的确认必须留着(切回空闲会复位配置)
  const idlePart = handler.slice(0, handler.indexOf('非 idle 档'));
  assertEq(/askConfirm\(/.test(idlePart), true, 'idle 分支保留确认(会复位配置)');
}

// === 点 2: 切档前等在途指令落地 ===
assertEq(/async function waitPortIdle\(/.test(appJs), true, 'waitPortIdle 已定义');
assertEq(/async function sendCmdQueued\(/.test(appJs), true, 'sendCmdQueued 已定义');

const applyBody = sliceFn(appJs, 'async function applyMode');
assertEq(applyBody.length > 0, true, '能定位 applyMode');
if (applyBody) {
  assertEq(/await waitPortIdle\(mode === 'idle' \? 8000 : 4000\);/.test(applyBody), true,
    'applyMode: 发 W:MODE 前先等在途指令落地(idle 等更久)');
  assertEq(/sendCmdQueued\(Protocol\.Enc\.setMode\(mode\)/.test(applyBody), true,
    'applyMode: W:MODE 走 sendCmdQueued(撞车重试一次)');
  // 先把"切换中"立起来再等，防止等待窗口里连点进第二条
  const flagPos = applyBody.indexOf('S.modeSwitching = true');
  const waitPos = applyBody.indexOf('await waitPortIdle(');
  assertEq(flagPos > 0 && waitPos > flagPos, true, 'applyMode: 先置 modeSwitching 再 waitPortIdle');

  // === 点 3: finally 清标志后重绘, 去掉残留的 switching 类 ===
  assertEq(/S\.modeSwitching = false;[\s\S]{0,260}renderMode\(\);/.test(applyBody), true,
    'applyMode: finally 里清 modeSwitching 后补 renderMode()');
}

// === 点 4: 切换中连点给出提示, 不再静默 ===
assertEq(/if \(S\.modeSwitching && mode !== 'idle'\) \{ toast\('正在切换模式，请稍候…'\); return; \}/.test(applyBody), true,
  'applyMode: 切换中连点有提示');

console.log('PASS: 切档单次确认 + idle 排队重试 + switching 类清理 (8 个测试点通过)');
