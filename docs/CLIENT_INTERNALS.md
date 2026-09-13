# FFXiMain friend list internals

Recovered 2026-09-12 by dynamic analysis of the HorizonXI retail client (`FFXiMain.dll` loaded at
**0x01CA0000**, size 0x00BDF000; the real `polcore.dll` is loaded at 0x10000000) on a local LSB
server. The addresses below are for that build. The addon locates everything by signature.

## Method (for the next person)

1. **Harness.** An Ashita addon reads commands from `/tmp/ffxi-pipe/cmd.txt` (via Wine's `Z:`
   drive). A line starting `LUA ` runs in-process, so `ashita.memory.*` and LuaJIT FFI can read,
   patch, call functions, and dump memory while the game runs. The addon also mirrors chat to a
   file and logs every packet.
2. **Dump.** `ashita.memory.read_array` over the module, written to a file, then analysed with
   Capstone. `ashita.memory.find` needs **unspaced** hex (`"46494E414C"`); spaced patterns
   silently return 0.
3. **Trace.** Command table → dispatcher → menu vtables → list builder → entry accessors → fetch.

## A trap worth knowing

At first `/friendlist`, `/blacklist`, and `/search` all printed *"You cannot use that command at
this time."* That was **not** a friend-list gate. A modal *"Start Seekers of Adoulin?"* prompt was
open, and it blocks every menu. Once the prompt was dismissed, the native Friend List opened and
showed *"No friends registered."* An earlier write-up (HorizonXI-on-Mac PR #28) wrongly blamed a
menu gate; this document supersedes it.

## Data path

```
/friendlist ─► command table (277 × 0x18 @ 0x1ff3418: name[16], u32, u16 id=0x3d, u16 flags)
            ─► dispatcher 0x1d1fe53 ─► 0x1d20020(id) ─► id→menu table @ 0x1fcabb0 (0x3d → menu 0x0d)
            ─► menu "friend" instance at [0x22ce8dc], vtable 0x1fd7be8
               row builder 0x1e89410 (thiscall, arg = byte [this+0x58])
                 count  = 0x1d86710()  → word [G+0x132]
                 rebuild 0x1d86720: for slot i in 0..299:
                     fetch 0x1d87720(i, &G[0xa90 + i*0x100])
                         i < 200  → call 0x1d91350(i, out)   ◄── PlayOnline layer; HOOKED HERE
                         i >= 200 → call 0x1d91360(i-200, out)
                     keep slot if fetch >= 0 and (entry[+0x98] & 1)
                     index list word[G+0x832 + n*2] = i ; count at G+0x132 and G+0x830
                 entry i = 0x1d86840(i)
G = [0x217d500]      (signature A1 ?? ?? ?? ?? 66 8B 80 32 01 00 00 C3 → [+1])
```

The fetch call site signature is `8B442404563DC80000007D0D8B4C240C5150E8`; the `E8` is at +0x12.
The addon repoints that `call` to a 45-byte stub that copies record *i* from its own buffer (or
returns -1), and restores the original call on unload.

Live refresh uses the row builder signature `83EC145355568BF133DB57895E3CC6464420`. The open
menu instance comes from `83EC1853568BF18B0D????????33DB57` → `[[+9]]` (0 when closed).

## Entry layout (0x100 bytes)

Accessors are at 0x1d871f0–0x1d87610. Only the fields below matter to the menu.

| Offset | Meaning | Accessor / use |
|---|---|---|
| +0x00 u32 (+0x04) | entry id | 0x1d87260 → row +0x08 |
| +0x08 u64 bits 13–15 | status: 1–3 = online | 0x1d872c0 / 0x1d872e0 |
| +0x08 bit 16 | character block present | 0x1d87410 |
| +0x08 bits 17–19 | index *k* of the character block at +0x18 + k·16 | 0x1d87430 |
| +0x08 bits 20–27 | byte → row +0x30 | 0x1d87280 |
| +0x08 bit 28 | **pending** (request not yet accepted) | 0x1d872a0 |
| +0x08 bits 13–15 == 4 | separate unlabeled category | 0x1d87310 |
| +0x0C bits 1–10 | icon index 1–14 (unused) | 0x1d87340 |
| +0x18+k·16: +2 u16 | block in use (== 1) | 0x1d87470 |
| … +4 u16 | zone id | 0x1d874d0 |
| … +6 u8 | world id; same-world check vs word [G+0x130] | 0x1d874a0 / 0x1d87500 |
| +0x98 u64 bit 0 | **slot valid** | 0x1d871f0 |
| +0x98 bits 1–44 | account number → row +0x28 | 0x1d87210 |
| +0x98 bits 45–50 | byte → row +0x20 | 0x1d87230 |
| +0xA0 char[16] | handle, shown "(Name)" | 0x1d87250 |
| +0xB0 bit 0 / +0xB4 char[16] | character name valid / name | 0x1d87550 |
| +0xB0 bit 6 / +0xD8 u16 | zone valid / zone id (the client prints the zone name) | 0x1d87570, 0x1d875a0 |
| +0xCC..+0xD3 bytes | job / level bytes (not yet mapped to display) | 0x1d875c0.. |
| +0xE0 bit 14 | "details hidden" (anon) | 0x1d875a0 |
| +0xF8 u8 | alternate online state (away?) | 0x1d87200 |
| +0xFC bit 0 | world field valid | 0x1d87500 |

## Categories (builder 0x1e89410)

| Condition | Header |
|---|---|
| +0xF8 != 0 → 2, or status 1–3 → 0 | **Online Friends** |
| otherwise → 1 | **Offline Friends** |
| bit 28 set → 3 | **Pending** |
| status == 4 → 4 | (blank header) |

For an online friend with a character block on the same world, the row shows handle, character
name, and zone name; see screenshot 04.

## Row actions (0x1e89d10), for future work

Case 1 builds a `/tell <name>` line from row +0x3c (entry +0xB4) through the chat input object
`[0x22cdf98]` vtable +0x24. Cases 2 and 3 invite to party or linkshell using ids at row +0x08 and
+0x0C (entry +0x00). Case 4 is 0x1d87da0, probably the delete-confirm path into PlayOnline.
