# Roadmap and continuation pathways

Written for whoever picks this up next, human or AI. Read `CLIENT_INTERNALS.md` first.

## Where it stands (2026-09-12)

Working and verified: native menu population, all three categories, live presence, request /
accept / decline / remove, retail-style chat notices, server persistence, and IP-bound auth.

## Known gaps, in priority order

1. **The menu's own actions.** Selecting a friend offers tell, party invite, and delete (see "Row
   actions" in CLIENT_INTERNALS). Tell and invite use the character name and ids from our entry,
   so they may already work; test them. Delete (case 4, 0x1d87da0) goes toward PlayOnline and
   needs a hook that calls `friendsd /v1/remove` instead.
2. **Native `/befriend` UX.** The addon intercepts the command. The client also has a befriend
   submenu (menu id 0x83) that could be hooked so right-click/target "Befriend" works too.
3. **Job and level display.** Bytes +0xCC..+0xD3 and the icon index (+0x0C bits 1–10) are read
   by the row builder but not mapped yet. friendsd already sends job and level. Probe with the
   harness the same way categories were decoded (screenshot 02).
4. **Anonymous flag.** +0xE0 bit 14 hides details. Map it to LSB's `/anon` (char flags) so
   friends can't see an anonymous player's zone.
5. **Remote hosting.** Serve friendsd behind TLS and use `--no-trust-local`. Consider a per-account
   token instead of IP binding when players share a NAT.
6. **Launcher integration (HorizonXI-on-Mac).** Start friendsd alongside the local LSB world in
   `lsb-server.sh`, ship the addon in the bundle, and remove FFXIFriendList from the local-world
   script so the two don't fight over `/befriend`. That needs a launcher rebuild; the addon is
   already copied into `C:\HorizonXI\addons\nativefriends` in the live prefix but isn't
   auto-loaded.

## Alternative pathways

- **A. Native LSB module (best long-term for server operators).** Replace friendsd with C++/Lua
  inside LSB. The map server already knows sessions, so presence can be pushed instead of polled.
  Transport to the addon could be an unused S2C packet id (Ashita `packet_in` sees unknown ids),
  so no HTTP at all. This is what a server team like HorizonXI would ship.
- **B. PlayOnline emulation.** Answer the real `0x1d91350` path by emulating what polcore expects
  (xiloader's IPOLCoreCom). That's heavier and brittle; only worth it if hooking FFXiMain is ever
  unacceptable.
- **C. Keep the addon hook, swap the backend.** `nf_net` only needs a `list` endpoint that returns
  `F|name|state|online|zone|job|lvl` lines, so any backend (Tanyrus's API, a Discord bot, a
  flat file) can drive the native menu.

## Test rig reminders

- Dismiss the *Seekers of Adoulin* prompt first; while it's open, every menu command is refused.
- An 8 GB Mac can't run two graphical clients safely. Use `tools/headless_friend.py` for the second player.
- HeadlessXI must match the server: loader version 2.0.x, and `XI_CLIENT_VER` within the server's
  `CLIENT_VER` lock (check `xi_connect.log` if login stalls after `lobby_data_0xA1 (1)`).
