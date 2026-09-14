--[[
* nativefriends -- makes Final Fantasy XI's own Friend List menu work on private servers.
*
* The client ships the whole friend list: the /friendlist and /befriend commands, the menu,
* its categories, the online/offline/pending layout. What it lacks on a private server is data:
* every entry is fetched from PlayOnline, which is gone, so the menu says "No friends
* registered." This addon redirects that one fetch to entries it builds from a friendsd server
* (see ../../server), so the real menu shows real friends with live presence.
*
* Copyright (c) 2026 Daniel Bates. All rights reserved.
* Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
* batesai.org - help@batesai.org
]]--

addon.name    = 'nativefriends';
addon.author  = 'Daniel Bates (Bates LLC)';
addon.version = '1.0';
addon.desc    = 'Fills the native FFXI friend list from a friendsd server.';
addon.link    = 'https://batesai.org';

-- Ashita 4.3 on Wine: hot LuaJIT traces fault in lj_mcode_patch. The interpreter is plenty.
jit.off();

require('common');
local ffi    = require('ffi');
local chat   = require('chat');
local net    = require('nf_net');
local record = require('nf_record');
local mail   = require('nf_mail');

pcall(ffi.cdef, [[
void* VirtualAlloc(void* addr, size_t size, unsigned long type, unsigned long protect);
]]);

local mem = ashita.memory;

local nf = {
    url       = 'http://127.0.0.1:54290',
    poll      = 10,       -- seconds between list refreshes
    last_poll = 0,
    friends   = {},       -- name -> entry from the server
    order     = {},
    ready     = false,
    hooked    = false,
    warned    = false,
    removed   = {},
    added     = {},       -- names we removed ourselves, so the poll does not announce it twice
};

----------------------------------------------------------------------------------------------------
-- Settings: one optional line "url=http://host:port" in settings.txt next to this file.
----------------------------------------------------------------------------------------------------
local function load_settings()
    local f = io.open(addon.path .. 'settings.txt', 'r');
    if (f == nil) then return; end
    for line in f:lines() do
        local k, v = line:match('^%s*(%w+)%s*=%s*(.-)%s*$');
        if (k == 'url' and v ~= '') then nf.url = v:gsub('/+$', ''); end
        if (k == 'poll' and tonumber(v)) then nf.poll = math.max(3, tonumber(v)); end
    end
    f:close();
end

local function say(msg)
    print(chat.header(addon.name):append(chat.message(msg)));
end

local function notice(msg)
    -- Same colour the client uses for its own friend notices.
    print(chat.color1(6, msg));
end

----------------------------------------------------------------------------------------------------
-- The hook.
--
-- FFXiMain rebuilds the list by calling fetch(i, out) for each of its slots and keeping those
-- whose valid bit is set. The call at the top of that fetch goes to the PlayOnline layer. We
-- point that call at a small stub that copies record i from our buffer, or returns an empty
-- entry for slots we have not filled.
----------------------------------------------------------------------------------------------------
local SIG_FETCH = '8B442404563DC80000007D0D8B4C240C5150E8';   -- call site is +0x12
local SIG_STORE = 'A1????????668B8032010000C3';               -- friend store global is [+1]
local SIG_BUILD = '83EC145355568BF133DB57895E3CC6464420';     -- friend menu: rebuild rows (thiscall)
local SIG_MENU  = '83EC1853568BF18B0D????????33DB57';         -- open friend menu instance is [[+9]]

local function u32(v)
    v = v % 4294967296;
    return { v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256 };
end

