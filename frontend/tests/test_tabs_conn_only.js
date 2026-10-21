// test_tabs_conn_only.js
//
// 2026-10: 档位标签(sniff模式/manual模式/platform模式)只在【串口已连接】时显示。
//   没连设备时 S.mode 还是上次会话的残留, 挂着"sniff模式"标签会让人以为
//   设备还在 sniff —— 未连接时只该有"首页"和"运行模式"两个标签。
//   断连时还要把停在档位页的视图切回首页(否则留一个没标签的页面)。

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. syncTabs 里档位标签都带 conn 判断
const syncStart = appJs.indexOf('function syncTabs');
assertEq(syncStart > 0, true, 'tabs: 找到 syncTabs');
const syncBody = appJs.substring(syncStart, syncStart + 2400);
assertEq(/const conn = !!S\.open/.test(syncBody), true,
  'tabs: syncTabs 取连接状态 conn = !!S.open');
for (const [id, expr] of [['tabManual', 'isManual(mode)'], ['tabPlatform', 'isPlatform(mode)'],
                          ['tabSniff', "mode === 'sniff'"]]) {
  assertEq(new RegExp('conn\\s*&&\\s*' + expr.replace(/[()'=]/g, '\\$&')).test(syncBody), true,
    `tabs: ${id} 的显示条件带 conn (未连接不显示)`);
}

// 2. 断连时 syncTabs 要被调一次 (否则标签要等下次切档才更新)
const portState = appJs.substring(appJs.indexOf('function setPortState'),
  appJs.indexOf('function setPortState') + 4000);
assertEq(/syncTabs\(\)/.test(portState), true,
  'tabs: setPortState 里调 syncTabs (连/断都同步标签)');

// 3. 断连且停在档位页时切回首页
assertEq(/if \(!open\)[\s\S]{0,400}activateTab\('tab0'\)/.test(portState), true,
  'tabs: 断连时若停在档位页, 切回首页');

console.log('PASS: tabs 档位标签仅串口已连接时显示 + 断连切回首页 (5 个测试点通过)');
