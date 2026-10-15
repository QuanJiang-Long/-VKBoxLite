// 共享 mock helpers for tests/
//
// 目的: 把 2k-2s 期间写的 .tmp_check_*.js 临时测试脚本里的 mock 抽出来,
//       让 8 个回归测试都能 require 使用, 不再复制粘贴
//
// 原则:
// - 简单. 不引入 mocha/jest 这种大框架
// - 隔离. 每个 test_*.js 自己 setUp, 跑完清干净
// - 真实. mock 贴近真实 DOM 行为, 不写魔法

// ---- makeEl: 造一个假的 DOM 元素 ----
//
// 真实场景里, 控件有: value, checked, textContent, addEventListener,
// classList, appendChild, contains 等等. 我们给一个最小可用的版本.
//
// 用法: const el = makeEl({ value: '9600' });
function makeEl(init = {}) {
  const el = {
    _tag: 'x',
    value: init.value !== undefined ? init.value : '',
    textContent: init.textContent !== undefined ? init.textContent : '',
    checked: init.checked !== undefined ? init.checked : false,
    hidden: init.hidden !== undefined ? init.hidden : false,
    disabled: init.disabled !== undefined ? init.disabled : false,
    readOnly: init.readOnly !== undefined ? init.readOnly : false,
    type: init.type !== undefined ? init.type : 'text',
    title: '',
    style: {},
    addEventListener: () => {},
    classList: {
      add: () => {}, remove: () => {}, toggle: () => {}, contains: () => false,
    },
    appendChild: () => {},
    contains: () => false,
    closest: () => null,
    getAttribute: () => null,
    setAttribute: () => {},
    removeAttribute: () => {},
  };
  return el;
}

// ---- makeIds: 给一组 id 列表造 el 元素 ----
//
// 用法: const ids = makeIds(['mSelBaud', 'mInpSlave']);
// 返回 { mSelBaud: makeEl({...}), mInpSlave: makeEl({...}) }
function makeIds(idList, defaults = {}) {
  const ids = {};
  for (const id of idList) {
    const init = defaults[id] || {};
    ids[id] = makeEl(init);
  }
  return ids;
}

// ---- makeRadioGroup: 造一组 radio ----
//
// 真实场景里, 一组 radio 是多个 <input type="radio" name="X" value="Y">,
// 共享同一个 name, 一次只能有一个 checked.
//
// 用法: const radios = makeRadioGroup('m-databits', ['8', '7'], '8');
//       // name='m-databits', 值是 8/7, 默认 checked 是 8
function makeRadioGroup(name, values, defaultChecked) {
  const radios = [];
  for (const v of values) {
    radios.push({ name, value: v, checked: v === defaultChecked });
  }
  return radios;
}

// ---- makeRadioDoc: 造一个 mock document 对象, 支持 radioVal/setRadio ----
//
// 给一组 radio 数组, 包装成 { querySelector, querySelectorAll }
// 像真实 document 一样按 name 过滤, 按 :checked 选 checked 的那个
function makeRadioDoc(allRadios) {
  return {
    querySelector: (sel) => {
      const m = sel.match(/^input\[name="([^"]+)"\]:checked$/);
      if (!m) return null;
      return allRadios.find(r => r.name === m[1] && r.checked) || null;
    },
    querySelectorAll: (sel) => {
      const m = sel.match(/^input\[name="([^"]+)"\]$/);
      if (!m) return [];
      return allRadios.filter(r => r.name === m[1]);
    },
  };
}

// ---- assertEq: 简单的断言, 不相等就抛 ----
//
// 用法: assertEq(actual, expected, 'mSelBaud should be 9600');
function assertEq(actual, expected, msg) {
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a !== e) {
    throw new Error(`FAIL: ${msg}\n  expected: ${e}\n  actual:   ${a}`);
  }
}

// ---- assertTrue: 简单的真值断言 ----
function assertTrue(cond, msg) {
  if (!cond) {
    throw new Error(`FAIL: ${msg}\n  expected: true\n  actual:   ${cond}`);
  }
}

// ---- assertContains: 字符串包含断言 ----
function assertContains(haystack, needle, msg) {
  if (!String(haystack).includes(String(needle))) {
    throw new Error(`FAIL: ${msg}\n  expected to contain: ${needle}\n  actual: ${haystack}`);
  }
}

module.exports = {
  makeEl, makeIds, makeRadioGroup, makeRadioDoc,
  assertEq, assertTrue, assertContains,
};
