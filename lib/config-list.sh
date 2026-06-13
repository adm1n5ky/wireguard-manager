#!/usr/bin/env bash
# =============================================================================
# lib/config-list.sh — List all WireGuard instances (managed + unmanaged)
# =============================================================================

# --- Interface state helpers -------------------------------------------------

_iface_state() {
    local iface="$1"
    if ip link show "$iface" &>/dev/null 2>&1; then
        if ip link show "$iface" 2>/dev/null | head -1 | grep -q "UP"; then
            echo "UP"
        else
            echo "DOWN"
        fi
    else
        echo "STOPPED"
    fi
}

_iface_boot() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface" 2>/dev/null || echo "wg")"
    if systemctl is-enabled "$(_systemd_unit "$backend" "$iface")" &>/dev/null; then
        echo "YES"
    else
        echo "NO"
    fi
}

_conf_address() {
    local conf="$1"
    grep -m1 "^Address" "$conf" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

_conf_port() {
    local conf="$1"
    grep -m1 "^ListenPort" "$conf" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

# --- Peers summary: total/created/active ------------------------------------
# total   = usable IPs in subnet minus server itself
# created = [Peer] sections in .conf
# active  = peers with handshake in last 180 seconds

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
            local hosts=$(( (1 << (32 - prefix)) - 2 ))
            total=$(( hosts - 1 ))
        fi
    fi

    if [[ -f "$conf_file" ]]; then
        created="$(grep -c '^\[Peer\]' "$conf_file" 2>/dev/null || echo 0)"
    fi

    if backend_is_up "$iface" 2>/dev/null; then
        active="$(backend_show "$iface" 2>/dev/null | \
            grep "latest handshake" | \
            awk -v now="$(date +%s)" '{
                for (i=1;i<=NF;i++) if ($i~/^[0-9]+$/ && $i>1000000) {
                    if (now-$i < 180) c++; break
                }
            } END {print c+0}')"
    fi

    echo "${total}/${created}/${active}"
}

# --- State colour helper -----------------------------------------------------

_state_col() {
    local state="$1"
    case "$state" in
        UP)      echo -e "${GREEN}${state}${NC}" ;;
        DOWN)    echo -e "${YELLOW}${state}${NC}" ;;
        STOPPED) echo -e "${RED}${state}${NC}" ;;
        *)       echo "$state" ;;
    esac
}

# --- Main listing ------------------------------------------------------------

config_list() {
    echo
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}  %-4s %-16s %-8s %-9s %-5s %-4s %-22s %-6s %s${NC}\n" \
           "ID" "INTERFACE" "BACKEND" "STATE" "BOOT" "MGR" "ADDRESS" "PORT" "PEERS"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"

    local found=0
    local idx=0
    declare -A seen

    # ── 1. Managed instances (have .env) ─────────────────────────────────────
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue

        local name network port backend
        name="$(env_get    "$env_file" WG_NAME)"
        network="$(env_get "$env_file" WG_SERVER_IP)"
        [[ -z "$network" ]] && network="$(env_get "$env_file" WG_NETWORK)"
        port="$(env_get    "$env_file" WG_PORT)"
        backend="$(env_get "$env_file" WG_BACKEND)"
        backend="${backend:-wg}"

        [[ -z "$name" ]] && continue
        idx=$(( idx + 1 ))
        seen["$name"]=1
        found=1

        local state boot peers
        state="$(_iface_state "$name")"
        boot="$(_iface_boot   "$name")"
        peers="$(_peers_summary "$name")"

        printf "  %-4s %-16s %-8s %-18s %-5s %-13s %-22s %-6s %s\n" \
               "$idx" \
               "$name" \
               "$backend" \
               "$(_state_col "$state")" \
               "$boot" \
               "$(echo -e "${GREEN}yes${NC}")" \
               "${network:--}" \
               "${port:--}" \
               "$peers"
    done

    # ── 2. Unmanaged .conf files (no matching .env) ───────────────────────────
    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue

        local name
        name="$(basename "$conf_file" .conf)"
        [[ -n "${seen[$name]+_}" ]] && continue
        found=1
        idx=$(( idx + 1 ))

        local address port_c state boot
        address="$(_conf_address "$conf_file")"
        port_c="$(_conf_port    "$conf_file")"
        state="$(_iface_state   "$name")"
        boot="$(_iface_boot     "$name")"

        printf "  %-4s %-16s %-8s %-18s %-5s %-13s %-22s %-6s %s\n" \
               "$idx" \
               "$name" \
               "-" \
               "$(_state_col "$state")" \
               "$boot" \
               "$(echo -e "${YELLOW}no${NC} ")" \
               "${address:--}" \
               "${port_c:--}" \
               "-"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No WireGuard configs found in ${WG_CONFIG_DIR}.${NC}"
        echo    "  Use 'Servers → Create server' to add one."
    fi

    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}PEERS: total/created/active  |  MGR: ${GREEN}yes${NC}${CYAN} = managed  |  ${YELLOW}no${NC}${CYAN} = manual${NC}"
    echo
    pause
}