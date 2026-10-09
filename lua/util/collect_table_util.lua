-- 采集表工具: 抽离 ds_poll/ds_pull 两套配置共用的校验/归一化逻辑.
-- 第一版: validate_reg 单条寄存器字段校验. cfg.normalize_reg 和
-- pullcfg.props_to_regs 都接它, 重复的 addr/count/dtype/name 范围
-- 校验只剩一处. 后续 to_modbus_tasks / build_u4_payload 在迭代 B
-- 收 poll 路径时再加.
--
-- 错误消息保持英文短词("bad addr" / "bad count" / "bad dtype" / "bad name")
-- 以兼容前端 app.js:764-767 的字面翻译表.
local M = {}

-- 支持的 dtype 白名单
local DTYPE_OK = {
    uint16 = 1, int16 = 1, uint32 = 1, int32 = 1,
    float32 = 1, uint64 = 1, int64 = 1, float64 = 1,
}

-- 校验单条寄存器字段. 入参 r 期望含 addr/count/dtype/name.
-- 返回 ok=true 或 ok=false, "bad xxx" 短词(前端翻译表按这 4 个 key).
function M.validate_reg(r)
    if type(r) ~= "table" then return false, "not table" end
    local addr = tonumber(r.addr)
    if not addr or addr < 0 or addr > 65535 then return false, "bad addr" end
    local count = tonumber(r.count) or 1
    if count < 1 or count > 125 then return false, "bad count" end
    if not DTYPE_OK[r.dtype] then return false, "bad dtype" end
    local name = r.name
    if type(name) ~= "string" or #name == 0
        or #name > 16 or not name:match("^%w+$") then
        return false, "bad name"
    end
    return true
end

return M
