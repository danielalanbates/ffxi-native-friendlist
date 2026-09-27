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

# Retail parity verification, 2026-09-13

Local LSB only. Same setup as above; every step used the game's own menus, driven by injected key
presses. The UI flows below are the retail PlayOnline ones, not addon commands.

| Retail feature | What happened in the native client | Evidence |
|---|---|---|
| Messages window | Main menu > Communication > Friend List > Messages lists mail with From / Type / Date; retail "Downloading data..." banner while loading | `09`, `10` |
| Friend request arrives as mail | `/befriend` from the other player delivers a [FWT] message; opening it shows From / Title "友達になろうよ！" and **Accept / Decline / Ignore Sender / Leave Unread** with retail help text | `11`, `15` |
| Accept | "Friend's Name:" prompt, then system line **"Accepted friend registration."**; the request is removed, a [FOK] reply is sent back, and the friend appears in To List as online with zone | `12`, `13`, `16` |
| Decline | System line **"Declined friend registration."**; the request is removed and a decline reply is sent | `14` |
| `/befriend <name>` | System line **"Requested friend registration."**; the friend shows under **Pending**; the target receives the [FWT] request | `17` |
| Accepted reply | Requester receives [FOK] "フレンド登録承諾" with **Reply / Ignore Sender / Leave Unread / Exit** | `18` |
| Away status | Friend row icon changes from the online globe to the Away face, and Send Message is disabled for an away friend | `19` |
| Send Message | Row menu > Send Message, then text, then **"Message sent."**; the message (subject "FINAL FANTASY XI") reaches the friend's inbox through friendsd | chat log + server row |
| Tell | Row menu > Tell opens "/tell Buddy" | earlier `rowsel` |
| New-mail indicator | PlayOnline envelope icon appears in the Network panel when unread mail exists | `13` |

## Bugs found and fixed while reaching parity

- **Negative fetch results** from the list stub made FFXiMain queue a PlayOnline error per empty slot. Once the file layer was on,
  that error loop blocked every message task ("Cannot do that action while processing another PlayOnline message.").
  Empty slots now return a zeroed entry.
- **Own account id and handle record** were empty on a private server; the game refused to list or send mail
  ("Failed to send. (7)"). The addon now fills both from the server's character id.
- **Recipient lookup** calls polcore's fetch directly, not through the list builder; without a table-level stub the game
  failed with "Failed to send. (10)" after a restart.
- **Network message operations** (send / reply / delete / friend sync) never complete without PlayOnline; they are
  replaced with local file operations that the addon synchronises through friendsd.
- Native `/befriend` must never reach polcore's network layer (it deadlocks the client); the addon handles it.
