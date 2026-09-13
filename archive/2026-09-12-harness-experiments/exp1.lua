local m=ashita.memory
local function u32le(v) return { v%256, math.floor(v/256)%256, math.floor(v/65536)%256, math.floor(v/16777216)%256 } end
local function str16(s) local t={} for k=1,16 do t[k]=(k<=#s) and s:byte(k) or 0 end return t end
local G=m.read_uint32(0x217d500)
local world=m.read_uint16(G+0x130)
local zone=m.read_uint32(m.read_uint32(0x217db28)+0x3c2e0)
local function rec(handle, f08, f0c, extra)
  local r={[0x00]=u32le(100+#handle),[0x08]=u32le(f08),[0x0c]=u32le(f0c),[0x98]=u32le(1+2*777),[0xa0]=str16(handle),[0xb0]=u32le(1+0x40),[0xb4]=str16(handle..'Chr'),[0xd8]=u32le(zone),[0xe0]=u32le(0)}
  for k,v in pairs(extra or {}) do r[k]=v end
  return r
end
FLN.count(0)
-- cat0 online with char block: status1, bit16, idx0; subblock +0x18: +0x1a=1,+0x1c zone,+0x1e world; +0xfc bit0
FLN.set(0, rec('Alpha', 0x2000+0x10000+ (5*0x100000), 0x2*3, {[0x18]={0,0,1,0}, [0x1c]={zone%256, math.floor(zone/256)%256, world%256, 0}, [0xfc]=u32le(1)}))
FLN.set(1, rec('Bravo', 0x0000, 0))
FLN.set(2, rec('Charlie', 0x2000, 0, {[0xf8]={1}}))
FLN.set(3, rec('Delta', 0x10000000, 0))
FLN.set(4, rec('Echo', 0x8000, 0))
FLN.count(5)
return ('world=%d zone=%d'):format(world, zone)
