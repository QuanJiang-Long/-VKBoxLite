







































local lbsLoc2 = {}

local function numToBcdNum(inStr,destLen)
local l,t,num = string.len(inStr or ""),{}
destLen = destLen or (inStr:len()+1)/2
for i=1,l,2 do
num = tonumber(inStr:sub(i,i+1),16)
if i==l then
num = 0xf0+num
else
num = (num%0x10)*0x10 + (num-(num%0x10))/0x10
end
table.insert(t,num)
end

local s = string.char(unpack(t))

l = string.len(s)
if l < destLen then
s = s .. string.rep("\255",destLen-l)
elseif l > destLen then
s = string.sub(s,1,destLen)
end

return s
end





local function bcdNumToNum(num)
local byte,v1,v2
local t = {}

for i=1,num:len() do
byte = num:byte(i)
v1,v2 = bit.band(byte,0x0f),bit.band(bit.rshift(byte,4),0x0f)

if v1 == 0x0f then break end
table.insert(t,v1)

if v2 == 0x0f then break end
table.insert(t,v2)
end

return table.concat(t)
end

lbsLoc2.imei = numToBcdNum(mobile.imei())

local function enCellInfo(s)

local v = s[1]
log.info("cell", json.encode(v))
local ret = pack.pack(">HHbbi",v.tac,v.mcc,v.mnc,31,v.cid)
return string.char(1)..ret
end

local function trans(str)
local s = str
if str:len()<10 then
s = str..string.rep("0",10-str:len())
end

return s:sub(1,3).."."..s:sub(4,10)
end






























function lbsLoc2.request(timeout, host, port, reqTime)
if mobile.status() == 0 then
return
end
local hosts = host and {host} or {"free.bs.luatos.com", "bs.openluat.com"}
port = port and tonumber(port) or 12411
local sc = socket.create(nil, function(sc, event)

if event == socket.ON_LINE then

sys.publish("LBS_CONACK")
elseif event == socket.TX_OK then

sys.publish("LBS_TX")
elseif event == socket.EVENT then

sys.publish("LBS_RX")
end
end)
if sc == nil then
return
end

socket.config(sc, nil, true)
local rxbuff = zbuff.create(64)
for k, rhost in pairs(hosts) do
local reqStr = string.char(0, (reqTime and 4 or 0) +8) .. lbsLoc2.imei
local tmp = nil
if mobile.scell then
local scell = mobile.scell()
if scell and scell.mcc then

tmp = pack.pack(">bHHbbi", 1, scell.tac, scell.mcc, scell.mnc, 31, scell.eci)
end
end
if tmp == nil then
local cells = mobile.getCellInfo()
if cells == nil or #cells == 0 then
socket.release(sc)
return
end
reqStr = reqStr .. enCellInfo(cells)
else
reqStr = reqStr .. tmp
end

log.debug("lbsLoc2", rhost, port)
if socket.connect(sc, rhost, port) and sys.waitUntil("LBS_CONACK", 1000) then
if socket.tx(sc, reqStr) and sys.waitUntil("LBS_TX", 1000) then
socket.wait(sc)
if sys.waitUntil("LBS_RX", timeout or 15000) then
local succ, data_len = socket.rx(sc, rxbuff)

if succ and data_len > 0 then
socket.close(sc)
break
else
log.debug("lbsLoc", "rx数据失败", rhost)
end
else
log.debug("lbsLoc", "等待数据超时", rhost)
end
else
log.debug("lbsLoc", "tx调用失败或TX_ACK超时", rhost)
end
else
log.debug("lbsLoc", "connect调用失败或CONACK超时", rhost)
end
socket.close(sc)

end
sys.wait(100)
socket.release(sc)
if rxbuff:used() > 0 then
local resp = rxbuff:toStr(0, rxbuff:used())
log.debug("lbsLoc2", "rx", (resp:toHex()))
if resp:len() >= 11 and(resp:byte(1) == 0 or resp:byte(1) == 0xFF) then
local lat = trans(bcdNumToNum(resp:sub(2, 6)))
local lng = trans(bcdNumToNum(resp:sub(7, 11)))
local t = nil
if resp:len() >= 17 then
t = {
year=resp:byte(12) + 2000,
month=resp:byte(13),
day=resp:byte(14),
hour=resp:byte(15),
min=resp:byte(16),
sec=resp:byte(17),
}
end
return lat, lng, t
end
end
rxbuff:del()
end







function lbsLoc2.version()
return "202607021200"
end

log.debug("lbsLoc2", "version -> " .. lbsLoc2.version())

return lbsLoc2
