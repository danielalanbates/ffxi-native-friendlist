#!/usr/bin/env python3
"""friendsd -- friend list service for LandSandBoat servers.

Runs beside the LSB database. Stores friendships in its own table (nf_friends) and reports
live presence from LSB's accounts_sessions, so the nativefriends Ashita addon can fill the
game's built-in Friend List menu.

Wire format is deliberately trivial (plain text, one record per line) so the addon needs no
JSON library:

    GET /v1/list?name=<char>                 -> lines  F|<name>|<state>|<online>|<zone>|<job>|<lvl>|<status 0 online,1 away>|<charid>
    GET /v1/request?name=<char>&target=<c>   -> OK|<message>  or  ERR|<message>
    GET /v1/accept?name=<char>&target=<c>
    GET /v1/remove?name=<char>&target=<c>    (also declines / cancels a pending request)
    GET /v1/status?name=<char>&status=online|away|invisible
    GET /v1/mail/send?name=<char>&to=<charid>&file=<native filename>&body=<hex>
    GET /v1/mail/list?name=<char>            -> lines  M|<id>|<filename>|<hex body>
    GET /v1/mail/ack?name=<char>&id=<id>     (delivered; remove from server)

state is friend | incoming | outgoing.

Authentication: a request acting for <char> is only honoured when <char> is logged in to the
map server from the same IP address the request comes from (accounts_sessions.client_addr).
Nobody can read or edit another player's list without being logged in as them.

Copyright (c) 2026 Daniel Bates. All rights reserved.
Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
batesai.org - help@batesai.org
"""
import argparse
import contextlib
import ipaddress
import os
import struct
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import pymysql

SCHEMA = """
CREATE TABLE IF NOT EXISTS nf_friends (
    charid   INT UNSIGNED NOT NULL,
    friendid INT UNSIGNED NOT NULL,
    accepted TINYINT(1)   NOT NULL DEFAULT 0,
    created  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (charid, friendid),
    KEY friendid (friendid)
)
"""
STATUS_SCHEMA = """
CREATE TABLE IF NOT EXISTS nf_status (
    charid  INT UNSIGNED NOT NULL PRIMARY KEY,
    status  TINYINT      NOT NULL DEFAULT 0,
    updated DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
)
"""
MAIL_SCHEMA = """
CREATE TABLE IF NOT EXISTS nf_mail (
    id        INT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
    to_id     INT UNSIGNED NOT NULL,
    from_id   INT UNSIGNED NOT NULL,
    filename  VARCHAR(128) NOT NULL,
    body      BLOB         NOT NULL,
    created   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    KEY to_id (to_id)
)
"""
MAX_BODY = 0x1400   # subject (0x7F) + separator + text (0xFFF) + slack
STATUSES = {'online': 0, 'away': 1, 'invisible': 2}
# A row (a, b, accepted=0) is a request from a to b. On acceptance both directions exist with
# accepted=1, so every query is "rows where charid = me".

MAX_FRIENDS = 200  # the client keeps 200 slots for this list


