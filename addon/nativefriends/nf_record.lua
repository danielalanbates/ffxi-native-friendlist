--[[
* nf_record -- builds the 0x100-byte friend entry FFXiMain's friend list reads.
*
* Layout recovered from FFXiMain.dll's accessor functions (see docs/CLIENT_INTERNALS.md).
* Only the fields the menu actually consumes are written; everything else stays zero.
*
* Copyright (c) 2026 Daniel Bates. All rights reserved.
* Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
]]--

local M = {};

local STATUS_ONLINE = 0x00002000;   -- +0x08 bits 13..15 = 1   -> "Online Friends"
local IN_GAME       = 0x00010000;   -- +0x08 bit 16            -> character block present
local PENDING       = 0x10000000;   -- +0x08 bit 28            -> "Pending"

local function put(t, off, bytes)
    for i = 1, #bytes do t[off + i] = bytes[i]; end
end

local function u16(v) return { v % 256, math.floor(v / 256) % 256 }; end
local function u32(v)
    v = v % 4294967296;
    return { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 };
end
local function name16(s)
    local t = {};
    for i = 1, 16 do t[i] = (i <= #s and i <= 15) and s:byte(i) or 0; end
    return t;
end

function M.build(e, id, world)
    local t = {};
    for i = 1, 0x100 do t[i] = 0; end

    put(t, 0x00, u32(id));                     -- entry id
    put(t, 0x98, u32(1 + 2 * id));             -- bit 0 = slot in use; bits 1.. = account number
    put(t, 0xA0, name16(e.name));              -- "handle", shown in parentheses
    put(t, 0xB0, u32(1));                      -- bit 0: character name below is valid
    put(t, 0xB4, name16(e.name));

    if (e.state == 'friend') then
        if (e.online) then
            put(t, 0x08, u32(STATUS_ONLINE + IN_GAME));   -- character block index 0
            put(t, 0x1A, u16(1));                         -- block in use
            put(t, 0x1C, u16(e.zone or 0));
            t[0x1E + 1] = (world or 0) % 256;             -- same world as us
            put(t, 0xFC, u32(1));                         -- world field valid
            put(t, 0xB0, u32(1 + 0x40));                  -- bit 6: zone below is valid
            put(t, 0xD8, u16(e.zone or 0));
        end
    else
        put(t, 0x08, u32(PENDING));
    end
    return t;
end

return M;
