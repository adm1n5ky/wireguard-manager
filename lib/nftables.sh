#!/usr/bin/env bash
# =============================================================================
# lib/nftables.sh — Per-instance nftables rules (forward + NAT + MSS + offload)
#                    + foreign default-drop input chain detection/live-fix
#
# DESIGN PRINCIPLES (see chat HANDOVER for full discussion):
#
#   - One nft table per instance: "wg_manager_<iface>". Never touches any
#     other table, never flushes the ruleset, never adds rules outside its
#     own table — EXCEPT for the one narrow, explicit, confirmed exception
#     described below (foreign default-drop input allow).
#   - SAFETY GUARANTEE: our own wg_manager_<iface> table NEVER uses a `drop`
#     verdict and NEVER sets `policy drop`, anywhere, on any chain. In
#     nftables, `drop` is the only verdict that is final across the whole
#     hook — `accept` (rule or policy) is NOT final, evaluation continues
#     to the next base chain on the same hook regardless of priority
#     (confirmed: wiki.nftables.org, "Configuring chains"). Because this
#     module only ever emits `accept` in its own table, that table is
#     structurally incapable of blocking SSH or anything else — this holds
#     regardless of priority number, so standard named priorities
#     (filter=0, srcnat=100) are used for readability.
#   - REAL-WORLD COROLLARY (found in production, msk-01, wg101): our
#     `accept` cannot rescue traffic from a DIFFERENT table's `policy drop`
#     on the same hook either — that other chain is evaluated independently
#     and its drop is final regardless of what our table decided. This is
#     the normal case on any server with a pre-existing hand-written
#     default-drop input firewall (the standard, common setup — not an
#     edge case). When detected, wg-manager:
#       1. never edits that foreign table/file automatically,
#       2. offers a single, explicit, confirmed `nft add rule` LIVE fix
#          (idempotent — checked via a comment tag before adding),
#       3. always states clearly that the live fix does not survive a
#         `nft -f` reload or reboot,
#       4. provides a persistent version (System → Nftables Rules) that
#          the admin pastes into their own file by hand — wg-manager never
#          writes to a file it did not create itself.
#   - Fragment files (our own table) live in /etc/wireguard/nftables.d/
#     <iface>.conf and are included from /etc/nftables.conf via one
#     `include` line, appended once. The main conf is never rewritten,
#     only appended to if the include line is missing.
#   - Every apply of our own table is `nft -c -f` (checked) before `nft -f`
#     (live). A failed check never touches the live ruleset — nft
#     transactions are atomic.
#   - Fragments are only generated/applied once the instance interface is
#     actually up (called from backend_start success paths) — the
#     flowtable's `devices = { ext_if, iface }` requires both interfaces to
#     exist at load time.
#   - Stopped instance: live table deleted via `nft delete table inet
#     wg_manager_<iface>` (renaming the file alone does not affect the live
#     ruleset), fragment renamed to <iface>.conf.stop (excluded by the
#     include glob).
#   - Deleted instance: live table deleted, fragment removed entirely.
# =============================================================================

NFT_MAIN_CONF="/etc/nftables.conf"
NFT_FRAG_DIR="${WG_CONFIG_DIR}/nftables.d"

_nft_table_name()           { echo "wg_manager_$1"; }
_nft_flowtable_name()       { echo "fast_path_$1"; }
nft_fragment_path()         { echo "${NFT_FRAG_DIR}/${1}.conf"; }
nft_fragment_stopped_path() { echo "${NFT_FRAG_DIR}/${1}.conf.stop"; }

# --- Availability -------------------------------------------------------

nft_available() { command -v nft &>/dev/null; }

# --- Bootstrap: package presence, fragment dir, include line, service ----