class Store:
    def __init__(self, cfg):
        self.cfg = cfg
        with self.cursor() as c:
            c.execute(SCHEMA)
            c.execute(STATUS_SCHEMA)
            c.execute(MAIL_SCHEMA)

    @contextlib.contextmanager
    def cursor(self):
        # One short-lived connection per call: the HTTP server is threaded and pymysql
        # connections are not thread-safe.
        db = pymysql.connect(autocommit=True, charset='utf8mb4', **self.cfg)
        try:
            with db.cursor() as c:
                yield c
        finally:
            db.close()

    def charid(self, name):
        with self.cursor() as c:
            c.execute('SELECT charid, charname FROM chars WHERE charname = %s', (name,))
            row = c.fetchone()
        return row if row else (None, None)

    def session_ip(self, charid):
        with self.cursor() as c:
            c.execute('SELECT client_addr FROM accounts_sessions WHERE charid = %s', (charid,))
            row = c.fetchone()
        if not row:
            return None
        # LSB stores the address in network byte order read as a little-endian integer.
        return str(ipaddress.IPv4Address(struct.pack('<I', row[0])))

    def listing(self, me):
        cols = """ch.charname, (s.charid IS NOT NULL), ch.pos_zone, st.mjob, st.mlvl, COALESCE(ns.status, 0), ch.charid"""
        joins = """LEFT JOIN accounts_sessions s ON s.charid = ch.charid
                   LEFT JOIN char_stats st ON st.charid = ch.charid
                   LEFT JOIN nf_status ns ON ns.charid = ch.charid"""
        with self.cursor() as c:
            c.execute('SELECT f.accepted, ' + cols + ' FROM nf_friends f JOIN chars ch ON ch.charid = f.friendid '
                      + joins + ' WHERE f.charid = %s', (me,))
            mine = c.fetchall()
            c.execute('SELECT 0, ' + cols + ' FROM nf_friends f JOIN chars ch ON ch.charid = f.charid '
                      + joins + ' WHERE f.friendid = %s AND f.accepted = 0', (me,))
            theirs = c.fetchall()
        out = []
        for accepted, name, online, zone, job, lvl, status, cid in mine:
            if accepted:
                # Invisible looks exactly like offline to friends, as on retail.
                if status == STATUSES['invisible']:
                    online, status = 0, 0
                out.append((name, 'friend', int(bool(online)), int(zone or 0) if online else 0,
                            int(job or 0), int(lvl or 0), int(status) if online else 0, int(cid)))
            else:
                out.append((name, 'outgoing', 0, 0, 0, 0, 0, int(cid)))
        # Presence stays hidden until the friendship is mutual.
        for _, name, _online, _zone, _job, _lvl, _status, cid in theirs:
            out.append((name, 'incoming', 0, 0, 0, 0, 0, int(cid)))
        return out

    def count(self, me):
        with self.cursor() as c:
            c.execute('SELECT COUNT(*) FROM nf_friends WHERE charid = %s', (me,))
            return c.fetchone()[0]

    def request(self, me, target):
        with self.cursor() as c:
            c.execute('SELECT accepted FROM nf_friends WHERE charid = %s AND friendid = %s', (me, target))
            mine = c.fetchone()
            if mine is not None:
                return 'ERR', 'already friends' if mine[0] else 'request already sent'
            if self.count(me) >= MAX_FRIENDS:
                return 'ERR', 'friend list is full'
            c.execute('SELECT 1 FROM nf_friends WHERE charid = %s AND friendid = %s', (target, me))
            if c.fetchone():
                return self.accept(me, target)
            c.execute('INSERT INTO nf_friends (charid, friendid, accepted) VALUES (%s, %s, 0)', (me, target))
        return 'OK', 'request sent'

    def accept(self, me, target):
        with self.cursor() as c:
            c.execute('SELECT 1 FROM nf_friends WHERE charid = %s AND friendid = %s AND accepted = 0', (target, me))
            if not c.fetchone():
                return 'ERR', 'no pending request from that player'
            if self.count(me) >= MAX_FRIENDS:
                return 'ERR', 'friend list is full'
            c.execute('UPDATE nf_friends SET accepted = 1 WHERE charid = %s AND friendid = %s', (target, me))
            c.execute('REPLACE INTO nf_friends (charid, friendid, accepted) VALUES (%s, %s, 1)', (me, target))
        return 'OK', 'friend added'

    def remove(self, me, target):
        with self.cursor() as c:
            n = c.execute('DELETE FROM nf_friends WHERE (charid = %s AND friendid = %s) OR (charid = %s AND friendid = %s)',
                          (me, target, target, me))
        return ('OK', 'removed') if n else ('ERR', 'not on your list')


