// test_cshard_upload.js
//
// 回归: 2026-11-13 配置分片上传(甲) —— renderer/cfg.js 的 planShards / writeCfgUp
//
// 为什么前端也要钉一遍: 设备侧那条墙是【单行接不进来】(轮询中只给得出 ~3KB 的
// 连续块, 而 60 行那份 W:CFG 是一整行 4072B, 在解析之前就被 prov 丢掉)。分片
// 这件事的正确性一半在"切出来的每一片整行都够小"、一半在"切完还得是同一份配置"
// —— 行数丢了、顺序乱了、收尾把 regs 又带上, 现场都会以"保存成功但少几个点"
// 的形式回来, 那种问题最难查。
//
// 测什么(全在 vm 里跑真的 cfg.js, 不拿正则读源码):
// 1. 小配置仍然一条 W:CFG 走完, 根本不碰分片(向后兼容 = 老固件也能用)
// 2. 60 行切成 N 片: 每片整行 <= 1200B, 片数 <= 32, 行序和内容一字不差
// 3. 收尾片带的是【除 regs 外】的字段, regs 不许多发一遍
// 4. 第 k 片重试两次仍失败 -> 发 W:CSABORT, 报错里说清是第几片
// 5. 字节数按 UTF-8 算: 中文行名不能按字符数低估(低估 = 片切大 = 现场又收不下)
// 6. 一行就超过预算 -> 当场说清, 不许切成两半送出去
//
// ⚠️ 桩必须连【应答键】一起模拟。11-13 第一次现场分片保存: 设备那边 4 片全收、
//    rows=60 落盘、回了 RET:CFG=OK —— 前端却弹"收尾失败"。原因是 sendCmd(line,'CFINISH')
//    等的是 CFINISH 这个键, app.js 的认领规则是"应答键 == 在途指令键"(FAIL 例外),
//    RET:CFG=OK 谁都不匹配 → 5s 超时 → 重发(会话已清 → 真失败) → CSABORT。
//    上一版这个桩把 expectCmd 扔一边、来什么 resolve 什么, 这类键名错位结构上就看不见。
//    现在 deviceReply() 按 cmd.lua 的应答串回, 再走一遍协议解码 + 认领规则。
//    对的那一侧另有护栏: tests/lua/test_cmd_cshard.lua ① 钉住设备回的就是
//    RET:CFINISH=OK。两边各钉一半, 谁改谁红。
//
// 跑法: node tests/test_cshard_upload.js

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { assertEq, assertTrue } = require('./setup');

const FE = path.join(__dirname, '..');

// 设备对每条上行命令回什么 —— 抄 firmware/svc/cmd.lua 的 M.reply 串
function deviceReply(line) {
  if (line.indexOf('W:CFG=') === 0) return 'RET:CFG=OK';
  if (line.indexOf('W:CSHARD=') === 0) {
    // 'W:CSHARD=2/4,[...]' -> RET:CSHARD=2=OK
    return 'RET:CSHARD=' + line.slice(9).split(',')[0].split('/')[0] + '=OK';
  }
  if (line.indexOf('W:CFINISH=') === 0) return 'RET:CFINISH=OK';
  if (line === 'W:CSABORT') return 'RET:CSABORT=OK';
  return null;
}

