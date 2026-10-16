//=====================================================================
// reg.js - 寄存器表格 CRUD / 弹窗 / 验证
//
// 从 app.js 拆出 (2g-3 refactor, 物理拆分不改逻辑)
// 依赖: 全局 S (state), el (Proxy), E(), cfgPrefix(), $(), refreshCfgDirty(),
//       askConfirm() 在 app.js, fillOk/toast() 等
// 注: collectRegs() 和 badRegRow() 在 cfg.js 里 (跟 saveCfg 流程一起)
//=====================================================================

//---------------------------------------------------------------------
// 寄存器表格
//---------------------------------------------------------------------
const ALL_TYPES = ['uint16', 'int16', 'uint32', 'int32', 'float32', 'uint64', 'int64', 'float64'];

function renderRegTable(pre) {
  // Step 2e: 拆 m/p 分支, pre 由 readCfg/readCfgSilent/activateTab 传入
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  // 两种情况都不重建 DOM：
  // ① 焦点正在参数表里 —— 重建会丢焦点、冲掉刚打的字；
  // ② 对应 tab 标签页不可见且表里已有真实数据行 —— 切走时浏览器会把焦点里的
  //    输入框 blur 掉，activeElement 变成 <body>，只判焦点会漏。
  //    ⚠️ 必须确认表里真的有 .c-addr 行才跳过：空表/占位行时该渲染
  const ae = document.activeElement;
  if (ae && ae.closest && tbody.contains && tbody.contains(ae)) return;
  const tabName = pre ? (pre === 'm' ? 'tabManual' : 'tabPlatform') : 'tabPoll';
  const pane = $(tabName);
  if (pane && !pane.classList.contains('active') && tbody.querySelector && tbody.querySelector('.c-addr')) return;
  tbody.innerHTML = '';
  const rows = toArr(S.regs);
  if (rows.length === 0) {
    const tr = document.createElement('tr');
    tr.innerHTML = '<td colspan="8" style="color:#999;padding:14px;">暂无寄存器，点「新增寄存器」添加</td>';
    tbody.appendChild(tr);
    return;
  }
  rows.forEach(r => addRegRow(pre, r.addr, r.dtype || r.type, r.name, r.alias, r.count));
}

function addRegRow(pre, addr, type, name, alias, count) {
  if (pre === undefined) pre = cfgPrefix();
  const tbody = E(pre, 'paramTbody');
  const tr = document.createElement('tr');
  const opts = ALL_TYPES
    .map(t => '<option' + (t === type ? ' selected' : '') + '>' + t + '</option>').join('');
  tr.innerHTML =
    '<td><input class="c-addr" type="number" value="' + addr + '"></td>' +
    '<td><select class="c-type">' + opts + '</select></td>' +
    '<td><input class="c-count" type="number" value="' + (count || 1) + '" min="1" max="125"></td>' +
    '<td><input class="c-name" type="text" value="' + esc(name || '') + '"></td>' +
    '<td><input class="c-alias" type="text" value="' + esc(alias || '') + '" ' +
    'title="MQTT 上报 name 字段的中文名，留空则用标识符"></td>' +
    '<td class="val-cell"><input class="c-val" type="text" value="" readonly></td>' +
    '<td class="ts-cell"><input class="c-ts" type="text" value="" readonly></td>' +
    '<td><button class="btn-del" onclick="deleteRow(this)">删除</button></td>';
  // 空表提示行没有 .c-addr，新增第一行前先删掉，否则它会和真实数据行并存，
  // 界面同时显示"暂无寄存器"和一个寄存器，自相矛盾
  const ph = tbody.querySelector && tbody.querySelector('tr td[colspan]');
  if (ph) ph.parentNode.removeChild(ph);
  tbody.appendChild(tr);
  // 新增行也要遵守当前模式的锁态: platform/sniff 下不该有「删除」键
  if (!isManual(S.mode)) {
    tr.querySelectorAll('input, select').forEach(e => {
      if (e.classList.contains('c-val') || e.classList.contains('c-ts')) return;
      // select 没有 readonly, 用 disabled
      if (e.tagName === 'SELECT') e.disabled = true;
      else e.readOnly = true;
      e.classList.add('ro');
    });
    const delBtn = tr.querySelector('.btn-del');
    if (delBtn) delBtn.style.display = 'none';
  }
  refreshCfgDirty(pre);                // 增行是 DOM 操作，不触发 input 事件，得手动标脏
}

function deleteRow(btn) {
  btn.closest('tr').remove();
  refreshCfgDirty();                   // 删行同理
}

function addParamRow() {
  $('regAddr').value = 1;
  $('regType').value = '';
  $('regId').value = '';
  $('regAlias').value = '';
  $('regCount').value = 1;
  regErr('');                                   // 上次的错误提示不能留着
  $('modalAddReg').style.display = 'flex';
}

function closeModal() { $('modalAddReg').style.display = 'none'; }

function confirmAddReg() {
  const addr = $('regAddr').value;
  const type = $('regType').value;
  const phyId = $('regId').value;
  const alias = $('regAlias').value.trim();
  const cnt = parseInt($('regCount').value, 10);
  // 错误提示写在弹窗里：alert() 是原生模态框，关掉后会让整个窗口丢失
  // 前台激活（详见 askConfirm 的注释），弹窗内的输入框也会跟着打不了字
  if (!type) { regErr('请选择数据类型'); return; }
  if (!addr || !cnt) { regErr('寄存器地址、寄存器个数不能为空'); return; }
  const W = { uint32: 2, int32: 2, float32: 2, uint64: 4, int64: 4, float64: 4 };
  const w = W[type] || 1;
  if (cnt % w !== 0) { regErr(type + ' 占 ' + w + ' 个寄存器，个数需为 ' + w + ' 的整数倍'); return; }
  if (!/^\w+$/.test(phyId.trim())) { regErr('标识符只能含字母、数字、下划线'); return; }
  if (phyId.trim().length > 16) { regErr('标识符最长 16 字符'); return; }
  // Step 2e: 传当前档位 pre 给 addRegRow, 让行加到 m/p 各自 tab 的 paramTbody
  addRegRow(cfgPrefix(), parseInt(addr, 10), type, phyId.trim(), alias, cnt);
  regErr('');
  closeModal();
}