local function install()
    local hit = mem.find('FFXiMain.dll', 0, SIG_FETCH, 0, 0);
    local st  = mem.find('FFXiMain.dll', 0, SIG_STORE, 0, 0);
    if (hit == 0 or st == 0) then
        say('this client build is not supported (signature not found); the native list stays empty.');
        return false;
    end
    nf.site  = hit + 0x12;
    nf.store = mem.read_uint32(st + 1);
    nf.orig  = (nf.site + 5 + mem.read_int32(nf.site + 1)) % 4294967296;

    local build = mem.find('FFXiMain.dll', 0, SIG_BUILD, 0, 0);
    local menu  = mem.find('FFXiMain.dll', 0, SIG_MENU, 0, 0);
    if (build ~= 0 and menu ~= 0) then
        nf.rebuild   = ffi.cast('void (__thiscall*)(void*, int)', build);
        nf.menu_slot = mem.read_uint32(menu + 9);
    end

    if (nf.buf == nil) then
        nf.buf = tonumber(ffi.cast('uint32_t', ffi.C.VirtualAlloc(nil, 0x10000, 0x3000, 0x40)));
        if (nf.buf == nil or nf.buf == 0) then
            say('could not allocate memory for the friend list.');
            return false;
        end
        nf.cnt  = nf.buf + 0xFFF0;
        nf.stub = nf.buf + 0xF000;
        mem.write_uint32(nf.cnt, 0);
    end

    local code = { 0x8B,0x44,0x24,0x04, 0x3B,0x05 };                  -- mov eax,[esp+4]; cmp eax,[cnt]
    for _, b in ipairs(u32(nf.cnt)) do code[#code + 1] = b; end
    for _, b in ipairs({ 0x73,0x1D, 0x56,0x57, 0x8B,0xF0, 0xC1,0xE6,0x08, 0x81,0xC6 }) do code[#code + 1] = b; end
    for _, b in ipairs(u32(nf.buf)) do code[#code + 1] = b; end         -- add esi,buf
    for _, b in ipairs({ 0x8B,0x7C,0x24,0x10,                           -- mov edi,[esp+0x10]
                         0xB9,0x00,0x01,0x00,0x00, 0xF3,0xA4,           -- mov ecx,0x100; rep movsb
                         0x5F,0x5E, 0x33,0xC0, 0xC3,                    -- pop; pop; xor eax,eax; ret
                         -- unused slot: zero the entry and succeed, as polcore does. A negative
                         -- result makes FFXiMain queue a PlayOnline error dialog for every slot.
                         0x57, 0x8B,0x7C,0x24,0x0C, 0x33,0xC0,          -- push edi; mov edi,[esp+0xC]; xor eax,eax
                         0xB9,0x00,0x01,0x00,0x00, 0xF3,0xAA,           -- mov ecx,0x100; rep stosb
                         0x5F, 0x33,0xC0, 0xC3 }) do                    -- pop edi; xor eax,eax; ret
        code[#code + 1] = b;
    end
    mem.write_array(nf.stub, code);

    -- The same entries for every other caller of polcore's fetch (message recipient lookups and so on).
    -- Those callers pass polcore-sized 0xB0 buffers, so this copy is shorter.
    local short = {};
    for i, b in ipairs(code) do short[i] = b; end
    for i = 1, #short - 4 do
        if (short[i] == 0xB9 and short[i + 1] == 0x00 and short[i + 2] == 0x01 and short[i + 3] == 0x00 and short[i + 4] == 0x00) then
            short[i + 1] = 0xB0; short[i + 2] = 0x00;
        end
    end
    nf.stub2 = nf.buf + 0xF100;
    mem.write_array(nf.stub2, short);
    local thunk = mem.find('FFXiMain.dll', 0, 'A1????????FFA0????0000', 0, 0);
    if (thunk ~= 0) then
        nf.poltbl = mem.read_uint32(mem.read_uint32(thunk + 1));
        nf.orig29c = nf.orig29c or mem.read_uint32(nf.poltbl + 0x29C);
        mem.write_uint32(nf.poltbl + 0x29C, nf.stub2);
    end

    local rel = u32(nf.stub - (nf.site + 5));
    mem.unprotect(nf.site, 5);
    mem.write_array(nf.site, { 0xE8, rel[1], rel[2], rel[3], rel[4] });
    nf.hooked = true;
    return true;
end

local function uninstall()
    if (not nf.hooked) then return; end
    if (nf.poltbl ~= nil and nf.orig29c ~= nil) then mem.write_uint32(nf.poltbl + 0x29C, nf.orig29c); end
    local rel = u32(nf.orig - (nf.site + 5));
    mem.write_array(nf.site, { 0xE8, rel[1], rel[2], rel[3], rel[4] });
    nf.hooked = false;
end

----------------------------------------------------------------------------------------------------
-- Publishing the list into the client.
----------------------------------------------------------------------------------------------------
local function my_name()
    local party = AshitaCore:GetMemoryManager():GetParty();
    local name = party and party:GetMemberName(0) or '';
    return name;
end

local function publish()
    if (not nf.hooked) then return; end
    local world = mem.read_uint16(nf.store + 0x130);
    mem.write_uint32(nf.cnt, 0);
    local n = 0;
    for _, name in ipairs(nf.order) do
        if (n >= 200) then break; end
        local bytes = record.build(nf.friends[name], nf.friends[name].id or (n + 1), world);
        mem.write_array(nf.buf + n * 0x100, bytes);
        n = n + 1;
    end
    mem.write_uint32(nf.cnt, n);

    -- If the Friend List menu is open, redraw it now so presence changes show without reopening.
    if (nf.rebuild ~= nil) then
        local inst = mem.read_uint32(nf.menu_slot);
        if (inst ~= 0) then
            nf.rebuild(ffi.cast('void*', inst), mem.read_uint8(inst + 0x58));
        end
    end
end

local STATE_RANK = { friend = 1, incoming = 2, outgoing = 3 };

local function apply_listing(body)
    if (nf.ready and body == nf.last_body) then return; end
    nf.last_body = body;
    nf.my_id = tonumber(body:match('S|(%d+)'));
    mail.set_own_id(nf.my_id, my_name());
    local fresh, order = {}, {};
    for line in body:gmatch('[^\r\n]+') do
        local name, state, online, zone, job, lvl, rest = line:match('^F|([^|]+)|(%a+)|(%d)|(%d+)|(%d+)|(%d+)(.*)$');
        if (name ~= nil) then
            local status, cid = rest:match('^|(%d+)|?(%d*)');
            fresh[name] = { name = name, state = state, online = online == '1',
                            zone = tonumber(zone), job = tonumber(job), lvl = tonumber(lvl),
                            away = status == '1', id = tonumber(cid) };
            order[#order + 1] = name;
        end
    end
    table.sort(order, function (a, b)
        local fa, fb = fresh[a], fresh[b];
        if (fa.state ~= fb.state) then return STATE_RANK[fa.state] < STATE_RANK[fb.state]; end
        return a < b;
    end);

    nf.friends, nf.order, nf.ready = fresh, order, true;
    nf.removed, nf.added = {}, {};
    publish();
end

local sync_mail;

local function refresh()
    local me = my_name();
    if (me == '') then return; end
    nf.last_poll = os.clock();
    net.get(nf.url .. '/v1/list?name=' .. net.escape(me), function (ok, code, body)
        if (not ok or code ~= 200) then
            if (not nf.warned) then
                nf.warned = true;
                say(('friend server unavailable (%s): %s'):format(nf.url, tostring(ok and body or code)));
            end
            return;
        end
        nf.warned = false;
        apply_listing(body);
        sync_mail();
    end);
end

sync_mail = function ()
    local me = my_name();
    if (not mail.ready or me == '') then return; end
    mail.claim(me);
    net.get(nf.url .. '/v1/mail/list?name=' .. net.escape(me), function (ok, code, body)
        if (not ok or code ~= 200) then return; end
        for id, fname, hexbody in body:gmatch('M|(%d+)|([^|\r\n]+)|(%x*)') do
            if (mail.deliver(fname, hexbody)) then
                net.get(('%s/v1/mail/ack?name=%s&id=%s'):format(nf.url, net.escape(me), id), function () end);
            end
        end
    end);
    mail.flush_outbox(function (to, fname, hexbody, typ, done)
        -- The game's own Accept / Decline in Messages answers with a type 9 / type 10 message.
        if (typ == 9 or typ == 10) then
            for name, f in pairs(nf.friends) do
                if (f.id == to) then
                    local verb = (typ == 9) and 'accept' or 'remove';
                    net.get(('%s/v1/%s?name=%s&target=%s'):format(nf.url, verb, net.escape(me), net.escape(name)),
                        function () refresh(); end);
                end
            end
        end
        net.get(('%s/v1/mail/send?name=%s&to=%d&file=%s&body=%s'):format(nf.url, net.escape(me), to, net.escape(fname), hexbody),
            function (ok, code, reply)
                local good = ok and code == 200 and (reply or ''):sub(1, 2) == 'OK';
                if (not good) then say(('message upload failed: %s %s'):format(tostring(code), tostring(reply))); end
                done(good);
            end);
    end);
end

local function action(verb, target)
    local me = my_name();
    if (me == '' or target == nil or target == '') then return; end
    target = target:sub(1, 1):upper() .. target:sub(2):lower();
    net.get(('%s/v1/%s?name=%s&target=%s'):format(nf.url, verb, net.escape(me), net.escape(target)),
        function (ok, code, body)
            if (not ok) then
                say('friend server unavailable: ' .. tostring(code));
                return;
            end
            local status, who, msg, tid = (body or ''):match('^(%u+)|([^|]*)|?([^|\r\n]*)|?(%d*)');
            tid = tonumber(tid);
            if (status == 'OK' and verb == 'request' and msg == 'request sent' and tid ~= nil and mail.ready) then
                -- Retail sends a "Let's be friends!" PlayOnline message; the recipient answers it in Messages.
                local fname, hexbody = mail.compose(1, nf.my_id or 0, tid, me, who, '', '');
                if (fname ~= nil) then
                    net.get(('%s/v1/mail/send?name=%s&to=%d&file=%s&body=%s'):format(nf.url, net.escape(me), tid, net.escape(fname), hexbody), function () end);
                end
                notice('Requested friend registration.');
                refresh();
                return;
            end
            if (status == 'OK') then
                if (verb == 'remove') then nf.removed[who] = true; else nf.added[who] = true; end
                local text = ({
                    request = 'A friend request has been sent to %s.',
                    accept  = '%s has been added to your friend list.',
                    remove  = '%s has been removed from your friend list.',
                })[verb];
                if (msg == 'friend added') then text = '%s has been added to your friend list.'; end
                notice(text:format(who));
            else
                notice(('Unable to complete the request: %s'):format(msg ~= '' and msg or (who or body or '?')));
            end
            refresh();
        end);
end

----------------------------------------------------------------------------------------------------
-- Events.
----------------------------------------------------------------------------------------------------
ashita.events.register('load', 'nf_load', function ()
    load_settings();
    if (install()) then
        local ok, where = mail.init();
        if (ok) then mail.install_overrides(); else say('messages unavailable: ' .. tostring(where)); end
        refresh();
    end
end);

ashita.events.register('unload', 'nf_unload', function ()
    if (nf.cnt ~= nil) then mem.write_uint32(nf.cnt, 0); end
    mail.remove_overrides();
    uninstall();
end);

ashita.events.register('d3d_present', 'nf_tick', function ()
    net.pump();
    if (nf.hooked and os.clock() - nf.last_poll >= nf.poll) then
        refresh();
    end
end);

-- The client confirms every status change (menu, /online, /away, /hide) with this line.
local STATUS_WORDS = { Online = 'online', Away = 'away', Invisible = 'invisible' };
ashita.events.register('text_in', 'nf_status', function (e)
    local word = (e.message or ''):match('Friend List online status has been changed to .(%a+)');
    local status = word and STATUS_WORDS[word];
    local me = my_name();
    if (status == nil or me == '') then return; end
    net.get(('%s/v1/status?name=%s&status=%s'):format(nf.url, net.escape(me), status), function () end);
end);

ashita.events.register('command', 'nf_command', function (e)
    local args = e.command:args();
    if (#args == 0) then return; end
    local cmd = args[1]:lower();

    if (cmd == '/befriend') then
        e.blocked = true;
        if (args[2] == nil) then
            notice('Usage: /befriend <character name>');
        else
            action('request', args[2]);
        end
        return;
    end

    if (cmd == '/friendlist' or cmd == '/flist' or cmd == '/nativefriends') then
        local sub = args[2] and args[2]:lower() or nil;
        if (sub == nil) then
            -- Let the client open its own menu; make sure it has fresh data.
            refresh();
            if (cmd == '/nativefriends') then e.blocked = true; end
            return;
        end
        e.blocked = true;
        if (sub == 'add' or sub == 'request') then action('request', args[3]);
        elseif (sub == 'accept' or sub == 'approve') then action('accept', args[3]);
        elseif (sub == 'decline' or sub == 'deny' or sub == 'remove' or sub == 'delete' or sub == 'del') then action('remove', args[3]);
        elseif (sub == 'refresh') then refresh(); say('refreshing.');
        elseif (sub == 'server') then
            if (args[3]) then nf.url = args[3]:gsub('/+$', ''); nf.warned = false; refresh(); end
            say('server: ' .. nf.url);
        elseif (sub == 'status') then
            local on, total, pend = 0, 0, 0;
            for _, f in pairs(nf.friends) do
                if (f.state == 'friend') then total = total + 1; if (f.online) then on = on + 1; end
                else pend = pend + 1; end
            end
            say(('hook %s, server %s, %d friends (%d online), %d pending'):format(
                nf.hooked and 'installed' or 'NOT installed', nf.url, total, on, pend));
        else
            notice('/friendlist [add|accept|decline|remove <name> | refresh | status | server <url>]');
        end
    end
end);
