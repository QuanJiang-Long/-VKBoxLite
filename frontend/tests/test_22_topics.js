// test_22_topics.js
//
// 22-fix: 测 topics.js 的核心功能
//   - 12 个 PLATFORM_* 常量都在 (U1~U7 + D1~D4 + D2n, U2 info 和 U6 reply 各 1 条)
//   - format 替换 {sn}
//   - manualExtraTopics 返回 2 条 (U1 hello + U2 meta)
//   - platformExtraTopics 返回 10 条 (24-fix 时 9 条; 2026-10 D2 改 service/invoke
//     + 新增 D2n node 级后同步为 10 条)
//   - formatListAsLines 输出多行

const { assertEq } = require('./setup');

// topics.js 是浏览器全局 (window.VKBoxTopics), 也支持 CommonJS (module.exports)
const VKBoxTopics = require('../renderer/topics');

const SN = 'VK20261016001';

// 测 1: 12 个常量都在
const expected = [
  'PLATFORM_HELLO_TOPIC', 'PLATFORM_INFO_TOPIC', 'PLATFORM_RES_TOPIC',
  'PLATFORM_PUB_TOPIC', 'PLATFORM_EVENT_TOPIC', 'PLATFORM_REPLY_TOPIC',
  'PLATFORM_FPOST_TOPIC',
  'PLATFORM_GET_TOPIC', 'PLATFORM_FUNC_TOPIC', 'PLATFORM_FUNC_NODE_TOPIC',
  'PLATFORM_PSET_TOPIC', 'PLATFORM_PGET_TOPIC',
];
for (const k of expected) {
  assertEq(typeof VKBoxTopics[k] === 'string' && VKBoxTopics[k].length > 0, true, `${k} 存在且非空`);
}

// 测 1.5: D2 两条 topic 的值 (2026-10 D2 改名 + 新增 node 级)
assertEq(
  VKBoxTopics.PLATFORM_FUNC_TOPIC,
  '/sys/thing/gw/service/invoke/{sn}',
  'D2 gw 级是 service/invoke (旧 function/get 已弃用)'
);
assertEq(
  VKBoxTopics.PLATFORM_FUNC_NODE_TOPIC,
  '/sys/thing/node/service/invoke/{sn}-N',
  'D2n node 级常量 (N=子设备序号, 与 U4 上报同序列)'
);

// 测 2: format 替换 {sn}
assertEq(
  VKBoxTopics.format(VKBoxTopics.PLATFORM_HELLO_TOPIC, SN),
  '/sys/thing/gw/config/hello/' + SN,
  'format 替换 {sn}'
);
assertEq(
  VKBoxTopics.format(VKBoxTopics.PLATFORM_HELLO_TOPIC, ''),
  '/sys/thing/gw/config/hello/{sn}',
  'format 空 sn 返回原模板'
);
assertEq(
  VKBoxTopics.format(VKBoxTopics.PLATFORM_HELLO_TOPIC, null),
  '/sys/thing/gw/config/hello/{sn}',
  'format null sn 返回原模板'
);
assertEq(
  VKBoxTopics.format(null, SN),
  '',
  'format 空模板返回空串'
);

// 测 3: manualExtraTopics 返回 2 条
const extras = VKBoxTopics.manualExtraTopics(SN);
assertEq(extras.length, 2, 'manualExtraTopics 返回 2 条');
assertEq(extras[0].code, 'U1', '第 1 条是 U1');
assertEq(extras[0].name, 'hello', 'U1 名称是 hello');
assertEq(extras[0].topic, '/sys/thing/gw/config/hello/' + SN, 'U1 topic 带 SN');
assertEq(extras[1].code, 'U2', '第 2 条是 U2');
assertEq(extras[1].name, 'meta', 'U2 名称是 meta');
assertEq(extras[1].topic, '/sys/thing/gw/info/post/' + SN, 'U2 topic 带 SN');

// 测 4: manualExtraTopics 空 SN 返回空数组
assertEq(VKBoxTopics.manualExtraTopics('').length, 0, '空 SN 返回空数组');
assertEq(VKBoxTopics.manualExtraTopics(null).length, 0, 'null SN 返回空数组');

// 测 5.5: platformExtraTopics 返回 10 条 (24-fix 9 条 → D2/D2n 同步后 10 条)
const pextras = VKBoxTopics.platformExtraTopics(SN);
assertEq(pextras.length, 10, 'platformExtraTopics 返回 10 条');
// 验证每条 code 都唯一
const codes = pextras.map(it => it.code);
const uniq = codes.filter((v, i, a) => a.indexOf(v) === i);
assertEq(uniq.length, 10, '10 条 code 都唯一');
// 验证不包含 U4 (已在 mqStPub) 和 D1 (已在 mqStSub)
assertEq(codes.indexOf('U4') < 0, true, '不含 U4 (已在 mqStPub)');
assertEq(codes.indexOf('D1') < 0, true, '不含 D1 (已在 mqStSub)');
// 验证 U1/U2/U3/U5/U6/U7 + D2/D2n/D3/D4 都在
const expectedCodes = ['U1', 'U2', 'U3', 'U5', 'U6', 'U7', 'D2', 'D2n', 'D3', 'D4'];
for (const c of expectedCodes) {
  assertEq(codes.indexOf(c) >= 0, true, `包含 ${c}`);
}
// 验证 U2 用的是 info (不是 meta)
assertEq(pextras.find(it => it.code === 'U2').name, 'info', 'U2 名称是 info');
// 验证 D2/D2n 的 topic 值 (2026-10 D2 改名后)
assertEq(pextras.find(it => it.code === 'D2').topic,
  '/sys/thing/gw/service/invoke/' + SN, 'D2 topic 是 service/invoke');
assertEq(pextras.find(it => it.code === 'D2n').topic,
  '/sys/thing/node/service/invoke/' + SN + '-N', 'D2n topic 是 node 级 {sn}-N');
// 验证空 SN 返回空数组
assertEq(VKBoxTopics.platformExtraTopics('').length, 0, 'platformExtraTopics 空 SN 返回空数组');

// 测 5: formatListAsLines 输出多行
const lines = VKBoxTopics.formatListAsLines(extras);
assertEq(lines.indexOf('\n') >= 0, true, '输出包含换行');
assertEq(lines.split('\n').length, 2, '输出正好 2 行');
assertEq(lines.indexOf('U1 (hello):') >= 0, true, '第 1 行以 "U1 (hello):" 开头');
assertEq(lines.indexOf('U2 (meta):') >= 0, true, '第 2 行以 "U2 (meta):" 开头');
assertEq(VKBoxTopics.formatListAsLines([]), '', '空数组返回空串');

console.log('PASS: 22-fix - topics.js 12 个常量 + format + manualExtraTopics + platformExtraTopics(10条) + formatListAsLines 全部通过');
