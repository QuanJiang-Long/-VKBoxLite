#!/usr/bin/env node
'use strict';
// tools/real_device_e2e.js
//
// 真机全流程跑测（Air780EP + 485）。驱动的是【真实 Electron 界面】，
// 所以测到的就是用户点得出来的那条路。
//
// 用法:
//   node tools/real_device_e2e.js --port COM32 --launch
//   node tools/real_device_e2e.js --port COM32            # 连已在跑的应用
//
// 常用开关:
//   --launch            自己拉起 Electron（会设好 VKBOX_DOWNLOAD_DIR，导出不弹原生保存框）
//   --debug-port 9333   调试端口（--launch 时自动带）
//   --no-write          只读巡检，不写设备配置
//   --no-restore        切完 idle 不把配置导回去（默认会还原，保护现场设备）
//   --expect-slave      R:VAL 没值算 FAIL（产线验收用）
//   --expect-net        MQTT 未就绪算 FAIL（产线验收用）
//   --min-max-block N   R:MEM 连续块下限，默认 2048
//   --keep              测完不关应用
//   --download-dir D    导出落盘目录

const { main } = require('./e2e/cli');

const USAGE = `
真机全流程跑测

  node tools/real_device_e2e.js --port COM32 --launch

前台检查（脚本管不到的部分）:
  1. 模组烧好本仓库固件, USB 口枚举成 COMx（设备管理器看得到）
  2. 没有别的串口工具占着这个口（SSCOM / 上位机 / 另一个本工具实例）
  3. 485 接线: A/B 不接反, 共地, 总线上 120Ω 终端电阻（长线/多从站时）
  4. 从站地址、功能码、寄存器地址与「手动配置」里的表一致

判定:
  FAIL = 软件链路该过没过
  SKIP = 依赖外部条件（从站/4G/总线流量）不满足, 属正常
`;

main({
  kind: '真机',
  usage: USAGE,
  resolve(args) {
    const port = args.port || args.target;
    if (!port) {
      throw new Error('缺少 --port。先确认模组的 COM 口（设备管理器），例如:\n'
        + '  node tools/real_device_e2e.js --port COM32 --launch');
    }
    return { target: String(port), env: {} };
  },
}, process.argv)
  .then(code => process.exit(code))
  .catch(e => { console.error('[脚本错误] ' + (e && e.message ? e.message : e)); process.exit(2); });
