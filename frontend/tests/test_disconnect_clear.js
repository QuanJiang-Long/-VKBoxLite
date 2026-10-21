// test_disconnect_clear.js
//
// 2026-10: 断开串口后, 页面里"从设备读来的值"必须清空。
//   留着会让人以为设备还在线、还停在那个档位(截图上"串口已关闭"但
//   页面仍显示 sniff/正常/SN/IMEI 的状态最容易误判)。
//   清: 设备信息只读框 + 所有状态卡显示值(.kv-grid) + 底栏设备/模式/MQTT
//   留: 首页 MQTT 的服务器地址/端口/凭证密码(本地配置, 重连还要用)

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');

// 1. 有 clearDeviceView 函数
assertEq(/function clearDeviceView\(\)/.test(appJs), true,
  'disconnect: 有 clearDeviceView 函数');

// 2. 断连时调用它
const portState = appJs.substring(appJs.indexOf('function setPortState'),
  appJs.indexOf('function setPortState') + 5000);
assertEq(/if \(!open\)[\s\S]{0,600}clearDeviceView\(\)/.test(portState), true,
  'disconnect: setPortState 断连分支调 clearDeviceView');

// 3. 清哪些
const fn = appJs.substring(appJs.indexOf('function clearDeviceView'),
  appJs.indexOf('function clearDeviceView') + 2500);
for (const id of ['fSn', 'fImei', 'fIccid', 'fCsq', 'fVer', 'fProj', 'fUrl']) {
  assertEq(fn.includes(id), true, `disconnect: 设备信息 ${id} 被清`);
}
assertEq(/\.kv-grid \.kv span/.test(fn), true,
  'disconnect: 状态卡显示值(.kv-grid .kv span) 被清');
assertEq(/\.kv-pre/.test(fn), true,
  'disconnect: 其他生效 Topic(pre) 被清');
for (const id of ['stSn', 'stDev', 'stMode', 'stMqtt']) {
  assertEq(fn.includes(id), true, `disconnect: 底栏 ${id} 被清`);
}

// 4. 保留的: 服务器地址/端口/凭证密码 是本地配置, 不能清
assertEq(!/hMqHost\.value = ''/.test(fn), true,
  'disconnect: MQTT 服务器地址保留(本地配置)');
assertEq(!/hMqPort\.value = ''/.test(fn), true,
  'disconnect: MQTT 端口保留(本地配置)');
assertEq(!/hMqPass\.value = ''/.test(fn), true,
  'disconnect: MQTT 凭证密码保留(本地配置)');

console.log('PASS: disconnect 断连清屏 — 设备信息/状态卡/底栏清空, 本地 MQTT 配置保留 (14 个测试点通过)');
