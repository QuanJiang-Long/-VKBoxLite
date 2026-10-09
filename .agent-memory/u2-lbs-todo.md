# U2 报文加 4 字段（deviceType/longitude/latitude/locationWay）— TODO

## 现状（commit 09d10b9，2026-10-10）
U2 (`/sys/thing/gw/info/post/{sn}`) 已加 2 个字段：
- `deviceType: 3` (产品定义: 网关, 固定)
- `locationWay: 0` (0=未定位, 2=LBS 成功)

**未加**：
- `longitude` / `latitude` (LBS 未集成, 整项不发, 遵守 send_meta 上方"不编假值"的规矩)

**未加**：
- `rssi` (项目里 csq 字段已等价于参考样例的 rssi 风格 — 0~31 正整数 CSQ;
  RSRP 是负数 dBm, 加了和 csq 重复, 不加)

## TODO: LBS 集成（拿到 project_id 后）

### 前置条件
- 注册 https://iot.openluat.com 账号
- 进入"订单管理" / 项目详情, 找 `project_id` (7 位字符串)
- 用户的项目已有 `project_key` (32 位, `tbdOo3pkSijd11fEQ4X1keayvhPSGRBH`)
  → 项目已开通付费业务; project_id 是项目身份, 单独存在

### 改动（4 处）
1. **iot.lua 顶部** 加 `local lbsLoc2 = corelib.try("lbsLoc2")`
2. **iot.lua 增 `lbs_request()` 函数**：
   ```lua
   local function lbs_request()
       if not lbsLoc2 then return nil end
       local ok, lat, lng, t = pcall(lbsLoc2.request, 5000)
       if not ok or type(lat) ~= "number" or type(lng) ~= "number" then
           return nil
       end
       return lat, lng
   end
   ```
3. **iot.lua send_meta** 在 `deviceType` / `locationWay` 字段后加:
   ```lua
   local lat, lng = lbs_request()
   if lat and lng then
       p[#p + 1] = string.format('"longitude":%.6f', lng)
       p[#p + 1] = string.format('"latitude":%.6f', lat)
       -- 最后一个 locationWay 从 0 改为 2
       p[#p] = '"locationWay":2'
   end
   ```
4. **30 分钟周期上报触发 LBS**（不超免费版 2 分钟 1 次限制, 我们 30 分钟足够）

### 注意事项
- LBS 限 2 分钟 1 次 (免费版 `lbsLoc2.request` 单基站定位) — 我们的 U2 上报频率
  本身是 30 分钟一次, 不会超
- 失败兜底: longitude/latitude 整项不发, locationWay 保持 0
- 不写 0/0 假装定位, 遵守 send_meta 上方"不编假值"规矩
- 不动 send_meta 上方 csq 字段 (csq 已等价 rssi)
- 改动只在 iot.lua, 不触 cfg.lua / ctrl.lua / poll / sniff (硬约束 1)

## 参考
- 合宙 LBS 文档: https://docs.openluat.com/air780ep/luatos/app/common/lbswifi/
- 免费版 demo: `gitee.com/openLuat/LuatOS-Air780EP/demo/lbsLoc2/main.lua`
- 平台文档参考样例见 git 历史 (commit 64a0db8 的测试反馈)