// ---- 造一个装了 protocol.js + cfg.js 的沙箱, 串口用假的 ----
function makeBox(opt) {
  opt = opt || {};
  const sent = [];          // 前端真正写出去的每一行
  const statusMsgs = [];
  const ctx = vm.createContext({
    TextEncoder, JSON, Object, Array, String, Number, Math, Error, Promise, RegExp,
    console,
    setTimeout, clearTimeout,
  });
  ctx.status = (m) => { statusMsgs.push(m); };
  ctx.toast = () => {};
  ctx.S = {};
  ctx.sendCmd = (line, expectCmd) => new Promise((resolve, reject) => {
    sent.push(line);
    if (opt.drop && opt.drop(line)) return reject(new Error('设备应答超时：' + line));
    const reply = deviceReply(line);
    if (!reply) return reject(new Error('桩不认识这条命令: ' + line));
    const resp = ctx.Protocol.decode(reply);
    // app.js onSerialLine 的认领规则, 原样搬过来
    const matched = resp && (resp.cmd === expectCmd || !resp.ok ||
      (resp.cmd === 'OK' && expectCmd !== 'SN'));
    if (!matched) {
      return reject(new Error('应答键错位: 设备回 ' + reply + '(键=' + resp.cmd +
        '), 前端等在途的是 ' + expectCmd + ' —— 没人认领就是 5s 超时'));
    }
    if (!resp.ok) return reject(new Error(resp.data));
    resolve(resp);
  });
  vm.runInContext(fs.readFileSync(path.join(FE, 'protocol.js'), 'utf8'), ctx);
  vm.runInContext(fs.readFileSync(path.join(FE, 'renderer', 'cfg.js'), 'utf8'), ctx);
  return { ctx, sent, statusMsgs };
}

function rows(n) {
  const out = [];
  for (let i = 1; i <= n; i++) {
    out.push({ addr: 100 + i, count: 2, name: 'machine_temp_' + i,
               alias: '温度' + i + '号点位', dtype: 'float32' });
  }
  return out;
}
const CFG = { baud: 9600, slave: 1, interval_ms: 5000, timeout_ms: 500 };
const bytes = (s) => new TextEncoder().encode(s).length;

// ---- 逐字节还原设备那边: 片里必须是 JSON 数组, 收尾里必须没有 regs ----
function splitLine(line) {
  const eq = line.indexOf('=');
  return { cmd: line.slice(0, eq), arg: line.slice(eq + 1) };
}

