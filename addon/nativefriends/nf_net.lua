--[[
* nf_net -- tiny non-blocking HTTP/1.0 GET over LuaSocket, pumped once per frame.
*
* The game thread must never wait on the network, so every request is a small state machine:
* connect (non-blocking), send, read until the server closes, then call back.
*
* Copyright (c) 2026 Daniel Bates. All rights reserved.
* Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
]]--

local install = AshitaCore:GetInstallPath():gsub('\\$', '');
package.path = install .. '\\addons\\libs\\?.lua;' .. install .. '\\addons\\libs\\socket\\?.lua;' .. package.path;

local ok, socket = pcall(require, 'socket');

local M = { pending = {} };

local TIMEOUT = 5;

function M.escape(s)
    return (tostring(s):gsub('[^%w%-_%.~]', function (c) return ('%%%02X'):format(c:byte()); end));
end

function M.available()
    return ok;
end

function M.get(url, cb)
    if (not ok) then
        cb(false, 'LuaSocket unavailable', nil);
        return;
    end
    local host, port, path = url:match('^http://([^/:]+):?(%d*)(/?.*)$');
    if (host == nil) then
        cb(false, 'bad url ' .. url, nil);
        return;
    end
    local s = socket.tcp();
    s:settimeout(0);
    s:connect(host, tonumber(port) or 80);
    M.pending[#M.pending + 1] = {
        sock = s, cb = cb, started = socket.gettime(), state = 'connect', buf = {},
        req = ('GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n'):format(path ~= '' and path or '/', host),
        sent = 0,
    };
end

local function finish(p, success, a, b)
    pcall(function () p.sock:close(); end);
    p.done = true;
    local good, err = pcall(p.cb, success, a, b);
    if (not good) then print('[nativefriends] callback error: ' .. tostring(err)); end
end

function M.pump()
    if (#M.pending == 0) then return; end
    local now = socket.gettime();
    for _, p in ipairs(M.pending) do
        if (not p.done) then
            if (now - p.started > TIMEOUT) then
                finish(p, false, 'timeout', nil);
            elseif (p.state == 'connect') then
                local _, w = socket.select(nil, { p.sock }, 0);
                if (w and #w > 0) then p.state = 'send'; end
            end
            if (not p.done and p.state == 'send') then
                local n, err, partial = p.sock:send(p.req, p.sent + 1);
                local last = n or partial;
                if (last) then p.sent = last; end
                if (p.sent >= #p.req) then
                    p.state = 'recv';
                elseif (err and err ~= 'timeout') then
                    finish(p, false, err, nil);
                end
            end
            if (not p.done and p.state == 'recv') then
                local data, err, partial = p.sock:receive(8192);
                local chunk = data or partial;
                if (chunk and #chunk > 0) then p.buf[#p.buf + 1] = chunk; end
                if (err == 'closed') then
                    local raw = table.concat(p.buf);
                    local code = tonumber(raw:match('^HTTP/%d%.%d (%d+)'));
                    local body = raw:match('\r\n\r\n(.*)$') or '';
                    if (code == nil) then
                        finish(p, false, 'bad response', nil);
                    else
                        finish(p, true, code, body);
                    end
                elseif (err and err ~= 'timeout') then
                    finish(p, false, err, nil);
                end
            end
        end
    end
    local keep = {};
    for _, p in ipairs(M.pending) do
        if (not p.done) then keep[#keep + 1] = p; end
    end
    M.pending = keep;
end

return M;
