// test_32_pub_topics.js
//
// 32-fix: 设备端 profile() / M.status() 实际发送的 topic 列表 (pub_topics)
//         前端 mqStPub 优先用 pub_topics 渲染, 老设备回退到 s.pub
//
// 修改:
//   设备 lua/iot/mqttcfg.lua:
//     profile() 手动档返回: pub_topics = { resolved_pub_topic }
//     profile() 平台档返回: pub_topics = { base .. "-1" }
//   设备 lua/iot/iot.lua:
//     M.status() 返回: pub_topics = prof and prof.pub_topics
//   前端 frontend/renderer/mqtt.js:
//     setKvPre('mqStPub', pub_topics.join('\n'), ...) 优先用 s.pub_topics
//   前端 MOCK 模拟:
//     R:PULLCFG / R:MQTT 加上 pub_topics 字段

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const mqttcfg = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'iot', 'mqttcfg.lua'), 'utf8');
const iot     = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'iot', 'iot.lua'), 'utf8');
const mqttJs  = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'mqtt.js'), 'utf8');
const appJs   = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// === 设备端 mqttcfg.lua ===

// 测 1: 手动档返回 pub_topics (单元素 list, 原样)
assertEq(/if c\.manual_on then[\s\S]*?pub_topics\s*=\s*p\s+and\s+\{\s*p\s*\}\s+or\s+\{\s*\}/.test(mqttcfg),
  true, 'mqttcfg.lua 手动档 profile() 返回 pub_topics');

// 测 2: 平台档返回 pub_topics (单元素 list, 带 -1)
assertEq(/return\s*\{[\s\S]*?user\s*=\s*"",\s*pass\s*=\s*c\.auto\.pass,[\s\S]*?pub_topics\s*=\s*pub\s+and\s+\{\s*pub\s*\.\.\s*"-1"\s*\}\s+or\s+\{\s*\}/.test(mqttcfg),
  true, 'mqttcfg.lua 平台档 profile() 返回 pub_topics 带 -1 后缀');

// 测 3: 32-fix 注释存在
assertEq(mqttcfg.indexOf('32-fix') >= 0, true, 'mqttcfg.lua 含 32-fix 注释');

// === 设备端 iot.lua M.status() ===

// 测 4: M.status() 返回 pub_topics
assertEq(/pub_topics\s*=\s*prof\s+and\s+prof\.pub_topics/.test(iot),
  true, 'iot.lua M.status() 返回 prof.pub_topics');

// 测 5: 32-fix 注释存在
assertEq(iot.indexOf('32-fix') >= 0, true, 'iot.lua 含 32-fix 注释');

// === 前端 mqtt.js ===

// 测 6: 优先用 s.pub_topics
assertEq(/s\.pub_topics\s*&&\s*s\.pub_topics\.length/.test(mqttJs),
  true, 'mqtt.js 优先用 s.pub_topics');

// 测 7: 回退到 s.pub (向后兼容)
assertEq(/s\.pub_topics\s*&&\s*s\.pub_topics\.length[\s\S]{0,100}\?[^:?]+\:\s*\(\s*s\.pub/.test(mqttJs),
  true, 'mqtt.js 在 s.pub_topics 缺失时回退到 s.pub');

// 测 8: 多行显示 (join with \n)
assertEq(/pub_topics\.join\(\s*['"]\\n['"]\s*\)/.test(mqttJs) ||
         /pubTopics\.join\(\s*['"]\\n['"]\s*\)/.test(mqttJs),
  true, 'mqtt.js 用 \\n 连接多个 topic');

// 测 9: 32-fix 注释
assertEq(mqttJs.indexOf('32-fix') >= 0, true, 'mqtt.js 含 32-fix 注释');

// === 前端 MOCK ===

// 测 10: MOCK R:PULLCFG 返回 pub_topics
//   检查 R:PULLCFG 段 (line 1987+)
const pullCfgSection = appJs.match(/else if \(line === 'R:PULLCFG'\)[\s\S]+?\}\s*\}/);
assertEq(!!pullCfgSection, true, '能找到 MOCK R:PULLCFG 段');
if (pullCfgSection) {
  assertEq(/pub_topics/.test(pullCfgSection[0]), true,
    'MOCK R:PULLCFG 返回 pub_topics');
}

// 测 11: MOCK R:MQTT 返回 pub_topics
const mqttSection = appJs.match(/else if \(line === 'R:MQTT'\)[\s\S]+?\}\s*\}/);
assertEq(!!mqttSection, true, '能找到 MOCK R:MQTT 段');
if (mqttSection) {
  assertEq(/pub_topics/.test(mqttSection[0]), true,
    'MOCK R:MQTT 返回 pub_topics');
}

console.log('PASS: 32-fix - 设备返回 pub_topics 列表, 前端优先显示 (11 个测试点通过)');
