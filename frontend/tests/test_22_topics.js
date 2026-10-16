// test_22_topics.js
//
// 22-fix: 测 topics.js 的核心功能
//   - 11 个 PLATFORM_* 常量都在 (U1~U7 + D1~D4, U2 info 和 U6 reply 各 1 条)
//   - format 替换 {sn}
//   - manualExtraTopics 返回 2 条 (U1 hello + U2 meta)
//   - formatListAsLines 输出多行

const { assertEq } = require('./setup');

// topics.js 是浏览器全局 (window.VKBoxTopics), 也支持 CommonJS (module.exports)
const VKBoxTopics = require('../renderer/topics');

const SN = 'VK20261016001';

// 测 1: 11 个常量都在
const expected = [
  'PLATFORM_HELLO_TOPIC', 'PLATFORM_INFO_TOPIC', 'PLATFORM_RES_TOPIC',
  'PLATFORM_PUB_TOPIC', 'PLATFORM_EVENT_TOPIC', 'PLATFORM_REPLY_TOPIC',
  'PLATFORM_FPOST_TOPIC',
  'PLATFORM_GET_TOPIC', 'PLATFORM_FUNC_TOPIC',
  'PLATFORM_PSET_TOPIC', 'PLATFORM_PGET_TOPIC',
];
for (const k of expected) {
  assertEq(typeof VKBoxTopics[k] === 'string' && VKBoxTopics[k].length > 0, true, `${k} 存在且非空`);
}

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

// 测 5: formatListAsLines 输出多行
const lines = VKBoxTopics.formatListAsLines(extras);
assertEq(lines.indexOf('\n') >= 0, true, '输出包含换行');
assertEq(lines.split('\n').length, 2, '输出正好 2 行');
assertEq(lines.indexOf('U1 (hello):') >= 0, true, '第 1 行以 "U1 (hello):" 开头');
assertEq(lines.indexOf('U2 (meta):') >= 0, true, '第 2 行以 "U2 (meta):" 开头');
assertEq(VKBoxTopics.formatListAsLines([]), '', '空数组返回空串');

console.log('PASS: 22-fix - topics.js 11 个常量 + format + manualExtraTopics + formatListAsLines 5 类 12 个测试通过');
