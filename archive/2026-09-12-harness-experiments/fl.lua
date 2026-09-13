-- Native friend list injector (experimental harness payload).
local ffi = require('ffi');
pcall(ffi.cdef, [[
void* VirtualAlloc(void* a, size_t s, unsigned long t, unsigned long p);
]]);
local m = ashita.memory;

FLN = FLN or {};
if (FLN.buf == nil) then
    FLN.buf  = tonumber(ffi.cast('uint32_t', ffi.C.VirtualAlloc(nil, 0x10000, 0x3000, 0x40)));
    FLN.cnt  = FLN.buf + 0xFFF0;
    FLN.stub = FLN.buf + 0xF000;
end

local function u32le(v)
    return { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 };
end

-- cdecl int stub(int i, void* out): copy record i from buf or return -1
local code = { 0x8B,0x44,0x24,0x04, 0x3B,0x05 };
for _, b in ipairs(u32le(FLN.cnt)) do code[#code+1] = b; end
local tail = { 0x73,0x1D, 0x56,0x57, 0x8B,0xF0, 0xC1,0xE6,0x08, 0x81,0xC6 };
for _, b in ipairs(tail) do code[#code+1] = b; end
for _, b in ipairs(u32le(FLN.buf)) do code[#code+1] = b; end
local tail2 = { 0x8B,0x7C,0x24,0x10, 0xB9,0x00,0x01,0x00,0x00, 0xF3,0xA4, 0x5F,0x5E, 0x33,0xC0, 0xC3, 0x83,0xC8,0xFF, 0xC3 };
for _, b in ipairs(tail2) do code[#code+1] = b; end
m.write_array(FLN.stub, code);

function FLN.set(i, rec)
    local base = FLN.buf + i * 0x100;
    local z = {}; for k = 1, 0x100 do z[k] = 0; end
    m.write_array(base, z);
    for off, bytes in pairs(rec) do m.write_array(base + off, bytes); end
end

function FLN.count(n) m.write_uint32(FLN.cnt, n); end

function FLN.hook(on)
    local site = 0x1d87732;
    m.unprotect(site, 5);
    local target = on and FLN.stub or 0x1d91350;
    local rel = (target - (site + 5)) % 4294967296;
    local b = u32le(rel);
    m.write_array(site, { 0xE8, b[1], b[2], b[3], b[4] });
end

local function str16(s)
    local t = {}; for k = 1, 16 do t[k] = (k <= #s) and s:byte(k) or 0; end return t;
end

-- first probe: one friend, valid, status 1
FLN.count(0);
FLN.set(0, {
    [0x00] = u32le(2), [0x04] = u32le(0),
    [0x08] = u32le(0x2000), [0x0c] = u32le(0),
    [0x98] = u32le(1 + 2 * 1234), [0x9c] = u32le(0),
    [0xa0] = str16('Buddy'),
    [0xb0] = u32le(1),
    [0xb4] = str16('Buddy'),
});
FLN.count(1);
FLN.hook(true);
return ('buf=%08X stub=%08X G=%08X mode=%d'):format(FLN.buf, FLN.stub, m.read_uint32(0x217d500), m.read_uint8(m.read_uint32(0x217d500) + 0x1c4));
