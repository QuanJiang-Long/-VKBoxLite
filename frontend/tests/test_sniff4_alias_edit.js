// test_sniff4_alias_edit.js
//
// sniff-4 (2026-10): 推断表的"参数名称 / 建议标识符"两列可编辑
//   - 前端: 点击单元格 → 弹窗改名 → 存设备 → 重推推断表
//   - 设备: R:SALIAS / W:SALIAS 两条指令 + fskv 别名表 ds_alias
//   - 生效: sniff 档的 U2 拓扑属性 id/name 与 U4 数据项 id/name 都用别名,
//     即平台上显示的就是用户起的名字
//
// 测的是"结构在不在" (源码文本断言), 不连设备

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const appJs = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'app.js'), 'utf8');
const protoJs = fs.readFileSync(path.join(__dirname, '..', 'protocol.js'), 'utf8');
const html = fs.readFileSync(path.join(__dirname, '..', 'renderer', 'index.html'), 'utf8');
const cmdLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'svc', 'cmd.lua'), 'utf8');
const iotLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'iot', 'iot.lua'), 'utf8');
const cfgLua = fs.readFileSync(path.join(__dirname, '..', '..', 'lua', 'cfg.lua'), 'utf8');

// === 1. 协议层: 两条别名指令 ===
assertEq(/aliasRead:\s*\(\)\s*=>\s*'R:SALIAS'/.test(protoJs), true,
  'sniff-4: protocol.js 有 aliasRead (R:SALIAS)');
assertEq(/aliasWrite:\s*\(o\)\s*=>\s*'W:SALIAS='/.test(protoJs), true,
  'sniff-4: protocol.js 有 aliasWrite (W:SALIAS=...)');

// === 2. 前端: 弹窗 + 保存 + 事件委托 ===
assertEq(/function askEditRegName\(/.test(appJs), true,
  'sniff-4: app.js 有 askEditRegName 弹窗');
assertEq(/function saveAlias\(/.test(appJs), true,
  'sniff-4: app.js 有 saveAlias 保存函数');
assertEq(/Protocol\.Enc\.aliasWrite\(/.test(appJs), true,
  'sniff-4: app.js 用 Enc.aliasWrite 下发');
assertEq(/class="ed-cell"/.test(appJs), true,
  'sniff-4: 推断表两列带 ed-cell 可编辑标记');
assertEq(/data-alias-field="name"/.test(appJs), true,
  'sniff-4: 参数名称列带 data-alias-field=name');
assertEq(/data-alias-field="id"/.test(appJs), true,
  'sniff-4: 建议标识符列带 data-alias-field=id');
assertEq(/inferTbody\.addEventListener\('click'/.test(appJs), true,
  'sniff-4: inferTbody 上有 click 事件委托 (表格重绘不丢绑定)');
// 弹窗要有输入框 + 预览 + 保存/恢复默认/取消
assertEq(/id="edName"/.test(appJs) && /id="edId"/.test(appJs), true,
  'sniff-4: 弹窗有参数名称/标识符两个输入框');
assertEq(/edPreview/.test(appJs), true, 'sniff-4: 弹窗有上报内容预览');
assertEq(/edReset/.test(appJs), true, 'sniff-4: 弹窗有恢复默认按钮');

// === 3. 样式: 可编辑单元格 ===
assertEq(/\.ed-cell\{/.test(html), true, 'sniff-4: index.html 有 .ed-cell 样式');

// === 4. 设备端: 指令 + 持久化槽 ===
assertEq(/M\.reg\("R:SALIAS"/.test(cmdLua), true, 'sniff-4: cmd.lua 注册 R:SALIAS');
assertEq(/M\.reg\("W:SALIAS"/.test(cmdLua), true, 'sniff-4: cmd.lua 注册 W:SALIAS');
assertEq(/K_ALIAS\s*=\s*"ds_alias"/.test(cfgLua), true,
  'sniff-4: cfg.lua 有别名表槽 ds_alias');
assertEq(/function M\.normalize_alias/.test(cfgLua), true,
  'sniff-4: cfg.lua 有 normalize_alias 校验');
assertEq(/function M\.set_alias/.test(cfgLua), true,
  'sniff-4: cfg.lua 有 set_alias 单条 upsert');
assertEq(/alias\s*=\s*\{ key = K_ALIAS/.test(cfgLua), true,
  'sniff-4: 别名表进了 SECTIONS (有 load_alias/save_alias)');

// === 5. 生效链路: 别名要同时管住拓扑(U2)与数据(U4)与推断表 ===
assertEq(/cfgstore\.alias_map\(\)/.test(iotLua), true,
  'sniff-4: iot.lua 用别名表');
assertEq(/r\.pid/.test(iotLua), true,
  'sniff-4: node_json 支持 pid/pname (拓扑属性用别名)');
// 12-fix-9: 名字不再挂到行上(那会给活着的行加第 9/10 个字段, 哈希槽 8→16,
//   每行 203→363 字节), 改成顶层 names 表 —— 行一个字段都不加, 零复制。
assertEq(/out\.names\s*=\s*names/.test(iotLua), true,
  'sniff-4: attach_names 把名字挂到顶层 names 表 (12-fix-9)');
assertEq(/names\[k\]\s*=\s*\{\s*id\s*=\s*id,\s*name\s*=\s*name\s*\}/.test(iotLua), true,
  'sniff-4: names 表的条目是 {id, name}');
assertEq(/a\.id\s*=/.test(iotLua), false,
  'sniff-4: attach_names 不再给行就地加 id (12-fix-9, 省堆)');
// 前端: 显示名字时先查 names 表, 查不到退回 reg<addr>
assertEq(/S\.inferNames\[akey\]/.test(appJs), true,
  'sniff-4: 前端从 names 表取名字 (12-fix-9)');
assertEq(/out\.regs\s*=\s*inf\.regs/.test(iotLua), true,
  'sniff-4: attach_names 不复制行 (12-fix-9, 零复制)');

console.log('PASS: sniff-4 推断表参数名称/建议标识符可编辑 (弹窗+存设备+上报生效, 18 个测试点通过)');
