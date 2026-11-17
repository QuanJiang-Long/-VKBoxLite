#!/usr/bin/env node
'use strict';
// tools/sim_e2e.js
//
// 模拟器全流程跑测 —— 和真机脚本跑的是同一份 journey, 只是目标串口换成
// frontend/main.js 里的模拟器伪串口 sim://127.0.0.1:<webc>/uart31。
//
// 用法:
//   # 先起模拟器（工作目录 = 装好固件+补丁的 staging）
//   .simulator/LuatOS_PC/luatos-pc-64bit.exe . --webc=18921 --noexit
//   # 再跑脚本（--launch 会自己拉起 Electron 并设好 VKBOX_SIM_WEBC）
//   node tools/sim_e2e.js --webc 18921 --launch
//
// 说明:
//   - 模拟器只验证软件链路, 不验证 485 电气层/时序/内存/掉电保持;
//     预置步骤见 docs/simulator-e2e.md。
//   - 模拟器没有 485 从站、没有 4G, 所以第 11/13/14/15 步会 SKIP。

const { main } = require('./e2e/cli');
const { httpGetJson } = require('./e2e/cdp');

const USAGE = `
模拟器全流程跑测

  node tools/sim_e2e.js --webc 18921 --launch

前提:
  1. 模拟器已启动: luatos-pc-64bit.exe . --webc=18921 --noexit
     （staging 里必须把 sn/prov.lua 和 svc/cmd.lua 的 UART_ID 改成 31,
       否则前端只"收得到、看不到回包", 详见 docs/simulator-e2e.md）
  2. 应用需带 VKBOX_SIM_WEBC=<webc> 启动（--launch 会自动设）
`;

main({
  kind: '模拟器',
  usage: USAGE,
  resolve(args) {
    const webc = Number(args.webc || process.env.VKBOX_SIM_WEBC || 18921);
    const target = args.target || ('sim://127.0.0.1:' + webc + '/uart31');
    return {
      target: String(target),
      env: { VKBOX_SIM_WEBC: String(webc) },
      preflight: async () => {
        try {
          const h = await httpGetJson('http://127.0.0.1:' + webc + '/api/health', 2500);
          console.log('[预检] 模拟器在线: ' + JSON.stringify(h));
        } catch (e) {
          throw new Error('模拟器 Web Console 不可达 (127.0.0.1:' + webc + ')\n'
            + '  先起模拟器: luatos-pc-64bit.exe . --webc=' + webc + ' --noexit\n'
            + '  （工作目录要用装好固件和 UART_ID=31 补丁的 staging）');
        }
      },
    };
  },
}, process.argv)
  .then(code => process.exit(code))
  .catch(e => { console.error('[脚本错误] ' + (e && e.message ? e.message : e)); process.exit(2); });
