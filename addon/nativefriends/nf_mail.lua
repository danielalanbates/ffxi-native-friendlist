--[[
* nf_mail -- PlayOnline messages for the native Friend List "Messages" window.
*
* On retail, FFXI's message box is a set of local files that PlayOnline kept in sync:
*   ...\PlayOnlineViewer\pub\home00\msg\r\b\<encoded header>   received
*   ...\PlayOnlineViewer\pub\home00\msg\O\m\<encoded header>   waiting to be sent
* The file name is polcore's own encoding of a 0x48-byte message header; the contents are the
* body ("subject" 0x07 "text" 0x00). polcore's file layer is only switched on by the PlayOnline
* Viewer, so this module switches it on (common function table slot 0xE5C), delivers server mail
* into the inbox as files, and uploads whatever the game drops into the outbox.
*
* Copyright (c) 2026 Daniel Bates. All rights reserved.
* Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
]]--

local ffi = require('ffi');
local mem = ashita.memory;

pcall(ffi.cdef, [[
int   MoveFileA(const char* a, const char* b);
typedef struct { unsigned long attr; unsigned long c1, c2, a1, a2, w1, w2; unsigned long sh, sl, r0, r1; char name[260]; char alt[14]; } NF_WFDA;
void* FindFirstFileA(const char* p, NF_WFDA* d);
int   FindNextFileA(void* h, NF_WFDA* d);
int   FindClose(void* h);
int   CreateDirectoryA(const char* p, void* s);
int   DeleteFileA(const char* p);
]]);

local M = { ready = false };

-- FFXiMain calls polcore through thunks "mov eax,[table ptr]; jmp [eax+slot]"; the first one tells us where the pointer lives.
local SIG_POL_THUNK     = 'A1????????FFA0????0000';
local SLOT_FS_INIT      = 0xE5C;
local SLOT_DECODE_NAME  = 0x48C;       -- (out 0x48 header, name) -> 0 on success

local function exists_dir(path)
    local d = ffi.new('NF_WFDA');
    local h = ffi.C.FindFirstFileA(path .. '*', d);
    if (h == ffi.cast('void*', -1)) then return false; end
    ffi.C.FindClose(h);
    return true;
end

