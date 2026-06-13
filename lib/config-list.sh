#!/usr/bin/env bash
# =============================================================================
# lib/config-list.sh — List all WireGuard instances (managed + unmanaged)
# =============================================================================

_iface_state() {
    local iface="$1"
    if ip link show "$iface" &>/dev/null 2>&1; then
        ip link show "$iface" 2>/dev/null | head -1 | grep -q "UP" && echo "UP" || echo "DOWN"
    else
        echo "STOPPED"
    fi
}

_iface_boot() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface" 2>/dev/null || echo "wg")"
    systemctl is-enabled "$(_systemd_unit "$backend" "$iface")" &>/dev/null && echo "YES" || echo "NO"
}

_iface_id() {
    local iface="$1"
    ip link show "$iface" 2>/dev/null | awk -F': ' 'NR==1{print $1}' | tr -d ' '
}

_conf_address() {
    grep -m1 "^Address" "$1" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

_conf_port() {
    grep -m1 "^ListenPort" "$1" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

_peers_summary() {
    local iface="$1"
    local env_file conf_file
    env_file="$(env_path  "$iface")"
    conf_file="$(conf_path "$iface")"

    local total="-" created=0 active="-"

    local network prefix
    network="$(env_get "$env_file" WG_NETWORK 2>/dev/null)"
    if [[ -n "$network" ]]; then
        prefix="${network#*/}"
        if [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix <= 30 )); then
            total=$(( (1 << (32 - prefix)) - 3 ))
        fi
    fi

    if [[ -f "$conf_file" ]]; then
        created="$(grep -c '^\[Peer\]' "$conf_file" 2>/dev/null || echo 0)"
    fi

    if backend_is_up "$iface" 2>/dev/null; then
        active="$(backend_show "$iface" 2>/dev/null | \
            grep "latest handshake" | \
            awk -v now="$(date +%s)" '{
                for(i=1;i<=NF;i++) if($i~/^[0-9]+$/ && $i>1000000){if(now-$i<180)c++;break}
            } END{print c+0}')"
    fi

    echo "${total}/${created}/${active}"
}

# Print a row without ANSI codes breaking printf padding.
# We use plain printf for the fixed columns, then append coloured words manually.
_row() {
    # $1=id $2=iface $3=backend $4=state $5=boot $6=mgr_plain $7=addr $8=port $9=peers
    # $10=state_colour $11=mgr_colour
    local id="$1" iface="$2" backend="$3" state="$4" boot="$5"
    local mgr_plain="$6" addr="$7" port="$8" peers="$9"
    local state_col="${10}" mgr_col="${11}"

    # Fixed-width plain part (no ANSI codes inside printf format)
    printf "  %-4s %-16s %-8s " "$id" "$iface" "$backend"
    # Coloured STATE — pad to 9 chars (longest: STOPPED=7 + 2 spaces)
    printf "%b%-$((9 - ${#state}))s" "$state_col" ""
    printf "%-5s " "$boot"
    # Coloured MGR — pad to 5 chars
    printf "%b%-$((5 - ${#mgr_plain}))s" "$mgr_col" ""
    printf "%-22s %-6s %s\n" "$addr" "$port" "$peers"
}

config_list() {
    local SEP="══════════════════════════════════════════════════════════════════════════════"
    echo
    echo -e "${BOLD}${SEP}${NC}"
    printf "${BOLD}  %-4s %-16s %-8s %-9s %-5s %-5s %-22s %-6s %s${NC}\n" \
           "ID" "INTERFACE" "BACKEND" "STATE" "BOOT" "MGR" "ADDRESS" "PORT" "PEERS"
    echo -e "${BOLD}${SEP}${NC}"

    local found=0
    declare -A seen

    # ── 1. Managed instances ──────────────────────────────────────────────────
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue

        local name network port backend
        name="$(env_get    "$env_file" WG_NAME)"
        network="$(env_get "$env_file" WG_SERVER_IP)"
        [[ -z "$network" ]] && network="$(env_get "$env_file" WG_NETWORK)"
        port="$(env_get    "$env_file" WG_PORT)"
        backend="$(env_get "$env_file" WG_BACKEND)"; backend="${backend:-wg}"
        [[ -z "$name" ]] && continue

        seen["$name"]=1
        found=1

        local sys_id state boot peers state_col
        sys_id="$(_iface_id "$name")"; sys_id="${sys_id:--}"
        state="$(_iface_state  "$name")"
        boot="$(_iface_boot    "$name")"
        peers="$(_peers_summary "$name")"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac

        _row "$sys_id" "$name" "$backend" "$state" "$boot" \
             "yes" "${network:--}" "${port:--}" "$peers" \
             "$state_col" "${GREEN}yes${NC}"
    done

    # ── 2. Unmanaged .conf files ──────────────────────────────────────────────
    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        local name
        name="$(basename "$conf_file" .conf)"
        [[ -n "${seen[$name]+_}" ]] && continue
        found=1

        local address port_c state boot state_col sys_id
        address="$(_conf_address "$conf_file")"
        port_c="$(_conf_port     "$conf_file")"
        state="$(_iface_state    "$name")"
        boot="$(_iface_boot      "$name")"
        sys_id="$(_iface_id      "$name")"; sys_id="${sys_id:--}"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac

        _row "$sys_id" "$name" "-" "$state" "$boot" \
             "no" "${address:--}" "${port_c:--}" "-" \
             "$state_col" "${YELLOW}no${NC}"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No WireGuard configs found in ${WG_CONFIG_DIR}.${NC}"
        echo    "  Use 'Servers → Create server' to add one."
    fi

    echo -e "${BOLD}${SEP}${NC}"
    echo -e "  ${CYAN}ID=system iface id  |  PEERS: total/created/active  |  MGR: ${GREEN}yes${NC}${CYAN}=managed ${YELLOW}no${NC}${CYAN}=manual${NC}"
    echo
    pause
}