nft_ensure_bootstrap() {
    if ! nft_available; then
        warn "nft (nftables) is not installed."
        return 1
    fi

    mkdir -p "$NFT_FRAG_DIR"
    chmod 700 "$NFT_FRAG_DIR"

    if [[ ! -f "$NFT_MAIN_CONF" ]]; then
        warn "${NFT_MAIN_CONF} not found — is nftables.service configured to load it?"
        warn "Check: systemctl cat nftables.service | grep ExecStart"
        return 1
    fi

    local include_line="include \"${NFT_FRAG_DIR}/*.conf\""
    if ! grep -qxF "$include_line" "$NFT_MAIN_CONF" 2>/dev/null; then
        msg "Adding include line to ${NFT_MAIN_CONF}..."
        {
            echo ""
            echo "# Added by wg-manager — do not remove"
            echo "$include_line"
        } >> "$NFT_MAIN_CONF"
        ok "Include line added: ${include_line}"
    fi

    if ! systemctl is-active --quiet nftables 2>/dev/null; then
        warn "nftables.service is not active."
        read -rep "Enable and start nftables.service now? [Y/n]: " _nft_enable
        _nft_enable="${_nft_enable:-Y}"
        if [[ "${_nft_enable,,}" == "y" ]]; then
            if systemctl enable --now nftables 2>/dev/null; then
                ok "nftables.service started."
            else
                warn "Failed to start nftables.service. Check: systemctl status nftables"
                return 1
            fi
        else
            warn "Skipping — instance rules will be written but not applied live."
            return 1
        fi
    fi

    return 0
}

# --- Persistent config file (source of truth for reload/reboot) ------------
# Resolved from nftables.service's actual ExecStart, not assumed, since the
# unit can be overridden. Falls back to the NFT_MAIN_CONF constant if
# detection fails for any reason.

nft_main_conf_from_service() {
    local execstart
    execstart="$(systemctl show -p ExecStart --value nftables.service 2>/dev/null)"
    [[ -z "$execstart" ]] && return 1

    local found
    found="$(echo "$execstart" | grep -oP '(?<=-f )\S+' | head -1)"
    [[ -z "$found" ]] && return 1

    echo "$found"
}

# --- External interface detection -----------------------------------------

nft_detect_ext_iface() {
    ip -o route show default 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit } }
    '
}

# Usage: prompt_nft_ext_iface VARNAME
prompt_nft_ext_iface() {
    local -n _pnx_out=$1
    local _nx_detected _nx_val _nx_force

    _nx_detected="$(nft_detect_ext_iface)"

    if [[ -n "$_nx_detected" ]]; then
        info "Detected external (WAN) interface: ${BOLD}${_nx_detected}${NC}"
    else
        warn "Could not auto-detect external interface (no default route found)."
    fi

    while true; do
        if [[ -n "$_nx_detected" ]]; then
            read -rep "External interface for NAT/forwarding [${_nx_detected}]: " _nx_val
            _nx_val="${_nx_val:-$_nx_detected}"
        else
            read -rep "External interface for NAT/forwarding (required): " _nx_val
        fi
        _nx_val="${_nx_val// /}"

        if [[ -z "$_nx_val" ]]; then
            warn "External interface cannot be empty."
            continue
        fi

        if ! ip link show "$_nx_val" &>/dev/null; then
            warn "Interface '${_nx_val}' not found on this system."
            read -rep "Use it anyway (e.g. it will exist later)? [y/N]: " _nx_force
            [[ "${_nx_force,,}" != "y" ]] && continue
        fi

        _pnx_out="$_nx_val"
        return 0
    done
}

# --- MSS calculation --------------------------------------------------------
# IPv4 header overhead: 20 (IP) + 20 (TCP) = 40
# IPv6 header overhead: 40 (IPv6) + 20 (TCP) = 60

_nft_mss_v4() { echo $(( $1 - 40 )); }
_nft_mss_v6() { echo $(( $1 - 60 )); }

# --- Fragment generation ----------------------------------------------------
# Reads all parameters from the instance's .env — never prompts here.
# Prints the fragment path on success (stdout), nothing on failure.

