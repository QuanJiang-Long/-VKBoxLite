local M = {}

local function is_lib(m)
    local t = type(m)
    return t == "table" or t == "userdata"
end

function M.get(name)
    local m = _G[name]
    if is_lib(m) then return m end
    local ok, mod = pcall(require, name)
    if ok and is_lib(mod) then return mod end
    error("corelib: library not available -> " .. tostring(name), 2)
end

function M.try(name)
    local ok, m = pcall(M.get, name)
    if ok and is_lib(m) then return m end
    return nil
end

local fallback
local function log_fallback()
    if fallback then return fallback end
    local mk = function(tag)
        return function(...)
            local parts = {}
            for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
            print("[" .. tag .. "]", table.concat(parts, " "))
        end
    end
    fallback = { debug = mk("D"), info = mk("I"), warn = mk("W"), error = mk("E") }
    return fallback
end

function M.log()
    local m = _G.log
    if is_lib(m) and type(m.info) == "function" and type(m.debug) == "function" then return m end
    local ok, mod = pcall(require, "log")
    if ok and is_lib(mod) and type(mod.info) == "function" and type(mod.debug) == "function" then return mod end
    if is_lib(m) and type(m.info) == "function" then
        return {
            debug = function() end,
            info = m.info,
            warn = type(m.warn) == "function" and m.warn or m.info,
            error = type(m.error) == "function" and m.error or m.info,
        }
    end
    return log_fallback()
end

return M
