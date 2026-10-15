// test_2k_placeholder.js
//
// 回归: 2k 改了 manual 5 字段 placeholder + 设备端删 pub_topic/sub_topic 默认路径
// Bug: manual 5 字段 (mMqUser/mMqPass/mMqClientId/mMqPub/mMqSub) 没有
//      placeholder, 用户不知道填什么
// 修:  HTML 加 placeholder 提示
//
// 测什么: HTML 文件里 manual 5 字段都有 placeholder 属性

const fs = require('fs');
const path = require('path');
const { assertContains, assertTrue } = require('./setup');

const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');

// 5 个 manual mqtt 字段都应该有 placeholder
const fields = [
  { id: 'mMqUser',     ph: 'username' },
  { id: 'mMqPass',     ph: 'password' },
  { id: 'mMqClientId', ph: 'client id' },
  { id: 'mMqPub',      ph: 'pub' },
  { id: 'mMqSub',      ph: 'sub' },
];

for (const f of fields) {
  // 找 id="X" 那行, 看它后面 200 字里有没有 placeholder="Y"
  const m = html.match(new RegExp(`id="${f.id}"[^>]*placeholder="([^"]*)"`));
  assertTrue(m !== null, `${f.id} 有 placeholder 属性`);
  // 不严格匹配文本, 只确保 placeholder 不空 (不同 commit 可能改文本)
  assertTrue(m[1].length > 0, `${f.id} placeholder 不为空`);
}

console.log('PASS: 2k - manual 5 字段 (mMqUser/Pass/ClientId/Pub/Sub) 都有 placeholder');