nft_write_fragment() {
    local iface="$1"
    local env_file
    env_file="$(env_path "$iface")"

    if [[ ! -f "$env_file" ]]; then
        warn "No .env for '${iface}' — cannot generate nftables fragment."
        return 1
    fi

    local port network network6 ipv6_mode mtu ext_if
    port="$(env_get "$env_file" WG_PORT)"
    network="$(env_get "$env_file" WG_NETWORK)"
    network6="$(env_get "$env_file" WG_NETWORK6)"
    ipv6_mode="$(env_get "$env_file" WG_IPV6_MODE)"
    mtu="$(env_get "$env_file" WG_MTU)"; mtu="${mtu:-1420}"
    ext_if="$(env_get "$env_file" WG_EXT_IFACE)"

    if [[ -z "$ext_if" ]]; then
        ext_if="$(nft_detect_ext_iface)"
        if [[ -z "$ext_if" ]]; then
            warn "No WG_EXT_IFACE set for '${iface}' and auto-detect failed."
            warn "Set it manually: add WG_EXT_IFACE=<iface> to $(env_path "$iface")"
            return 1
        fi
        warn "WG_EXT_IFACE not set for '${iface}' — using detected '${ext_if}' (not saved to .env)."
    fi

    if [[ -z "$port" || -z "$network" ]]; then
        warn "Incomplete .env for '${iface}' (missing port/network) — cannot generate fragment."
        return 1
    fi

    if ! ip link show "$iface" &>/dev/null; then
        warn "Interface '${iface}' does not exist (not up) — cannot generate fragment yet."
        warn "Rules are generated only after the interface is started."
        return 1
    fi

    local table_name flowtable_name
    table_name="$(_nft_table_name "$iface")"
    flowtable_name="$(_nft_flowtable_name "$iface")"

    local mss_v4 mss_v6
    mss_v4="$(_nft_mss_v4 "$mtu")"
    mss_v6="$(_nft_mss_v6 "$mtu")"

    mkdir -p "$NFT_FRAG_DIR"
    chmod 700 "$NFT_FRAG_DIR"

    local frag_file tmp_file
    frag_file="$(nft_fragment_path "$iface")"
    tmp_file="$(mktemp)"

    {
        echo "# wg-manager — nftables fragment for instance: ${iface}"
        echo "# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "# DO NOT EDIT manually — regenerated on every instance start."
        echo "#"
        echo "# Safety invariant: this table never uses 'drop' or 'policy drop'."
        echo "# 'accept' is not terminal across chains in nftables — only 'drop' is."
        echo "# This table therefore cannot block SSH or anything outside its own"
        echo "# forward/postrouting/input rules for this one instance. It also"
        echo "# cannot override a DIFFERENT table's 'policy drop' on the same hook"
        echo "# (see System -> Nftables Rules if this instance has connectivity"
        echo "# issues on a server with a pre-existing default-drop firewall)."
        echo "table inet ${table_name} {"
        echo ""
        echo "    flowtable ${flowtable_name} {"
        echo "        hook ingress priority filter"
        echo "        devices = { ${ext_if}, ${iface} }"
        echo "    }"
        echo ""
        echo "    chain input {"
        echo "        type filter hook input priority filter; policy accept;"
        echo "        ct state established,related accept"
        echo "        udp dport ${port} accept"
        echo "    }"
        echo ""
        echo "    chain forward {"
        echo "        type filter hook forward priority filter; policy accept;"
        echo ""
        echo "        ct state established,related accept"
        echo ""
        echo "        # MSS clamping — instance MTU ${mtu}"
        echo "        # IPv4 overhead 40 -> MSS ${mss_v4} | IPv6 overhead 60 -> MSS ${mss_v6}"
        echo "        meta nfproto ipv4 iifname \"${iface}\" tcp flags syn tcp option maxseg size set ${mss_v4}"
        echo "        meta nfproto ipv6 iifname \"${iface}\" tcp flags syn tcp option maxseg size set ${mss_v6}"
        echo "        meta nfproto ipv4 oifname \"${iface}\" tcp flags syn tcp option maxseg size set ${mss_v4}"
        echo "        meta nfproto ipv6 oifname \"${iface}\" tcp flags syn tcp option maxseg size set ${mss_v6}"
        echo ""
        echo "        # Flow offload — established TCP/UDP bypass the classic path."
        echo "        # MSS clamping rules above MUST stay before this (new SYNs need"
        echo "        # to be clamped before their connection enters the fast path)."
        echo "        ip protocol { tcp, udp } ct state established flow add @${flowtable_name}"
        echo "        ip6 nexthdr { tcp, udp } ct state established flow add @${flowtable_name}"
        echo ""
        echo "        iifname \"${iface}\" accept"
        echo "    }"
        echo ""
        echo "    chain postrouting {"
        echo "        type nat hook postrouting priority srcnat; policy accept;"
        echo ""
        echo "        ip saddr ${network} oifname \"${ext_if}\" masquerade"

        if [[ -n "$network6" ]]; then
            local -a _nets6
            IFS=',' read -ra _nets6 <<< "$network6"
            local _n6
            for _n6 in "${_nets6[@]}"; do
                _n6="${_n6// /}"
                [[ -z "$_n6" ]] && continue
                if [[ "$ipv6_mode" == "nat66" ]]; then
                    echo "        ip6 saddr ${_n6} oifname \"${ext_if}\" masquerade"
                else
                    echo "        # ${_n6} is routed — no masquerade needed"
                fi
            done
        fi

        echo "    }"
        echo "}"
    } > "$tmp_file"

    local check_err
    check_err="$(mktemp)"
    if ! nft -c -f "$tmp_file" 2>"$check_err"; then
        warn "Generated nftables fragment failed validation for '${iface}':"
        sed 's/^/    /' "$check_err" >&2
        rm -f "$tmp_file" "$check_err"
        return 1
    fi
    rm -f "$check_err"

    mv "$tmp_file" "$frag_file"
    chmod 600 "$frag_file"
    rm -f "$(nft_fragment_stopped_path "$iface")"

    echo "$frag_file"
}