local function list(dir)
    local out = {};
    local d = ffi.new('NF_WFDA');
    local h = ffi.C.FindFirstFileA(dir .. '*', d);
    if (h == ffi.cast('void*', -1)) then return out; end
    repeat
        if (bit.band(d.attr, 0x10) == 0) then out[#out + 1] = ffi.string(d.name); end
    until ffi.C.FindNextFileA(h, d) == 0;
    ffi.C.FindClose(h);
    return out;
end

local function hex(s)
    return (s:gsub('.', function (c) return ('%02x'):format(c:byte()); end));
end

local function unhex(s)
    return (s:gsub('%x%x', function (h) return string.char(tonumber(h, 16)); end));
end

function M.init()
    local thunk = mem.find('FFXiMain.dll', 0, SIG_POL_THUNK, 0, 0);
    if (thunk == 0) then return false, 'polcore thunk signature not found'; end
    local tbl = mem.read_uint32(mem.read_uint32(thunk + 1));
    if (tbl == 0) then return false, 'polcore table not found'; end
    local root = AshitaCore:GetInstallPath():gsub('\\$', '') .. '\\SquareEnix\\PlayOnlineViewer\\pub\\home00\\msg\\';
    M.inbox  = root .. 'r\\b\\';
    M.outbox = root .. 'O\\m\\';
    for _, p in ipairs({ root, root .. 'r\\', M.inbox, root .. 'O\\', M.outbox }) do ffi.C.CreateDirectoryA(p, nil); end
    ffi.cast('void (__cdecl*)(void)', mem.read_uint32(tbl + SLOT_FS_INIT))();
    M.decode = ffi.cast('int (__cdecl*)(uint8_t*, const char*)', mem.read_uint32(tbl + SLOT_DECODE_NAME));
    -- polcore's own account id lives in the global read by slot 0x46C (jmp -> mov esi,[id]).
    local impl = mem.read_uint32(tbl + 0x46C);
    if (mem.read_uint8(impl) == 0xE9) then impl = impl + 5 + mem.read_int32(impl + 1); end
    for off = 0, 16 do
        if (mem.read_uint8(impl + off) == 0x8B and mem.read_uint8(impl + off + 1) == 0x35) then
            M.own_id_addr = mem.read_uint32(impl + off + 2);
            break;
        end
    end
    M.ready  = exists_dir(M.inbox);
    return M.ready, M.inbox;
end

-- The inbox belongs to whichever character is logged in. Park another character's mail in
-- msg\nf-<name>\ and bring this character's back, so nobody reads someone else's messages.
function M.claim(me)
    if (not M.ready or me == nil or me == '') then return; end
    local ownerfile = M.inbox .. '..\\nf-owner.txt';
    local f = io.open(ownerfile, 'rb');
    local owner = f and f:read('*l') or '';
    if (f) then f:close(); end
    if (owner == me) then return; end
    local root = M.inbox .. '..\\..\\';
    if (owner ~= '') then
        local stash = root .. 'nf-' .. owner .. '\\';
        ffi.C.CreateDirectoryA(stash, nil);
        for _, fname in ipairs(list(M.inbox)) do ffi.C.MoveFileA(M.inbox .. fname, stash .. fname); end
    end
    local mine = root .. 'nf-' .. me .. '\\';
    for _, fname in ipairs(list(mine)) do ffi.C.MoveFileA(mine .. fname, M.inbox .. fname); end
    local g = io.open(ownerfile, 'wb');
    if (g) then g:write(me); g:close(); end
end

local SIG_ENCODE_NAME = '83EC085355568B74241857' .. '68453E271C';   -- polcore: header -> message file name

-- Build a native message (polcore's own header builder + file-name encoder).
-- typ 1 = ordinary message, 0x11 = friend registration. Returns file name, hex body.
function M.compose(typ, from_id, to_id, from_name, to_name, subject, text)
    if (not M.ready) then return nil; end
    if (M.encode == nil) then
        local tbl = mem.read_uint32(mem.read_uint32(mem.find('FFXiMain.dll', 0, SIG_POL_THUNK, 0, 0) + 1));
        M.build  = ffi.cast('int (__cdecl*)(uint8_t*, int, uint32_t, uint32_t, uint32_t, uint32_t, const char*, const char*, int, int, int, int, int)', mem.read_uint32(tbl + 0x438));
        local enc = mem.find('polcore.dll', 0, SIG_ENCODE_NAME, 0, 0);
        if (enc == 0) then return nil; end
        M.encode = ffi.cast('int (__cdecl*)(uint8_t*, char*, int)', enc);
    end
    local body = (subject or '') .. '\7' .. (text or '') .. '\0';
    local hdr  = ffi.new('uint8_t[0x48]');
    M.build(hdr, typ, from_id, 0, to_id, 0, from_name, to_name, 0, 0, 0, 0, #body);
    local name = ffi.new('char[0x80]');
    M.encode(hdr, name, 0);
    return ffi.string(name), hex(body);
end

-- PlayOnline's network side, replaced with local equivalents so the game's own message UI completes.
-- Start functions return a task id; the matching poll returns 1 (done). Sends become outbox files that
-- flush_outbox uploads; deletes remove the inbox file. The friend-list sync poll completes at once
-- because nativefriends keeps the server in step itself.
local keep = {};
local function override(tbl, slot, sig, fn)
    local cb = ffi.cast(sig, fn);
    keep[#keep + 1] = cb;
    M.saved = M.saved or {};
    if (M.saved[slot] == nil) then M.saved[slot] = mem.read_uint32(tbl + slot); end
    mem.write_uint32(tbl + slot, tonumber(ffi.cast('uint32_t', cb)));
end

local function name_of(hdr)
    local buf = ffi.new('char[0x80]');
    M.encode(hdr, buf, 0);
    return ffi.string(buf);
end

function M.install_overrides()
    if (M.overridden or not M.ready) then return; end
    local tbl = mem.read_uint32(mem.read_uint32(mem.find('FFXiMain.dll', 0, SIG_POL_THUNK, 0, 0) + 1));
    if (M.encode == nil) then M.compose(1, 0, 0, '', '', '', ''); end
    if (M.encode == nil) then return; end
    local task = 100;
    local send = function (hdr, body)
        local ok = pcall(function ()
            local h = ffi.cast('uint8_t*', hdr);
            local size = ffi.cast('uint32_t*', h + 0x38)[0];
            local f = io.open(M.outbox .. name_of(h), 'wb');
            if (f ~= nil) then f:write(ffi.string(ffi.cast('uint8_t*', body), size)); f:close(); end
        end);
        task = task + 1;
        return ok and task or -1;
    end
    local done = function (_) return 1; end
    override(tbl, 0x444, 'int (__cdecl*)(void*, void*)', send);          -- send message
    override(tbl, 0x448, 'int (__cdecl*)(int)', done);
    override(tbl, 0x44C, 'int (__cdecl*)(void*, void*)', send);          -- send reply
    override(tbl, 0x450, 'int (__cdecl*)(int)', done);
    override(tbl, 0x454, 'void (__cdecl*)(int)', function (_) end);     -- release task
    override(tbl, 0x460, 'int (__cdecl*)(void*)', function (hdr)       -- delete message
        pcall(function () ffi.C.DeleteFileA(M.inbox .. name_of(ffi.cast('uint8_t*', hdr))); end);
        task = task + 1;
        return task;
    end);
    override(tbl, 0x464, 'int (__cdecl*)(int)', done);
    override(tbl, 0x298, 'int (__cdecl*)(int)', done);                  -- friend-list sync poll
    M.overridden = true;
end

function M.remove_overrides()
    if (not M.overridden) then return; end
    local tbl = mem.read_uint32(mem.read_uint32(mem.find('FFXiMain.dll', 0, SIG_POL_THUNK, 0, 0) + 1));
    for slot, orig in pairs(M.saved) do mem.write_uint32(tbl + slot, orig); end
    M.overridden = false;
end

-- Messages are addressed by account id; retail PlayOnline filled this in at login, together with
-- the player's own handle record, which the game checks before it will send a message.
function M.set_own_id(id, name)
    if (M.own_id_addr ~= nil and id ~= nil) then
        mem.write_uint32(M.own_id_addr, id);
        mem.write_uint32(M.own_id_addr + 4, 0);
    end
    if (id == nil or name == nil or name == '') then return; end
    if (M.handle_base == nil) then
        local tbl = mem.read_uint32(mem.read_uint32(mem.find('FFXiMain.dll', 0, SIG_POL_THUNK, 0, 0) + 1));
        local idx_fn, rec_fn = mem.read_uint32(tbl + 0x2F8), mem.read_uint32(tbl + 0x2B4);
        for off = 0, 16 do     -- 0x2F8: mov esi,[current handle index]
            if (mem.read_uint8(idx_fn + off) == 0x8B and mem.read_uint8(idx_fn + off + 1) == 0x35) then
                M.handle_idx = mem.read_uint32(idx_fn + off + 2); break;
            end
        end
        for off = 0, 48 do     -- 0x2B4: lea ecx,[eax*8 + handle table]
            if (mem.read_uint8(rec_fn + off) == 0x8D and mem.read_uint8(rec_fn + off + 1) == 0x0C and mem.read_uint8(rec_fn + off + 2) == 0xC5) then
                M.handle_base = mem.read_uint32(rec_fn + off + 3); break;
            end
        end
    end
    if (M.handle_idx == nil or M.handle_base == nil) then return; end
    local idx = mem.read_int32(M.handle_idx);
    if (idx < 0 or idx >= 0x40) then idx = 0; mem.write_uint32(M.handle_idx, 0); end
    local rec = M.handle_base + idx * 0x28;
    mem.write_uint32(rec, id);
    mem.write_uint32(rec + 4, 0);
    local bytes = {};
    for i = 1, 16 do bytes[i] = (i <= #name and i <= 15) and name:byte(i) or 0; end
    mem.write_array(rec + 8, bytes);
end

-- Recipient id of an outgoing message, straight from its encoded file name.
function M.recipient(fname)
    local hdr = ffi.new('uint8_t[0x48]');
    if (M.decode(hdr, fname) ~= 0) then return nil; end
    local flags = ffi.cast('uint16_t*', hdr + 0x3E)[0];
    return tonumber(ffi.cast('uint32_t*', hdr + 8)[0]), bit.band(bit.rshift(flags, 7), 0x1F);
end

-- Upload every file waiting in the outbox. `send(to_id, fname, hexbody, type, done)` does the network part.
function M.flush_outbox(send)
    if (not M.ready) then return; end
    for _, fname in ipairs(list(M.outbox)) do
        if (not M.sending or not M.sending[fname]) then
            local to, typ = M.recipient(fname);
            if (to == nil) then print('[nativefriends] cannot read recipient of ' .. fname); end
            local f = io.open(M.outbox .. fname, 'rb');
            local body = f and f:read('*a');
            if (f) then f:close(); end
            if (to ~= nil and body ~= nil) then
                M.sending = M.sending or {};
                M.sending[fname] = true;
                send(to, fname, hex(body), typ, function (ok)
                    M.sending[fname] = nil;
                    if (ok) then ffi.C.DeleteFileA(M.outbox .. fname); end
                end);
            end
        end
    end
end

-- Write one delivered message into the inbox. Returns true when the file is on disk.
function M.deliver(fname, hexbody)
    if (not M.ready or fname:find('[\\/:]')) then return false; end
    local f = io.open(M.inbox .. fname, 'wb');
    if (f == nil) then return false; end
    f:write(unhex(hexbody));
    f:close();
    return true;
end

return M;
