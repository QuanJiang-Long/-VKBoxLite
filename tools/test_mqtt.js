// MQTT 连接测试脚本
const mqtt = require('mqtt');

// 平台凭证（从设备日志）
const options = {
  clientId: 'VL20261019002_',
  username: 'VL20261019002',
  password: 'VKBOXGW2026KEY',  // 用截图里的密码
  clean: true,
  keepalive: 60,
  reconnectPeriod: 0,  // 不自动重连
  connectTimeout: 10000
};

console.log('正在连接 MQTT...');
console.log('Broker: dz.voltkun.com:1883');
console.log('ClientId:', options.clientId);
console.log('Username:', options.username);

const client = mqtt.connect('mqtt://dz.voltkun.com:1883', options);

client.on('connect', function () {
  console.log('✅ 连接成功!');
  console.log('CONACK: 正常');
  client.end();
  process.exit(0);
});

client.on('error', function (err) {
  console.log('❌ 连接错误:', err.message);
  process.exit(1);
});

client.on('offline', function () {
  console.log('⚠️  连接离线');
  process.exit(1);
});

// 超时处理
setTimeout(function() {
  console.log('⏱️  连接超时');
  process.exit(1);
}, 15000);