def make_handler(store, trust_local):
    class Handler(BaseHTTPRequestHandler):
        server_version = 'friendsd/1.0'

        def log_message(self, fmt, *args):
            if os.environ.get('FRIENDSD_VERBOSE'):
                super().log_message(fmt, *args)

        def reply(self, code, body):
            data = body.encode('utf-8')
            self.send_response(code)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            url = urlparse(self.path)
            q = {k: v[0] for k, v in parse_qs(url.query).items()}
            if url.path == '/v1/ping':
                return self.reply(200, 'OK|friendsd\n')
            me, myname = store.charid(q.get('name', ''))
            if me is None:
                return self.reply(404, 'ERR|unknown character\n')
            ip = store.session_ip(me)
            peer = self.client_address[0]
            if ip is None:
                return self.reply(403, 'ERR|character is not logged in\n')
            if ip != peer and not (trust_local and peer == '127.0.0.1'):
                return self.reply(403, 'ERR|not your character\n')

            if url.path == '/v1/list':
                lines = ['S|%d' % me] + ['F|%s|%s|%d|%d|%d|%d|%d|%d' % r for r in store.listing(me)]
                return self.reply(200, '\n'.join(lines) + ('\n' if lines else ''))

            if url.path == '/v1/mail/send':
                try:
                    to_id = int(q.get('to', '0'))
                    body = bytes.fromhex(q.get('body', ''))
                except ValueError:
                    return self.reply(200, 'ERR|bad mail\n')
                fname = q.get('file', '')
                if not (0 < len(fname) <= 128) or len(body) > MAX_BODY or '/' in fname or '\\' in fname or '..' in fname:
                    return self.reply(200, 'ERR|bad mail\n')
                with store.cursor() as c:
                    c.execute('SELECT 1 FROM chars WHERE charid = %s', (to_id,))
                    if not c.fetchone():
                        return self.reply(200, 'ERR|no such recipient\n')
                    c.execute('INSERT INTO nf_mail (to_id, from_id, filename, body) VALUES (%s, %s, %s, %s)',
                              (to_id, me, fname, body))
                return self.reply(200, 'OK|sent\n')

            if url.path == '/v1/mail/list':
                with store.cursor() as c:
                    c.execute('SELECT id, filename, body FROM nf_mail WHERE to_id = %s ORDER BY id LIMIT 50', (me,))
                    rows = c.fetchall()
                return self.reply(200, ''.join('M|%d|%s|%s\n' % (i, f, bytes(b).hex()) for i, f, b in rows))

            if url.path == '/v1/mail/ack':
                with store.cursor() as c:
                    c.execute('DELETE FROM nf_mail WHERE to_id = %s AND id = %s', (me, int(q.get('id', '0'))))
                return self.reply(200, 'OK|ack\n')

            if url.path == '/v1/status':
                value = STATUSES.get(q.get('status', ''))
                if value is None:
                    return self.reply(200, 'ERR|status must be online, away or invisible\n')
                with store.cursor() as c:
                    c.execute('REPLACE INTO nf_status (charid, status) VALUES (%s, %s)', (me, value))
                return self.reply(200, 'OK|%s|%s\n' % (myname, q['status']))

            target, tname = store.charid(q.get('target', ''))
            if url.path in ('/v1/request', '/v1/accept', '/v1/remove'):
                if target is None:
                    return self.reply(200, 'ERR|no character named %s\n' % q.get('target', ''))
                if target == me:
                    return self.reply(200, 'ERR|that is you\n')
                fn = {'/v1/request': store.request, '/v1/accept': store.accept, '/v1/remove': store.remove}[url.path]
                status, msg = fn(me, target)
                return self.reply(200, '%s|%s|%s|%d\n' % (status, tname, msg, target))
            return self.reply(404, 'ERR|no such endpoint\n')

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--bind', default=os.environ.get('FRIENDSD_BIND', '127.0.0.1'))
    ap.add_argument('--port', type=int, default=int(os.environ.get('FRIENDSD_PORT', '54290')))
    ap.add_argument('--db-host', default=os.environ.get('XI_DB_HOST', '127.0.0.1'))
    ap.add_argument('--db-port', type=int, default=int(os.environ.get('XI_DB_PORT', '3306')))
    ap.add_argument('--db-user', default=os.environ.get('XI_DB_USER', 'root'))
    ap.add_argument('--db-pass', default=os.environ.get('XI_DB_PASS', ''))
    ap.add_argument('--db-name', default=os.environ.get('XI_DB_NAME', 'xidb'))
    ap.add_argument('--db-socket', default=os.environ.get('XI_DB_SOCKET'))
    ap.add_argument('--no-trust-local', action='store_true',
                    help='require the session IP to match even for requests from 127.0.0.1')
    a = ap.parse_args()
    cfg = dict(user=a.db_user, password=a.db_pass, database=a.db_name)
    if a.db_socket:
        cfg['unix_socket'] = a.db_socket
    else:
        cfg.update(host=a.db_host, port=a.db_port)
    store = Store(cfg)
    srv = ThreadingHTTPServer((a.bind, a.port), make_handler(store, not a.no_trust_local))
    print('friendsd listening on http://%s:%d' % (a.bind, a.port), flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
