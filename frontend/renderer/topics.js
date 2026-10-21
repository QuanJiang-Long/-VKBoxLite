//=====================================================================
// topics.js - 平台 Topic 常量 + 格式化辅助函数
//
// 跟 lua/core/config.lua 的 PLATFORM_* 配套, 一一对应.
// 改了 lua 那边要同步改这里.
//
// 上行 (设备 → 平台/用户 broker):
//   U1 hello       拉取握手, 一次性
//   U2 info        元数据/拓扑, 网关建档 (meta 不带 nodes / topo 带 nodes)
//   U3 res         网关资源, ram/uptime/cpu
//   U4 pub         数据上报, 子设备属性
//   U5 event       资源告警, ram/cpu/disk 越阈值
//   U6 reply       应用回执, 配置回写结果
//   U7 fpost       指令回执, D2/D3 写寄存器结果
//
// 下行 (平台/用户 broker → 设备):
//   D1 get         主下行, 配置下发 + 普通指令
//   D2 invoke    gw 服务调用
//   D2n invoke   node 服务调用, 到 {sn}-N 子设备 (N=子设备序号, 与 U4 的
//                 -{n} 同序列; 设备实际订阅按档案从机精确定制, 无通配)
//   D3 pset        属性设置
//   D4 pget        属性查询
//
// 用法:
//   const t = window.VKBoxTopics;
//   const hello = t.format(t.PLATFORM_HELLO_TOPIC, sn);
//   const lines = t.formatManualExtraTopics(sn);  // 手动档生效的额外 topic
//=====================================================================

