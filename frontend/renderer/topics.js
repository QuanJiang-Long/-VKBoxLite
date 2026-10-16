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
//   D2 func        服务调用
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
    PLATFORM_FUNC_TOPIC: '/sys/thing/gw/function/get/{sn}',
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
  //   本表列出其余 9 条: U1/U2/U3/U5/U6/U7 + D2/D3/D4
  //   U2 info: meta (不带 nodes) + topo (带 nodes) 共用同一 topic, 这里只列一次
  function platformExtraTopics(sn) {
    if (!sn) return [];
    return [
      { code: 'U1', name: 'hello', topic: format(TOPICS.PLATFORM_HELLO_TOPIC, sn) },
      { code: 'U2', name: 'info',  topic: format(TOPICS.PLATFORM_INFO_TOPIC, sn) },
      { code: 'U3', name: 'res',   topic: format(TOPICS.PLATFORM_RES_TOPIC, sn) },
      { code: 'U5', name: 'event', topic: format(TOPICS.PLATFORM_EVENT_TOPIC, sn) },
      { code: 'U6', name: 'reply', topic: format(TOPICS.PLATFORM_REPLY_TOPIC, sn) },
      { code: 'U7', name: 'fpost', topic: format(TOPICS.PLATFORM_FPOST_TOPIC, sn) },
      { code: 'D2', name: 'func',  topic: format(TOPICS.PLATFORM_FUNC_TOPIC, sn) },
      { code: 'D3', name: 'pset',  topic: format(TOPICS.PLATFORM_PSET_TOPIC, sn) },
      { code: 'D4', name: 'pget',  topic: format(TOPICS.PLATFORM_PGET_TOPIC, sn) },
    ];
  }

  // 把 topic 列表格式化成多行字符串 (给前端 <pre> 显示)
  function formatListAsLines(items) {
    if (!items || items.length === 0) return '';
    // 取最长 code 标签做对齐 (U1..U7 都是 2 字符, D1..D4 也是, 不需要 padding)
    return items.map(it => `${it.code} (${it.name}): ${it.topic}`).join('\n');
  }

  return Object.assign({}, TOPICS, {
    format,
    manualExtraTopics,
    platformExtraTopics,
    formatListAsLines,
  });
})();

if (typeof window !== 'undefined') window.VKBoxTopics = VKBoxTopics;
if (typeof module !== 'undefined') module.exports = VKBoxTopics;