# =============================================================================
# Foreign default-drop input chain detection + live-fix
# =============================================================================

# Print "<family>\t<table>\t<chain>" for every base chain on hook=input with
# policy=drop, excluding wg-manager's own wg_manager_* tables. Uses `nft -j`
# (JSON) parsed via python3 — more robust than scraping human-readable output.
nft_foreign_drop_chains() {
    nft -j list ruleset 2>/dev/null | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for obj in data.get('nftables', []):
    c = obj.get('chain')
    if not c:
        continue
    if c.get('hook') not in ('input', 'forward'):
        continue
    if c.get('policy') != 'drop':
        continue
    table = c.get('table', '')
    if table.startswith('wg_manager_'):
        continue
    print(f\"{c.get('family','')}\t{table}\t{c.get('name','')}\t{c.get('hook','')}\")
"
}

# Check whether a rule with the given comment already exists in a chain.
# Returns 0 (found) / 1 (not found).
_nft_foreign_rule_exists() {
    local family="$1" table="$2" chain="$3" comment="$4"
    nft -j list chain "$family" "$table" "$chain" 2>/dev/null | python3 -c "
import json, sys
target = sys.argv[1]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for obj in data.get('nftables', []):
    r = obj.get('rule')
    if not r:
        continue
    if r.get('comment') == target:
        sys.exit(0)
sys.exit(1)
" "$comment"
}

# Called after our own table is applied successfully. Detects any foreign
# default-drop input chain, and — only with explicit per-chain confirmation —
# adds a single idempotent live 'accept' rule for this instance's UDP port.
# Never edits any file. Never adds more than one rule per (chain, instance)
# pair, checked via a comment tag.
nft_offer_foreign_allow() {
    local iface="$1"
    local env_file port ext_if
    env_file="$(env_path "$iface")"
    port="$(env_get "$env_file" WG_PORT)"
    ext_if="$(env_get "$env_file" WG_EXT_IFACE)"
    [[ -z "$ext_if" ]] && ext_if="$(nft_detect_ext_iface)"
    [[ -z "$port" ]] && return 0

    local foreign
    foreign="$(nft_foreign_drop_chains)"
    [[ -z "$foreign" ]] && return 0

    local comment="wg-manager: ${iface}"

    while IFS=$'\t' read -r family table chain hook; do
        [[ -z "$table" ]] && continue

        if _nft_foreign_rule_exists "$family" "$table" "$chain" "$comment"; then
            continue
        fi

        echo
        warn "Found a default-drop ${hook} firewall: ${family} table '${table}', chain '${chain}'."

        local -a rule_expr
        case "$hook" in
            input)
                warn "Instance '${iface}' UDP port ${port} is NOT in its allow-list."
                warn "Clients will see repeated handshake retries and never connect."
                rule_expr=(udp dport "$port" accept)
                ;;
            forward)
                if [[ -z "$ext_if" ]]; then
                    warn "Instance '${iface}' traffic is NOT in this forward allow-list, and no"
                    warn "external interface could be determined — skipping automatic fix."
                    warn "Add manually: iifname \"${iface}\" oifname <ext-if> accept"
                    continue
                fi
                warn "Instance '${iface}' forwarded traffic is NOT in this chain's allow-list."
                warn "Handshakes may succeed but clients will have NO internet access."
                warn "NOTE: this assumes ${table}/${chain} already has a generic"
                warn "'ct state established,related accept' rule for return traffic"
                warn "(near-universal pattern) — if not, add that manually too."
                rule_expr=(iifname "$iface" oifname "$ext_if" accept)
                ;;
            *)
                continue
                ;;
        esac

        echo
        read -rep "Add a LIVE 'accept' rule to ${table}/${chain} (${hook}) now? [Y/n]: " _fw_ans
        _fw_ans="${_fw_ans:-Y}"

        if [[ "${_fw_ans,,}" == "y" ]]; then
            local apply_err
            apply_err="$(mktemp)"
            if nft add rule "$family" "$table" "$chain" \
                   "${rule_expr[@]}" comment "\"${comment}\"" 2>"$apply_err"; then
                ok "Live rule added: ${rule_expr[*]} (${table}/${chain})."
                warn "LIVE ONLY — this will NOT survive 'nft -f' or a reboot."
                warn "To persist it: System -> Nftables Rules"
            else
                warn "Failed to add live rule:"
                sed 's/^/    /' "$apply_err" >&2
            fi
            rm -f "$apply_err"
        else
            warn "Skipped. '${iface}' may not work correctly until ${table}/${chain} allows it."
        fi
    done <<< "$foreign"
}

