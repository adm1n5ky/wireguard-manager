# PROGRESS LOG

Compact append-only log. English, keyword-dense, low token cost.
Format per entry: DATE | TOPIC | DECISION | FILES | FUNCTIONS.
Read this file first in any new chat for this project. Append a new
entry at the end of each completed work session, after user confirms.

---

## 2026-06-XX | Bootstrap fixes after GitHub sync drift

PROBLEM: arrow keys (^[[A^[[B) printed as text in all `read -rp` menu
prompts. Root cause: missing `-e` (readline) flag.
DECISION: `read -rp` → `read -rep` everywhere user makes a menu choice.
FILES: menu.sh, client-create.sh, status.sh, client-show.sh,
client-delete.sh, server-create.sh, server-delete.sh, validation.sh,
backend.sh, endpoint.sh, ports.sh, system.sh, common.sh,
peer-monitor.sh.

PROBLEM: `5) Interface status` called nonexistent `server_status`.
DECISION: added `server_status()` to status.sh (later replaced, see
Peer Monitor entry below).

PROBLEM: client config not shown after creation, only QR offered.
DECISION: print `cat "$c_conf_file"` between separators before
QR prompt. FUNCTIONS: client_create(), \_client_create_on()
in client-create.sh.

PROBLEM: menu item "Show QR code" only showed QR, not full
.conf+QR view that already existed in client-show.sh.
DECISION: renamed menu item to "Show client .conf & QR code", wired
to `client_show_for` instead of separate `client_show_qr`.
FILES: menu.sh.

PROBLEM: `client_show_for: command not found`.
ROOT CAUSE: client-show.sh module never added to wg-manager.sh
source loop.
DECISION: added `client-show` to module list between client-delete
and status. FILES: wg-manager.sh.

PROBLEM: after viewing .conf+QR (pause/Enter), menu redrew instantly,
wiping QR before user could read it.
DECISION: tried `do_clear` flag approach (overengineered), reverted
to simple `clear` at top of while loop — pause() in client_show_for
already blocks until Enter, so clear-on-redraw is correct behavior.
FILES: menu.sh, function `_menu_clients_for`.

---

## 2026-06-XX | CIDR validation crash (set -u unbound variable)

PROBLEM: `cidr: unbound variable` in server-create.sh after CIDR
input, intermittently (worked for /26, failed for /20 then /25).
ROOT CAUSE #1: `ipcalc -n` on Debian/Ubuntu 0.51 returns
`Network: <ip>` WITHOUT prefix, script compared to full CIDR
string with prefix → false mismatch → validate_cidr returned 1
even for valid network addresses.
DECISION: removed ipcalc branch entirely from validate_cidr, kept
only bash-math branch (ip_to_int/prefix_to_mask_int/int_to_ip from
network.sh). FILES: validation.sh.
Also removed ipcalc from BOOTSTRAP_REQUIRED (common.sh) and
REQUIRED_PACKAGES_WG (system.sh) since no longer used anywhere
in the codebase (confirmed via grep — was only used in this one
validate_cidr branch).

ROOT CAUSE #2 (deeper, found after #1 fix incomplete): bash nameref
self-capture bug. `prompt_cidr cidr` passes arg name "cidr"; inside
function `local -n _pc_out=$1` creates nameref to outer "cidr", but
`local cidr err` on next line creates a NEW local "cidr" that shadows
the nameref target. Result: _pc_out silently points to the local
copy, outer var stays unset under `set -u`.
DECISION: renamed all internal locals in prompt_\* functions to have
`_` prefix so they can never collide with the passed-in variable name.
FUNCTIONS FIXED: prompt*cidr (validation.sh: cidr→_cidr_val,
err→_cidr_err), prompt_iface_name (validation.sh: name→_iface_val,
err→_iface_err), prompt_port (ports.sh: port→_port_val,
err→_port_err), prompt_endpoint (endpoint.sh: endpoint→_ep_val,
err→_ep_err).
RULE ESTABLISHED: any function using `local -n` must prefix ALL its
other locals with `*` to prevent nameref shadowing. Documented in
README.md security section.

---

## 2026-06-XX | Peer Monitor (built in separate chat, merged here)

DECISION: replaced useless "Interface status" menu item with realtime
peer dashboard. Built in a separate chat, final version pasted here,
only fixed `read -rp`→`read -rep` and choice→_pm_choice var rename
on merge.
FILES: peer-monitor.sh (full rewrite), menu.sh (item label + case
branch → `peer_monitor`).
BUG after merge: STATUS column showed "IDLEVE" (leftover chars from
previous longer status string "ACTIVE" not cleared).
ROOT CAUSE: `tput cup` repositions cursor without clearing line;
printf without trailing clear leaves old chars when new string is
shorter.
FIX: removed trailing newline from status printf, added `tput el`
(clear to EOL) before manual `echo`. FUNCTION: \_render_peer_table
in peer-monitor.sh.

---

## 2026-06-XX | grep -c double-zero bug (recurring regression)

PROBLEM: peer count column showed correct single-line output for
instances with peers, but split across two lines for instances with
zero peers.
ROOT CAUSE: `grep -c pattern file || echo 0` — grep -c on zero matches
still prints "0" to stdout AND returns exit code 1, triggering the
`|| echo 0` fallback → "0\n0" concatenated in the captured variable.
FIX PATTERN: remove `|| echo 0`, use `created="${created:-0}"` after
plain capture instead.
STATUS: was already fixed in config-list.sh and server-delete.sh in
an earlier session; bug recurred in menu.sh because that file wasn't
included in that earlier fix pass. Re-applied fix to menu.sh
(\_peers_summary function, `created=` line) this session.
WATCH FOR: any other `grep -c ... || echo` pattern anywhere in repo —
search before assuming this class of bug is fully closed.

---

## 2026-06-XX | QR SVG generation

FEATURE: generate QR code as SVG alongside client .conf, stored at
client_dir/iface-name.svg. Auto-create if missing when viewing client
via client-show.
DECISION: qrencode moved from OPTIONAL_PACKAGES to
REQUIRED/BOOTSTRAP — needed for both terminal QR and SVG QR.
FILES: common.sh (BOOTSTRAP_REQUIRED), system.sh
(REQUIRED_PACKAGES_WG, OPTIONAL_PACKAGES emptied), client-create.sh
(new `_generate_qr_svg()` helper, called from both client_create()
and \_client_create_on(), summary block prints SVG path), client-show.sh
(auto-generate SVG if absent, print path).

BUG: `_generate_qr_svg` had literal spaces instead of newlines in the
`&&` chain (artifact of a string-replace that flattened multiline
text). Caught via code review comment.
FIX: rewrote with explicit line continuations.
RECURRING: this same flattening bug appeared twice across sessions
(a fix was applied but did not persist because repo did not have the
latest push at re-check time). WATCH: always re-verify via fresh
fetch before assuming a previous fix persisted — repo state can
regress if user pushes an older local copy or fix wasn't committed.

BUG (separate): IPv6 allocation message leaked into Address field of
client .conf — `ok "IPv6 allocated..."` writes to stdout, captured by
`client_ipv6_addrs="$(_allocate_client_ipv6 ...)"`.
FIX: redirect `ok`/`warn` inside \_allocate_client_ipv6 to stderr.
RECURRED once after a repo sync where the fix wasn't present — always
re-verify via fresh fetch before re-applying.

---

## 2026-06-XX | Full/split tunnel choice removed

DECISION (user-driven simplification): AllowedIPs is now hardcoded to
"0.0.0.0/0, 2000::/3" for every client. No interactive routing choice.
2000::/3 chosen over ::/0 to exclude IPv6 link-local/multicast
ranges — 2000::/3 covers exactly the global unicast space.
FILES: client-create.sh — removed "Routing" step block from both
client_create() and \_client_create_on(), renumbered subsequent steps.

---

## 2026-06-XX | IPv6 phase 1 — per-client dual-stack addressing

SCOPE AGREED WITH USER:

- Server may have multiple IPv4/IPv6 external blocks.
- HE tunnel is semi-permanent (kept even after native IPv6 arrives,
  used as censorship-bypass route). Do not assume tunnel is temporary.
- No tariff-plan / multi-route-on-router features in this project
  (explicitly descoped — "this is a tool for everyone").
- IPv6 pool: NO pre-generation (impractical for /64+), allocate
  on-demand, increment from last allocated.
- AllowedIPs simplified to always-on full tunnel (see entry above).

NEW FILES/FUNCTIONS:

- network.sh: ipv6_expand, validate_ipv6_cidr, ipv6_network_to_server_ip,
  ipv6_next_host, detect_ipv6_prefixes (later partially superseded,
  see "available pool" entry below) — all implemented via `python3 -c`
  since bash lacks 128-bit arithmetic.
- ip-pool.sh: pool6_allocate, pool6_release, pool6_stats, \_pool6_file.
  File: ip-pool6.dat, format: ip / status / client / cidr / timestamp
  (tab-separated).
- server-create.sh: IPv6 networks step (optional) + forwarding mode
  step added after CIDR step. .env gets WG_NETWORK6 (comma-separated
  CIDR list) and WG_IPV6_MODE. .conf Interface Address line gets IPv6
  server addresses appended.
- client-create.sh: \_allocate_client_ipv6() helper (shared by both
  client_create and \_client_create_on), allocates one address per
  CIDR in WG_NETWORK6, client .conf Address line becomes dual-stack.
- client-delete.sh: pool6_release call added after IPv4 pool_release.

DEPENDENCY NOTE: python3 confirmed present by default on Ubuntu
24.04+, used for all IPv6 arithmetic (ipaddress module). No pip
packages required. NOT yet added to BOOTSTRAP_REQUIRED defensively.

---

## 2026-06-XX | IPv6 phase 2 — available-pool registry

PROBLEM WITH PHASE 1: live-scanning `ip -6 addr show` cannot
distinguish HE tunnel point-to-point addresses (the tunnel link
itself) from real routed blocks. Routed large blocks don't appear as
interface addresses until manually carved and assigned — no reliable
way to auto-detect "ownership" from `ip addr` alone.

DECISION (user-approved): introduce persistent registry file at
/etc/wireguard/ipv6-available.conf, managed via new System menu
item. Format: cidr / type(nat66|routed) / comment. User manually
registers blocks they actually control. server-create.sh reads from
this registry instead of live-scanning interfaces.

NEW FILES/FUNCTIONS:

- common.sh: IPV6_AVAILABLE_CONF constant.
- network.sh: ipv6_read_available, ipv6_available_count,
  ipv6_available_add, ipv6_available_remove, ipv6_used_64s (scans
  BOTH .env WG_NETWORK6 of all instances AND real `ip -6 addr show`
  output to find occupied /64s — combines static config + live
  state), ipv6_carve_next_64.
- system.sh: system_ipv6_networks() (list/add/remove submenu),
  helper functions for add/remove (warns if block is referenced by
  an existing instance's WG_NETWORK6 before removal, does not block
  removal — informational only).
- menu.sh: System menu item "IPv6 Networks" → system_ipv6_networks.
- server-create.sh IPv6 step rewritten: reads ipv6_available_count();
  if 0, offers to abort and configure via System menu, or continue
  without IPv6. If >0, lists blocks with preview of next free /64,
  lets user multi-select, carves and combines mode (mixed
  nat66+routed selection falls back to nat66 as the safer default).

CARVING LOGIC (ipv6_carve_next_64), iterated twice:
v1: started from network address of the parent block itself
(::0/64) — WRONG, this is the parent block's network address, not a
valid standalone subnet for routing semantics.
v2 (final, user-specified): for blocks larger than /64, start
carving at 4th hextet = 0x1000, increment by 1 per instance
(...1000::/64, ...1001::/64, ...1002::/64...). Address space
::0–::fff in the 4th hextet reserved for infra use, never auto-carved.
Skips any /64 already in ipv6_used_64s().

CONFIG-LIST POLLUTION BUG: ipv6-available.conf sits in
/etc/wireguard/ and matched the wildcard .conf glob in
config-list.sh's unmanaged-instance scan, appearing as a fake
"ipv6-available" interface row in the server table.
FIX: config-list.sh — skip basename=="ipv6-available" explicitly,
PLUS defense-in-depth: skip any .conf without an [Interface] section
(grep check) before treating it as a WireGuard config.

UI BUGS in system_ipv6_networks list rendering (two separate, both
fixed): (1) duplicate printf calls printed the CIDR line twice
(leftover from iterative edit, two printf statements both emitting
output instead of one) — fixed to single printf. (2) type column
printed both the colored type_col variable (already contains the
word "routed"/"nat66" embedded in ANSI codes) AND the raw type value
again → visual duplication like "routedrouted" — fixed by removing
the redundant second argument, kept only the colored variable.

---

## STATUS AS OF END OF THIS CHAT

DONE: IPv4 full lifecycle, IPv6 dual-stack client addressing,
ipv6-available.conf registry + carving with correct 0x1000 offset,
Peer Monitor, QR SVG, all known nameref/grep-c/escape-sequence bug
classes fixed across the codebase (verify via fresh fetch before
assuming fixed in future sessions — repo sync has regressed fixes
before, more than once).

NOT DONE / NEXT STEPS (explicit user request, discussed in detail,
code not yet written):

1. nftables rule generator — forward + NAT/masquerade rules per
   instance, both IPv4 (already manual on server, working for two
   instances, MISSING for two other live instances found during
   discussion — those have zero internet for clients right now) and
   IPv6 NAT66 (separate ip6 nat table needed, existing nft config
   only has an ip nat table for v4). Proposed approach: generate one
   nftables fragment file per instance at server_create time, apply
   on backend_start, remove on server_delete. Detect external
   interface/IP via default route lookup rather than hardcoding.
2. DNS-over-TLS forwarding for clients — systemd-resolved stub
   listener is loopback-only; plan is DNSStubListenerExtra (supported
   on Ubuntu 24.04's systemd) bound to WG interfaces. Deliberately
   deferred — user wants nftables first, DNS "later".
3. Live server has instances with NO forward/NAT rules yet (manual
   nftables config only covers the first two instances created
   manually before this tool existed) — this is the immediate
   real-world blocker once nftables generator work starts.

ARCHITECTURE NOTES FOR FUTURE SELF:

- ipcalc is NOT a dependency anymore (removed, see CIDR bug entry).
- python3 IS a hard dependency now for all IPv6 math.
- GitHub repo is PUBLIC, readable via raw.githubusercontent.com
  fetch without auth. No git-write access exists from chat — user
  must git push manually after every file handoff. Always re-fetch
  fresh from GitHub at start of new chat / before re-applying any
  fix, do not trust Project Knowledge sync timestamp blindly (has
  gone stale mid-session before, more than once).
