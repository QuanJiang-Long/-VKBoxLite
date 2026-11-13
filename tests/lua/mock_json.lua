-- mock_json.lua —— 测试用的真 JSON 编解码器(从 test_cfg_shard.lua 那枚原样搬来)
--
--   为什么不用"定长假 blob": 12-fix 那一轮的教训是【替身不像, 测试全绿、现场
--   全红】。分片上传(W:CSHARD)这段代码的正确性全在"一整行怎么切成片、片里的
--   数组怎么拼回一张表", 假 blob 一行都验不了 —— 连 arg 里那个逗号的位置都是
--   被测对象。
--   严格度对齐真 json: 解析失败必须 raise(设备侧靠 pcall 兜), 解码解出 nil 也
--   要能区分开, 因为 jdecode_err 就是靠这两种情况分别报"不合法"和"为空"。
--   test_cfg_shard.lua 仍用它自己那份内联副本, 不动它。
local M = {}

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }
local function enc_str(s)
  return '"' .. (tostring(s):gsub('[%c"\\]', function(c)
    return ESC[c] or string.format('\\u%04x', c:byte())
  end)) .. '"'
end

local encode
local function is_array(v)
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n == 0 then return true end
  for k in pairs(v) do
    if type(k) ~= 'number' or k % 1 ~= 0 or k < 1 or k > n then return false end
  end
  return true
end

function encode(v)
  local t = type(v)
  if t == 'nil' then return 'null' end
  if t == 'boolean' then return tostring(v) end
  if t == 'number' then return tostring(v) end
  if t == 'string' then return enc_str(v) end
  if t ~= 'table' then error('encode: 不支持的类型 ' .. t) end
  local parts = {}
  if is_array(v) then
    for i = 1, #v do parts[i] = encode(v[i]) end
    return '[' .. table.concat(parts, ',') .. ']'
  end
  for k, val in pairs(v) do
    parts[#parts + 1] = enc_str(k) .. ':' .. encode(val)
  end
  table.sort(parts)
  return '{' .. table.concat(parts, ',') .. '}'
end

local function decode(s)
  local i = 1
  local value
  local function ws()
    while i <= #s do
      local c = s:sub(i, i)
      if c == ' ' or c == '\t' or c == '\n' or c == '\r' then i = i + 1 else break end
    end
  end
  local function err(m) error('json decode: ' .. m .. ' @' .. i) end
  function value()
    ws()
    local c = s:sub(i, i)
    if c == '{' then
      local o = {}
      i = i + 1
      ws()
      if s:sub(i, i) == '}' then i = i + 1 return o end
      while true do
        ws()
        if s:sub(i, i) ~= '"' then err('expect key') end
        local k = value()
        ws()
        if s:sub(i, i) ~= ':' then err('expect colon') end
        i = i + 1
        o[k] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == '}' then break end
        if d ~= ',' then err('expect comma or brace') end
      end
      return o
    end
    if c == '[' then
      local a = {}
      i = i + 1
      ws()
      if s:sub(i, i) == ']' then i = i + 1 return a end
      while true do
        a[#a + 1] = value()
        ws()
        local d = s:sub(i, i)
        i = i + 1
        if d == ']' then break end
        if d ~= ',' then err('expect comma or bracket') end
      end
      return a
    end
    if c == '"' then
      i = i + 1
      local buf = {}
      while true do
        local ch = s:sub(i, i)
        if ch == '' then err('unterminated string') end
        if ch == '\\' then
          local nx = s:sub(i + 1, i + 1)
          if nx == 'u' then
            buf[#buf + 1] = string.char(tonumber(s:sub(i + 2, i + 5), 16))
            i = i + 6
          else
            buf[#buf + 1] = ({ ['"'] = '"', ['\\'] = '\\', ['/'] = '/', n = '\n',
              r = '\r', t = '\t', b = '\b', f = '\f' })[nx] or nx
            i = i + 2
          end
        elseif ch == '"' then
          i = i + 1
          return table.concat(buf)
        else
          buf[#buf + 1] = ch
          i = i + 1
        end
      end
    end
    if c == 't' then
      if s:sub(i, i + 3) ~= 'true' then err('bad literal') end
      i = i + 4 return true
    end
    if c == 'f' then
      if s:sub(i, i + 4) ~= 'false' then err('bad literal') end
      i = i + 5 return false
    end
    if c == 'n' then
      if s:sub(i, i + 3) ~= 'null' then err('bad literal') end
      i = i + 4 return nil
    end
    local num = s:match('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', i)
    if not num or num == '' then err('bad value, got ' .. tostring(c)) end
    i = i + #num
    return tonumber(num)
  end
  return value()
end

M.encode = encode
M.decode = decode
-- 一整行 W:CSHARD / W:CFINISH 的行头切分, 和 cmd.lua 用的同一个形状
M.line = function(cmd, head, body)
  return cmd .. '=' .. head .. ',' .. encode(body)
end

return M
