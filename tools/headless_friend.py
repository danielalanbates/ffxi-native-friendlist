#!/usr/bin/env python3
"""headless_friend -- log a second character in to a LOCAL LandSandBoat server with no game client.

Used to verify the friend list with two real players on an 8 GB machine: one graphical client
plus this. It uses LandSandBoat's own HeadlessXI (tools/headlessxi in an LSB checkout, imported,
not copied) with two fixes this server build needs:

* the 0x00A login packet's LoginPacketCheck byte (sum of bytes +0x08..end) -- without it the map
  server silently ignores the login and drops the pending session after 60 s;
* a repeat of that packet every 15 s, which keeps the session alive (MAP MAX_TIME_LASTUPDATE).

The character is online (a real accounts_sessions row) until the stop file appears; the session
then ends 60 s later, exactly like a disconnect.

    LSB_ROOT=/path/to/lsb XI_USER=... XI_PASS=... XI_CHARID=2 python3 headless_friend.py
    touch /tmp/headless_friend.stop     # log out

Only ever point this at your own local server.

Copyright (c) 2026 Daniel Bates. All rights reserved.
Licensed under PolyForm Noncommercial 1.0.0 with a 10% revenue-share rider - see LICENSE.
"""
import os
import sys
import time

os.chdir(os.environ['LSB_ROOT'])
sys.path.insert(0, '.')

from tools.headlessxi.hxiclient import HXIClient  # noqa: E402
from tools.headlessxi.packets import packets       # noqa: E402
from tools.headlessxi.util import util, PACKET_HEAD  # noqa: E402

_orig_0a = packets.to_map_0a


def _login_0a(char_id):
    d = _orig_0a(char_id)
    d[PACKET_HEAD + 4] = sum(d[PACKET_HEAD + 8:PACKET_HEAD + 92]) & 0xFF
    util.packet_md5(d)
    return d


packets.to_map_0a = staticmethod(_login_0a)

# Must match the first six digits of the server's CLIENT_VER (see the connect log if login stalls).
client_ver = os.environ.get('XI_CLIENT_VER', '30251100_0')
stop_file = os.environ.get('XI_STOP_FILE', '/tmp/headless_friend.stop')

c = HXIClient(os.environ['XI_USER'], os.environ['XI_PASS'], os.environ.get('XI_SERVER', '127.0.0.1'),
              client_str=client_ver)
c.char_id = int(os.environ['XI_CHARID'])
c.login()
print('LOGGED_IN', flush=True)

last = time.time()
while not os.path.exists(stop_file):
    time.sleep(1)
    if time.time() - last > 15:
        c.map_sock.sendto(packets.to_map_0a(c.char_id), c.map_server)
        last = time.time()
c.logout()
print('LOGGED_OUT', flush=True)
