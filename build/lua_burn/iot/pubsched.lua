













































local cfg = require "core/config"

local M = {}


M.PUB_MIN_MS = cfg.PUB_MIN_MS or 30000


local CH = {
    meta = { min_ms = M.PUB_MIN_MS },            -- U2 元数据
    prop = { min_ms = M.PUB_MIN_MS },            -- U4 子设备数据
    topo = { min_ms = cfg.TOPO_REBUILD_MS or M.PUB_MIN_MS },  -- U2 拓扑
}


local clock = os.clock
local clock_wall = os.time
M._set_clock = function(fn, fn_wall)
    clock = fn or os.clock
    clock_wall = fn_wall or os.time
end


function M.changed(ch)
    local st = CH[ch]
    if st then st.dirty = true end
end


local function consume(st)
    st.at = clock()
    st.wall = clock_wall()
end





function M.due(ch, fallback_s)
    local st = CH[ch]
    if not st then return false end

    if fallback_s and fallback_s > 0 and (clock_wall() - (st.wall or 0)) >= fallback_s then
        consume(st)
        return true
    end
    if not st.dirty then return false end

    if ((clock() - (st.at or -1e9)) * 1000) < st.min_ms then
        st.blocked = (st.blocked or 0) + 1
        return false
    end
    consume(st)
    return true
end




function M.ready(ch)
    local st = CH[ch]
    if not st then return false end
    if ((clock() - (st.at or -1e9)) * 1000) < st.min_ms then return false end
    consume(st)
    return true
end


function M.sent(ch)
    local st = CH[ch]
    if not st then return end
    st.dirty = false
    st.sent = (st.sent or 0) + 1
    st.ok_at = clock()
end

function M.dirty(ch)
    local st = CH[ch]
    return (st and st.dirty) or false
end


function M.status()
    local out = {}
    for ch, st in pairs(CH) do
        out[ch] = {
            dirty = st.dirty and true or false,
            sent = st.sent or 0,
            blocked = st.blocked or 0,
            min_ms = st.min_ms,
            last_age = (st.ok_at and (clock() - st.ok_at) or nil),
        }
    end
    return out
end






function M.reset()
    local w = clock_wall()
    for _, st in pairs(CH) do
        st.dirty = true
        st.at = -1e9
        st.wall = w
    end
end



for _, st in pairs(CH) do
    st.dirty = false
    st.at = -1e9
    st.wall = clock_wall()
    st.ok_at = nil
    st.sent = 0
    st.blocked = 0
end

return M