async function main() {
  // ===== 1) 小配置: 一条 W:CFG 走人 =====
  {
    const b = makeBox();
    const mode = await b.ctx.writeCfgUp(CFG, rows(2));
    assertEq(mode, 'plain', '① 小配置该走整行那条路');
    assertEq(b.sent.length, 1, '① 只发一行');
    assertTrue(b.sent[0].indexOf('W:CFG=') === 0, '① 发的就是 W:CFG: ' + b.sent[0]);
    const obj = JSON.parse(splitLine(b.sent[0]).arg);
    assertEq(obj.regs.length, 2, '① regs 跟着整行走');
  }

  // ===== 2) 60 行: 切成 N 片, 每片整行都够小, 内容一字不差 =====
  {
    const b = makeBox();
    const regs = rows(60);
    const whole = JSON.stringify(Object.assign({}, CFG, { regs: regs }));
    assertTrue(bytes('W:CFG=' + whole) > 1200, '② 这份该超阈值, 实际 ' + bytes('W:CFG=' + whole) + 'B');
    const mode = await b.ctx.writeCfgUp(CFG, regs);
    assertEq(mode, 'shard', '② 该走分片');
    const shards = b.sent.filter(l => l.indexOf('W:CSHARD=') === 0);
    const fin = b.sent.filter(l => l.indexOf('W:CFINISH=') === 0);
    assertEq(fin.length, 1, '② 收尾一条');
    // 一条不多不少 = 没有任何一次重发。上一版现场就是靠这条看出来的:
    // 应答键错位 → 收尾被重发两次 → sent 比 n+1 多。设备回得对但【没人认领】,
    // 只看"最后有没有报错"是看不出来的(它报的是失败, 而配置其实存进去了)
    assertEq(b.sent.length, shards.length + 1, '② 成功路上一条都不许多发');
    assertTrue(shards.length >= 4, '② 60 行至少 4 片, 实际 ' + shards.length);
    assertTrue(shards.length <= 32, '② 片数不超过设备上限 32');
    for (const l of shards) {
      assertTrue(bytes(l) <= 1200, '② 单行超过 1200B: ' + bytes(l) + 'B');
      const arg = splitLine(l).arg;
      const comma = arg.indexOf(',');
      const head = arg.slice(0, comma).split('/');
      assertEq(head.length, 2, '② 片头是 i/n');
      assertEq(Number(head[1]), shards.length, '② n 前后一致');
      const arr = JSON.parse(arg.slice(comma + 1));
      assertTrue(Array.isArray(arr), '② 片体是数组');
    }
    // 片号必须 1..n 连续, 顺序就是发送顺序
    shards.forEach((l, i) => {
      const head = splitLine(l).arg.split(',')[0];
      assertEq(head, (i + 1) + '/' + shards.length, '② 第 ' + (i + 1) + ' 片的片头');
    });
    // 拼回去必须等于原来那 60 行(逐字段)
    const got = [];
    shards.forEach(l => JSON.parse(splitLine(l).arg.split(',').slice(1).join(',')).forEach(r => got.push(r)));
    assertEq(got.length, 60, '② 60 行一行不少');
    assertEq(JSON.stringify(got), JSON.stringify(regs), '② 行序和内容一字不差');
    // 收尾: 字段齐, 但不许多带 regs
    const fa = splitLine(fin[0]).arg;
    assertEq(fa.split(',')[0], String(shards.length), '② 收尾说的 n 和片数一致');
    const fo = JSON.parse(fa.slice(fa.indexOf(',') + 1));
    assertEq(fo.baud, 9600, '② 收尾带了 485 字段');
    assertEq('regs' in fo, false, '② 收尾不许再带 regs');
  }

  // ===== 3) 第 2 片送三次都不行: 放弃 + 说清是第几片 =====
  {
    // 让第 2 片永远"应答超时", 其余照旧走 makeBox 里那套设备应答 + 认领规则
    const b = makeBox({ drop: (l) => l.indexOf('W:CSHARD=2/') === 0 });
    let err = null;
    try { await b.ctx.writeCfgUp(CFG, rows(60)); } catch (e) { err = e; }
    assertTrue(err !== null, '③ 必须抛错, 不许假装保存成功');
    assertTrue(err.message.indexOf('第 2/') >= 0, '③ 报错要说清死在第几片: ' + err.message);
    const tries = b.sent.filter(l => l.indexOf('W:CSHARD=2/') === 0).length;
    assertEq(tries, 3, '③ 同一片重试到 3 次为止');
    assertTrue(b.sent.some(l => l.indexOf('W:CSABORT') === 0), '③ 放弃会话, 不把半份暂存留在设备里');
    assertTrue(!b.sent.some(l => l.indexOf('W:CFINISH') === 0), '③ 片没齐就不许收尾提交');
  }

  // ===== 4) UTF-8: 中文行名按字节算 =====
  {
    const b = makeBox();
    const zh = [{ addr: 1, count: 1, name: 'n', alias: '温'.repeat(30), dtype: 'uint16' }];
    assertEq(b.ctx.byteLen('温度'), 6, '④ byteLen 按 UTF-8 数字节');
    const ps = b.ctx.planShards(zh.concat(rows(40)));
    let max = 0;
    ps.forEach((p, i) => {
      const line = 'W:CSHARD=' + (i + 1) + '/' + ps.length + ',' + JSON.stringify(p);
      if (bytes(line) > max) max = bytes(line);
    });
    assertTrue(max <= 1200, '④ 含中文的片也没超预算, 最大 ' + max + 'B');
  }

  // ===== 5) 一行就超预算: 明说, 不切半行 =====
  {
    const b = makeBox();
    const fat = [{ addr: 1, count: 1, name: 'x', alias: 'y'.repeat(2000), dtype: 'uint16' }];
    let err = null;
    try { b.ctx.planShards(fat); } catch (e) { err = e; }
    assertTrue(err !== null && err.message.indexOf('设备接不住') >= 0,
      '⑤ 单行超限要当场说清: ' + (err && err.message));
  }

  console.log('PASS: 配置分片上传 —— 小配置走整行, 大表切片且片片收得下, 片没齐不提交');
}

main().catch(e => { console.error('FAIL: ' + (e && e.stack || e)); process.exit(1); });
