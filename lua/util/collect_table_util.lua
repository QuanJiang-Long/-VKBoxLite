-- 采集表工具. 错误消息保持英文短词以兼容前端 app.js:764-767 翻译表.
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