# --- Lifecycle hooks ---------------------------------------------------------

# Call after backend_start succeeded (interface is confirmed up).
nft_instance_start() {
    local iface="$1"

    nft_available || { warn "nft not installed — skipping firewall rules for ${iface}."; return 1; }
    nft_ensure_bootstrap || { warn "nftables bootstrap incomplete — skipping firewall rules for ${iface}."; return 1; }

    local frag_file
    frag_file="$(nft_write_fragment "$iface")" || return 1

    msg "Applying nftables rules for ${iface}..."
    local apply_err
    apply_err="$(mktemp)"
    if nft -f "$frag_file" 2>"$apply_err"; then
        ok "nftables rules applied (table: $(_nft_table_name "$iface"))."
        rm -f "$apply_err"
        nft_offer_foreign_allow "$iface"
        return 0
    else
        warn "Failed to apply nftables rules for ${iface}:"
        sed 's/^/    /' "$apply_err" >&2
        rm -f "$apply_err"
        return 1
    fi
}

# Call after backend_stop succeeded (interface confirmed down).
nft_instance_stop() {
    local iface="$1"
    nft_available || return 0

    local table_name
    table_name="$(_nft_table_name "$iface")"

    if nft list table inet "$table_name" &>/dev/null; then
        if nft delete table inet "$table_name" 2>/dev/null; then
            ok "nftables table removed: ${table_name}"
        else
            warn "Failed to remove nftables table: ${table_name}"
        fi
    fi

    local frag_file stop_file
    frag_file="$(nft_fragment_path "$iface")"
    stop_file="$(nft_fragment_stopped_path "$iface")"

    [[ -f "$frag_file" ]] && mv "$frag_file" "$stop_file"
}

# Call during server_delete, before removing conf/env/keydir.
nft_instance_delete() {
    local iface="$1"
    nft_available || return 0

    local table_name
    table_name="$(_nft_table_name "$iface")"

    if nft list table inet "$table_name" &>/dev/null; then
        if nft delete table inet "$table_name" 2>/dev/null; then
            ok "nftables table removed: ${table_name}"
        else
            warn "Failed to remove nftables table: ${table_name}"
        fi
    fi

    rm -f "$(nft_fragment_path "$iface")" "$(nft_fragment_stopped_path "$iface")"
}