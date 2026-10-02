//=====================================================================
// protocol.js - 设备通讯协议编解码（浏览器/Electron 通用）
// 设备协议：一行一条指令 -> RET:xxx 应答，\r\n 结尾
// 与 lua/svc/vcom.lua 注册的指令一一对应
//=====================================================================
(function (global) {

  // ---------- 编码：前端 -> 设备 ----------
  // 与 lua/svc/vcom.lua 的 reg_cmds() 一一对应
  // ⚠️ 设备成功应答一律带 key（RET:CFG=OK），前端按 cmd 匹配
  const Enc = {
    // 读设备信息（SN/IMEI/ICCID/信号/版本/项目/服务器/波特率/从机/寄存器数）
    info: () => 'R:INFO',
    // 读 SN 状态。前端不用，但【产线烧写软件的回读校验通道】，删了会卡住上锁，
    // 保留以维持与设备端指令集一一对应。详见 lua/sn/prov.lua 的警告注释
    sn: () => 'R:SN',
    // 读芯片身份（产线指令，imei/uid/sn/state/lock 一行拿全）
    id: () => 'R:ID',

    // ---- 模式控制 ----
    mode:     ()     => 'R:MODE',                       // 读模式+状态
    setMode:  (m)    => 'W:MODE=' + m,                  // idle/poll/sniff (stop=idle 别名)
    bootMode: (m)    => 'W:BOOTMODE=' + m,              // idle/poll/sniff

    // ---- 485 配置 ----
    cfg:        ()     => 'R:CFG',                      // 读 poll 配置
    writeCfg:   (obj)  => 'W:CFG=' + JSON.stringify(obj),

    // ---- 寄存器表 ----
    reg:      ()   => 'R:REG',
    writeReg: (arr) => 'W:REG=' + JSON.stringify(arr),

    // ---- 数据 ----
    val:  () => 'R:VAL',                    // 实时值快照
    stat: () => 'R:STAT',                   // 全量运行状态

    // ---- 平台配置拉取 ----
    pullCfg:     ()  => 'W:PULLCFG',        // 发起拉取（立即应答 started）
    pullCfgStat: ()  => 'R:PULLCFG',        // 查拉取状态

    // ---- MQTT ----
    mqtt:    ()   => 'R:MQTT',
    writeMqtt: (o) => 'W:MQTT=' + JSON.stringify(o),
    // 只重连、不动配置：设备侧等价于 iot.kick()（销毁 client 后按 backoff=1 立刻重连）
    mqttReconnect: () => 'W:MQTTRC',
    report:  ()   => 'R:REPORT',

    // ---- sniff 结果 ----
    frames:  (n)  => 'R:FRAMES' + (n ? '=' + n : ''),   // 最近解译帧
    infer:   ()   => 'R:INFER',                          // 推断轮询表+从机列表（只读参考，不写配置）
    autoDetect: () => 'R:AUTODETECT',                    // 识别 baud/parity（只用于本次 sniff 会话）

    // ---- 总线诊断 ----
    sniffBus: (ms) => 'R:SNIFF=' + (ms || 3000),         // 静默侦听总线
    txHex:    (hex) => 'W:TX=' + hex,                    // 手动发原始帧
  };

  // ---------- 解码：设备 -> 前端 ----------
  // 返回 { cmd, ok, data, raw }
  function decode(line) {
    const raw = String(line || '').trim();
    if (!raw) return null;
    if (!raw.startsWith('RET:')) {
      return { cmd: null, ok: false, data: null, raw, unknown: true };
    }
    const body = raw.slice(4);
    // 先按 = 切；没有 = 时按第一个 : 切（覆盖 RET:FAIL:原因 形式）
    let key, val;
    const eq = body.indexOf('=');
    const co = body.indexOf(':');
    if (eq >= 0 && (co < 0 || eq < co)) {
      key = body.slice(0, eq);
      val = body.slice(eq + 1);
    } else if (co >= 0) {
      key = body.slice(0, co);
      val = body.slice(co + 1);
    } else {
      key = body;
      val = '';
    }
    // FAIL 形式：key=FAIL, val=子命令:原因
    if (key === 'FAIL') {
      const c = val.indexOf(':');
      if (c >= 0) return { cmd: val.slice(0, c), ok: false, data: val.slice(c + 1), raw };
      return { cmd: null, ok: false, data: val, raw };
    }
    const ok = true;
    // 尝试解析 JSON 负载
    let data = val;
    if (val && (val[0] === '{' || val[0] === '[')) {
      try { data = JSON.parse(val); } catch (e) { data = val; }
    }
    // R:INFO 风格 k:v;k:v
    if (typeof data === 'string' && data.indexOf(';') >= 0 && data.indexOf(':') >= 0) {
      const kv = {};
      data.split(';').forEach(pair => {
        const i = pair.indexOf(':');
        if (i > 0) kv[pair.slice(0, i)] = pair.slice(i + 1);
      });
      if (Object.keys(kv).length > 0) data = kv;
    }
    return { cmd: key, ok, data, raw };
  }

  // ---------- 寄存器值按数据类型解码 ----------
  // 与 lua/bus/mbus.lua 的 parse_value 完全一致（固定大端）
  // regs: number[]（原始 16 位寄存器值，来自 R:VAL 的 value 或帧的 values）
  // type: uint16/int16/uint32/int32/float32/uint64/int64/float64
  const TYPE_WIDTH = {
    uint16: 1, int16: 1,
    uint32: 2, int32: 2, float32: 2,
    uint64: 4, int64: 4, float64: 4
  };

  function decodeValues(regs, type, count) {
    const out = [];
    if (!Array.isArray(regs)) return out;
    const width = TYPE_WIDTH[type] || 1;
    for (let i = 0; i + width <= regs.length && out.length < count; i += width) {
      // 切成字节（每寄存器 2 字节，大端）
      const b = [];
      for (let w = 0; w < width; w++) {
        const r = regs[i + w] & 0xFFFF;
        b.push(Math.floor(r / 256), r % 256);
      }
      out.push(decodeBytes(b, type));
    }
    return out;
  }

  function decodeBytes(b, type) {
    const width = TYPE_WIDTH[type] || 1;
    if (width === 1) {
      const raw = b[0] * 256 + b[1];
      return type === 'int16' ? toInt16(raw) : raw;
    }
    if (width === 2) {
      if (type === 'float32') {
        const dv = new DataView(new ArrayBuffer(4));
        for (let i = 0; i < 4; i++) dv.setUint8(i, b[i]);
        const f = dv.getFloat32(0, false);
        return Number.isFinite(f) ? f : null;
      }
      let u32 = 0;
      for (let i = 0; i < 4; i++) u32 = u32 * 256 + b[i];
      if (type === 'int32') return u32 >= 2147483648 ? u32 - 4294967296 : u32;
      return u32;
    }
    if (type === 'float64') {
      const dv = new DataView(new ArrayBuffer(8));
      for (let i = 0; i < 8; i++) dv.setUint8(i, b[i]);
      const f = dv.getFloat64(0, false);
      return Number.isFinite(f) ? f : null;
    }
    // uint64 / int64: JS number 精度上限 2^53，用 BigInt 精确算。
    // 能安全表示成 number 的返回 number，超出的返回字符串（保精度）
    if (typeof BigInt === 'function') {
      let v = 0n;
      for (let i = 0; i < 8; i++) v = (v << 8n) | BigInt(b[i] & 0xFF);
      if (type === 'int64' && v >= 0x8000000000000000n) v -= 0x10000000000000000n;
      const SAFE = 9007199254740991n;                 // 2^53 - 1
      if (v <= SAFE && v >= -SAFE) return Number(v);
      return v.toString();
    }
    // BigInt 不可用（极老环境）的退化路径
    let hi = 0, lo = 0;
    for (let i = 0; i < 4; i++) hi = hi * 256 + b[i];
    for (let i = 4; i < 8; i++) lo = lo * 256 + b[i];
    let u53 = hi * 4294967296 + lo;                   // hi 占高 32 位
    if (type === 'int64' && hi >= 2147483648) u53 = u53 - 18446744073709551616;
    return u53;
  }

  function toInt16(u) { return u >= 0x8000 ? u - 0x10000 : u; }

  // ---------- 值 -> 显示文本 ----------
  function fmt(v) {
    if (v === null || v === undefined) return '';
    if (typeof v === 'number') {
      return Number.isInteger(v) ? String(v) : v.toFixed(3).replace(/\.?0+$/, '');
    }
    return String(v);
  }

  global.Protocol = { Enc, decode, decodeValues, fmt };
})(typeof window !== 'undefined' ? window : globalThis);
