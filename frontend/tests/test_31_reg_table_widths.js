// test_31_reg_table_widths.js
//
// 31-fix: 寄存器表 "标识符" 列改为固定宽度 110px (和参数名称一样),
//         "值" 列从 170px 缩短到 130px
//
// 3 处表格 (manual / platform / poll) 都要改

const fs = require('fs');
const path = require('path');
const { assertEq } = require('./setup');

const indexHtml = fs.readFileSync(
  path.join(__dirname, '..', 'renderer', 'index.html'),
  'utf8'
);

// 测 1: 标识符 列有固定宽度 110px (在 3 个 param-table 中)
const hasIdentifierWidth = (() => {
  // 匹配 "<th style="width:110px;">标识符</th>"
  // 但不匹配 参**数**名**称 (顺序: 标识符 在 参**数**名**称 之前)
  const re = /<th\s+style="width:110px;">标识符<\/th>/g;
  const matches = indexHtml.match(re) || [];
  return matches.length;
})();
assertEq(hasIdentifierWidth, 3, '3 个 param-table 都给标识符列设了 width:110px (found ' + hasIdentifierWidth + ')');

// 测 2: 没有 "<th>标识符</th>" 不带宽度的 (应该 0 个)
const hasBareIdentifier = (() => {
  const re = /<th>标识符<\/th>/g;
  const matches = indexHtml.match(re) || [];
  return matches.length;
})();
assertEq(hasBareIdentifier, 0, '不应再有 "<th>标识符</th>" 不带宽度的写法');

// 测 3: 值 列从 170px 缩短到 130px (3 个)
const has130Val = (() => {
  const re = /<th\s+style="width:130px;">值<\/th>/g;
  const matches = indexHtml.match(re) || [];
  return matches.length;
})();
assertEq(has130Val, 3, '3 个 param-table 都把值列改成 width:130px');

// 测 4: 没有 170px 的值列 (应该 0 个)
const has170Val = (() => {
  const re = /<th\s+style="width:170px;">值<\/th>/g;
  const matches = indexHtml.match(re) || [];
  return matches.length;
})();
assertEq(has170Val, 0, '不应再有 width:170px 的值列');

// 测 5: 参数名称 110px 仍在 (3 个, 验证没误改)
const hasParamName110 = (() => {
  const re = /<th\s+style="width:110px;">参数名称/g;
  const matches = indexHtml.match(re) || [];
  return matches.length;
})();
assertEq(hasParamName110, 3, '参数名称 110px 仍存在 (3 个)');

console.log('PASS: 31-fix - 标识符列固定 110px + 值列缩短到 130px (5 个测试点通过)');
