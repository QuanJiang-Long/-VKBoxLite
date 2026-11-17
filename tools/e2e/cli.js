'use strict';
// tools/e2e/cli.js
//
// 命令行外壳: 解析参数 -> (可选)拉起 Electron -> 连 CDP -> 跑 journey -> 打印结果。
// 真机脚本 tools/real_device_e2e.js 和模拟器脚本 tools/sim_e2e.js 共用这一层,
// 差别只有默认目标串口和启动环境变量。

const fs = require('fs');
const os = require('os');
const path = require('path');
const { findPage, connect, makeEval, prepare, launchElectron, killTree, sleep, httpGetJson } = require('./cdp');
const { runJourney } = require('./journey');

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) { out._.push(a); continue; }
    const eq = a.indexOf('=');
    if (eq > 0) { out[a.slice(2, eq)] = a.slice(eq + 1); continue; }
    const key = a.slice(2);
    const next = argv[i + 1];
    if (next && !next.startsWith('--')) { out[key] = next; i++; }
    else out[key] = true;
  }
  return out;
}

const STATUS_ICON = { PASS: 'PASS', SKIP: 'SKIP', FAIL: 'FAIL' };

function printReport(kind, cfg, results, notes) {
  console.log('');
  console.log('===== ' + kind + ' 全流程跑测 =====');
  console.log('目标串口: ' + cfg.target);
  console.log('');
  let pass = 0, skip = 0, fail = 0;
  for (const r of results) {
    if (r.status === 'PASS') pass++;
    else if (r.status === 'SKIP') skip++;
    else fail++;
    const info = r.info === undefined || r.info === null ? ''
      : (typeof r.info === 'string' ? r.info : JSON.stringify(r.info));
    console.log(STATUS_ICON[r.status] + '  ' + r.name
      + (r.status === 'PASS' && !info ? '' : '  ::  ' + info.slice(0, 300))
      + '  (' + r.ms + 'ms)');
  }
  if (notes.length) {
    console.log('');
    console.log('--- 备注 ---');
    notes.forEach(n => console.log('* ' + n));
  }
  console.log('');
  console.log('结果: PASS=' + pass + '  SKIP=' + skip + '  FAIL=' + fail);
  if (skip) {
    console.log('SKIP 表示依赖外部条件（485 从站 / 4G / 总线流量），条件不满足时属正常。');
    console.log('产线验收可加 --expect-slave / --expect-net 把它们升级成 FAIL。');
  }
  if (fail) {
    console.log('有 FAIL：先看该步的 stMsg/toast，再对照 docs/real-device-e2e.md 的排查表。');
  }
  return fail;
}

/**
 * @param {object} spec
 * @param {string} spec.kind       '真机' / '模拟器'（打印用）
 * @param {(args:object)=>({target:string, env:object, preflight?:Function})} spec.resolve
 */
async function main(spec, argv) {
  const args = parseArgs(argv.slice(2));
  if (args.help || args.h) {
    console.log(spec.usage);
    return 0;
  }
  const repoRoot = path.resolve(__dirname, '..', '..');
  const debugPort = Number(args['debug-port'] || 9333);
  const downloadDir = path.resolve(args['download-dir']
    || path.join(os.tmpdir(), 'vkbox_e2e_dl'));
  fs.mkdirSync(downloadDir, { recursive: true });

  let resolved;
  try {
    resolved = spec.resolve(args, repoRoot);
  } catch (e) {
    console.error(String((e && e.message) || e));
    console.error(spec.usage || '');
    return 2;
  }
  const cfg = {
    target: resolved.target,
    label: spec.kind,
    real: spec.kind === '真机',
    downloadDir,
    // --read-only：只读巡检。不写配置、不切档、不导入、不切空闲。
    // 第一次接陌生设备（可能是客户现场机）时先跑这一档，保证不动设备状态。
    readOnly: !!args['read-only'],
    writeCfg: !args['no-write'] && !args['read-only'],
    restore: !args['no-restore'] && !args['read-only'],
    expectSlave: !!args['expect-slave'],
    expectNet: !!args['expect-net'],
    minMaxBlock: Number(args['min-max-block'] || 2048),
  };

  if (typeof resolved.preflight === 'function') {
    try { await resolved.preflight(); }
    catch (e) { console.error('[预检失败] ' + e.message); return 2; }
  }

  let child = null;
  let client = null;
  let exitCode = 0;
  const ensureCleanup = () => {
    try { if (client) client.close(); } catch (e) {}
    if (child && !args.keep) killTree(child.pid);
  };
  const onSignal = () => { ensureCleanup(); process.exit(130); };
  process.on('SIGINT', onSignal);

  try {
    if (args.launch) {
      console.log('[启动] Electron (debug port ' + debugPort + ') …');
      child = launchElectron(repoRoot, {
        debugPort,
        electronPath: args.electron,
        env: Object.assign({ VKBOX_DOWNLOAD_DIR: downloadDir }, resolved.env || {}),
      });
      await sleep(500);
      if (child.__launchError) throw child.__launchError;
    }

    const page = await findPage(debugPort, Number(args['wait'] || 25) * 1000);
    client = await connect(page.webSocketDebuggerUrl);
    const ev = makeEval(client);
    await prepare(client, debugPort, { downloadDir });

    console.log('[连接] ' + page.url);
    const t0 = Date.now();
    const { results, notes } = await runJourney({ ev, client, cfg });
    const fail = printReport(spec.kind, cfg, results, notes);
    console.log('总耗时: ' + Math.round((Date.now() - t0) / 1000) + 's');
    exitCode = fail ? 1 : 0;
  } catch (e) {
    console.error('[脚本错误] ' + (e && e.message ? e.message : e));
    exitCode = 2;
  } finally {
    ensureCleanup();
  }
  return exitCode;
}

module.exports = { main, parseArgs };
