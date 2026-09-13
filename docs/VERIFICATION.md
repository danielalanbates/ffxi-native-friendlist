# Verification, 2026-09-12

Local LandSandBoat server only (no hosted server was touched). Character **Test** ran the
HorizonXI retail client under Wine on macOS with `nativefriends` loaded. Character **Buddy** was a
genuinely logged-in second player via `tools/headless_friend.py`, with a real `accounts_sessions`
row. Buddy's friend actions went through the same `friendsd` HTTP API its addon would call.

| # | Step | Evidence in Test's client | Result |
|---|---|---|---|
| 1 | Test: `/befriend Buddy` (native command, intercepted) | chat "A friend request has been sent to Buddy."; menu **Pending → (Buddy)** (`03`) | PASS |
| 2 | Buddy accepts | chat "Buddy is now on your friend list."; menu **Online Friends → (Buddy) Buddy SSandOria** (`04`), with zone 230 named by the client | PASS |
| 3 | Buddy's session ends (logout → 60 s timeout) | chat "Buddy has logged out."; open menu moves Buddy to **Offline Friends** without reopening (`05`) | PASS |
| 4 | Buddy logs in again | chat "Buddy has logged in."; open menu moves Buddy back to **Online Friends** (`06`) | PASS |
| 5 | Test: `/friendlist remove Buddy` | one notice "Buddy has been removed from your friend list."; both server lists empty | PASS |
| 6 | Buddy sends Test a request | chat "Buddy would like to add you as a friend. (/friendlist accept Buddy …)"; menu **Pending → (Buddy)** (`07`) | PASS |
| 7 | Test: `/friendlist accept Buddy` | one notice "Buddy has been added to your friend list."; Buddy's server view shows Test as friend and online in zone 231 | PASS |
| 8 | Final build regression (remove → incoming → accept → status) | "hook installed … 1 friends (1 online), 0 pending"; menu online (`08`) | PASS |

Screenshots are in `docs/screenshots/`. The server-side view was captured with `curl` at every step:
`F|Buddy|outgoing` → `F|Buddy|friend|1|230|1|1` → `F|Buddy|friend|0|230|1|1`.

## Bugs found and fixed during verification

- **Port clash.** friendsd first listened on 54230, LSB's lobby data port. On localhost it
  intercepted the lobby connection (the connect log filled with *"Session requested without valid
  sessionHash"*). Moved to 54290, and the README now lists the ports to avoid.
- **Addon conflict.** FFXIFriendList also claims `/befriend` and blocked it first. Unload it.
- **Duplicate notices.** Remove and accept printed both the action result and the poll's diff.
  After the first fix, an accepted friend also produced a spurious "has logged in". Both fixed;
  the regression (step 8) is clean.
- **Menu refresh.** The open menu kept stale rows until reopened, and the game ignored synthetic
  Escape when unfocused. Fixed by calling the menu's own row builder after each data change.
- **HeadlessXI vs this LSB build.** It reported loader version 2.1.0 (server wants 2.0.x), a
  client version outside the lock, no 0x00A `LoginPacketCheck` (login silently ignored), and no
  keepalive. All handled in `tools/headless_friend.py` and a local copy of hxiclient.

## Not verified yet

- Using the native menu's row actions (tell, invite, delete) on an injected entry.
- More than one friend at once through the server (the probe with 5 injected entries rendered correctly, see `02`).
- A remote (non-localhost) friendsd with `--no-trust-local`.
