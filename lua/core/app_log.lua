-- 统一日志接口. info/warn/error 永久保留, debug 发布版关闭.
-- 业务事件用 info, 告警用 warn, 错误用 error, 调试/探针用 debug.
local M = {}

function M.info(msg)  print("[I]", msg) end
function M.warn(msg)  print("[W]", msg) end
function M.error(msg) print("[E]", msg) end

M.debug = _G.BUILD_RELEASE and function() end or function(msg)
    print("[D]", msg)
end

return M