const VKBoxTopics = (function () {
  // 模板: 占位符用 {sn} (小写), 跟 lua 的 %s + format 一一对应
  const TOPICS = {
    // U1
    PLATFORM_HELLO_TOPIC: '/sys/thing/gw/config/hello/{sn}',
    // U2 (元数据 + 拓扑共用 topic, 靠 body 里有没有 nodes[] 区分)
    PLATFORM_INFO_TOPIC: '/sys/thing/gw/info/post/{sn}',
    // U3
    PLATFORM_RES_TOPIC: '/sys/thing/gw/property/post/{sn}',
    // U4
    PLATFORM_PUB_TOPIC: '/sys/thing/node/property/post/{sn}',
    // U5
    PLATFORM_EVENT_TOPIC: '/sys/thing/gw/event/post/{sn}',
    // U6
    PLATFORM_REPLY_TOPIC: '/sys/thing/gw/config/reply/{sn}',
    // U7
    PLATFORM_FPOST_TOPIC: '/sys/thing/gw/function/post/{sn}',
    // D1
    PLATFORM_GET_TOPIC: '/sys/thing/gw/config/get/{sn}',
    // D2
    PLATFORM_FUNC_TOPIC: '/sys/thing/gw/service/invoke/{sn}',
    // D2n (子设备级, -N=子设备序号, 与 U4 上报 -{n} 同序列; 设备订精确 -1..-K, 无通配)
    PLATFORM_FUNC_NODE_TOPIC: '/sys/thing/node/service/invoke/{sn}-N',
    // D3
    PLATFORM_PSET_TOPIC: '/sys/thing/gw/property/set/{sn}',
    // D4
    PLATFORM_PGET_TOPIC: '/sys/thing/gw/property/get/{sn}',
  };

  // 替换 {sn} 占位符. sn 为空时返回模板本身 (不替换, 调试用)
  function format(tpl, sn) {
    if (!tpl) return '';
    if (!sn) return tpl;
    return tpl.replace(/\{sn\}/g, sn);
  }

  // 手动档额外生效的 topic 列表 (除用户自填的 pub_topic/sub_topic 之外,
  // 设备还会自动发的两条):
  //   U1 hello - 进 manual 模式时 ctrl.lua:76 调一次
  //   U2 meta  - 指纹变 / 2min 兜底重发
  // 注: U2-topo (带 nodes) manual 不发; U3/U5/U6/U7 manual 不发 (pub_platform gate);
  //     D1/D2/D3/D4 manual 不订 (走用户 sub_topic)
  function manualExtraTopics(sn) {
    if (!sn) return [];
    return [
      { code: 'U1', name: 'hello', topic: format(TOPICS.PLATFORM_HELLO_TOPIC, sn) },
      { code: 'U2', name: 'meta',  topic: format(TOPICS.PLATFORM_INFO_TOPIC, sn) },
    ];
  }

  // 24-fix: 平台档额外生效的 topic 列表 (除 mqStPub/mqStSub 已显示的 2 条之外).
  //   mqStPub = U4 pub   (PLATFORM_PUB_TOPIC)
  //   mqStSub = D1 get   (PLATFORM_GET_TOPIC)
  //   本表列出其余 10 条: U1/U2/U3/U5/U6/U7 + D2/D2n/D3/D4
  //   U2 info: meta (不带 nodes) + topo (带 nodes) 共用同一 topic, 这里只列一次
  // realSubs (可选): 设备回报的【真实订阅清单】(R:MQTT stat.sub_list)。
  //   只有 D2n 那条需要它: 常量里是模板 ".../{sn}-N"(N=从机序号占位符),
  //   设备实际订的是 ".../{sn}-1"(多从机展开 -1..-K)。显示模板等于骗人 ——
  //   现场照着 "-N" 去订阅收不到东西(2026-10 用户问出来的)
  function platformExtraTopics(sn, realSubs) {
    if (!sn) return [];
    const subs = Array.isArray(realSubs) ? realSubs.filter(Boolean) : [];
    const nodeReal = subs.find(t => t.indexOf('/node/service/invoke/') >= 0);
    const nodeTopic = nodeReal || format(TOPICS.PLATFORM_FUNC_NODE_TOPIC, sn);
    return [
      { code: 'U1', name: 'hello', topic: format(TOPICS.PLATFORM_HELLO_TOPIC, sn) },
      { code: 'U2', name: 'info',  topic: format(TOPICS.PLATFORM_INFO_TOPIC, sn) },
      { code: 'U3', name: 'res',   topic: format(TOPICS.PLATFORM_RES_TOPIC, sn) },
      { code: 'U5', name: 'event', topic: format(TOPICS.PLATFORM_EVENT_TOPIC, sn) },
      { code: 'U6', name: 'reply', topic: format(TOPICS.PLATFORM_REPLY_TOPIC, sn) },
      { code: 'U7', name: 'fpost', topic: format(TOPICS.PLATFORM_FPOST_TOPIC, sn) },
      { code: 'D2',  name: 'invoke', topic: format(TOPICS.PLATFORM_FUNC_TOPIC, sn) },
      { code: 'D2n', name: 'invoke', topic: nodeTopic },
      { code: 'D3',  name: 'pset',  topic: format(TOPICS.PLATFORM_PSET_TOPIC, sn) },
      { code: 'D4',  name: 'pget',  topic: format(TOPICS.PLATFORM_PGET_TOPIC, sn) },
    ];
  }

  // sniff 状态卡片「其他生效 Topic」尾部要拼的 2 条下行服务调用 topic
  // (sniff 卡的 snStExtraTopics 主体仍是设备回传的 pub 上行列表, 这 2 行
  //  以 code 标签形式附在后面, 方便现场核对 gw/node 两级 invoke 的订法)
  function sniffExtraTopics(sn) {
    if (!sn) return [];
    return [
      { code: 'D2',  name: 'invoke', topic: format(TOPICS.PLATFORM_FUNC_TOPIC, sn) },
      { code: 'D2n', name: 'invoke', topic: format(TOPICS.PLATFORM_FUNC_NODE_TOPIC, sn) },
    ];
  }

  // 把 topic 列表格式化成多行字符串 (给前端 <pre> 显示)
  function formatListAsLines(items) {
    if (!items || items.length === 0) return '';
    // 取最长 code 标签做对齐 (U1..U7/D1..D4 都是 2 字符, D2n 3 字符, 差 1 格可接受)
    return items.map(it => `${it.code} (${it.name}): ${it.topic}`).join('\n');
  }

  return Object.assign({}, TOPICS, {
    format,
    manualExtraTopics,
    platformExtraTopics,
    sniffExtraTopics,
    formatListAsLines,
  });
})();

if (typeof window !== 'undefined') window.VKBoxTopics = VKBoxTopics;
if (typeof module !== 'undefined') module.exports = VKBoxTopics;
