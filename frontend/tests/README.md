# 单元测试 (Unit Tests)

> 防回归. 每次改 app.js / index.html 后跑一遍, 8 个核心场景 1 秒内过完.

## 跑测试

```bash
cd frontend
npm test                    # 跑全部
node tests/run.js           # 同样
node tests/test_2q_radio_isolation.js   # 跑单个
```

## 框架特点

- **零依赖** - 只用 Node.js 内置 (vm, child_process, fs), 不引入 mocha/jest
- **子进程隔离** - 每个 test_*.js 是独立进程, 一个挂了不影响其它
- **vm sandbox** - 测试里需要重新定义被测函数 (e.g. cfgSnap), 用 vm 隔离全局
- **失败 exit 1** - 跑前 CI 能检测到 (后配)

## 文件结构

```
tests/
├── README.md          # 本文件
├── run.js             # 跑所有 test_*.js, 汇总 pass/fail
├── setup.js           # 共享 mock helpers (makeEl, makeRadioGroup, assert...)
├── test_2k_*.js       # 2k 修复的回归 (placeholder)
├── test_2l_*.js       # 2l 修复的回归 (homeTimer 不再调 readMqtt)
├── test_2m_*.js       # 2m 修复的回归 (4 个 mBtnMqtt* onclick 绑定)
├── test_2n_*.js       # 2n 修复的回归 (mqSnap 走档位)
├── test_2o_*.js       # 2o 修复的回归 (3 pane 内 input 绑 dirty)
├── test_2p_*.js       # 2p 修复的回归 (3 pane 都绑 input+change)
├── test_2q_*.js       # 2q 修复的回归 (radio 3 group 隔离)
└── test_2s_*.js       # 2s 修复的回归 (refreshCfgDirty 不传 Event 对象)
```

## 8 个测试对应 2k-2s 修复

| 测试 | 修了什么 | 跑时间 |
|---|---|---|
| test_2k_placeholder | manual 5 字段 placeholder | ~80ms |
| test_2l_timer_removed | homeTimer 5s 拿掉 readMqtt(true) | ~80ms |
| test_2m_button_bindings | manual 4 个 mqtt 按钮 onclick | ~80ms |
| test_2n_mq_dirty | mqSnap 走档位 | ~80ms |
| test_2o_input_dirty | 3 pane 内 input 绑 dirty | ~80ms |
| test_2p_pane_event | 3 pane 都绑 input+change | ~80ms |
| test_2q_radio_isolation | 3 pane radio 名字加前缀 (互不干扰) | ~80ms |
| test_2s_event_arg | refreshCfgDirty 箭头函数包装 | ~80ms |

## 怎么写新测试

参考 `test_2q_radio_isolation.js` 的结构:

1. `const { makeEl, makeRadioGroup, ... } = require('./setup')` 引入 helpers
2. mock 控件 (用 makeEl, makeIds)
3. `vm.createContext + vm.runInContext` 定义被测函数 + 跑
4. `assertEq(actual, expected, '说明')` / `assertTrue(cond, '说明')` 断言
5. 最后 `console.log('PASS: <测试名>')`
6. 失败时 throw (assertEq/assertTrue 内部 throw), run.js 会捕获并标记 FAIL

## 不要做的事

- ❌ 引入 mocha/jest/ava (大框架, 1 秒目标守不住)
- ❌ require 真实的 app.js (它是浏览器环境代码, 不会跑)
- ❌ 在 test 文件里 setTimeout/网络 (子进程要快)
- ❌ 测试之间共享 state (子进程隔离, 共享也拿不到)

## 后续

- 等业务加新功能 (e.g. 多协议) 时, 给新功能加 test_*.js
- 加 CI (e.g. .github/workflows/test.yml) 跑 `npm test`
- 2g 拆模块时, 拆完一个文件就给它写 test_*.js, 边拆边测
