#!/usr/bin/env bash
# =============================================================================
# lib/config-list.sh — List all WireGuard instances (managed + unmanaged)
# =============================================================================

_iface_state() {
    local iface="$1"
    if ip link show "$iface" &>/dev/null 2>&1; then
        ip link show "$iface" 2>/dev/null | head -1 | grep -q "UP" \
            && echo "UP" || echo "DOWN"
    else
        echo "STOPPED"
    fi
}

_iface_boot() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface" 2>/dev/null || echo "wg")"
    systemctl is-enabled "$(_systemd_unit "$backend" "$iface")" &>/dev/null \
        && echo "YES" || echo "NO"
}

_iface_id() {
    local iface="$1"
    local id
    id="$(ip link show "$iface" 2>/dev/null | awk -F': ' 'NR==1{print $1}' | tr -d ' ')"
    echo "${id:--}"
}

_conf_address() { grep -m1 "^Address"    "$1" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '; }
_conf_port()    { grep -m1 "^ListenPort" "$1" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '; }

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

_state_colour() {
    case "$1" in
        UP)      echo "${GREEN}${1}${NC}" ;;
        DOWN)    echo "${YELLOW}${1}${NC}" ;;
        STOPPED) echo "${RED}${1}${NC}" ;;
        *)       echo "$1" ;;
    esac
}

# --- Main listing (with pause) -----------------------------------------------

config_list() {
    echo
    table_header
    _table_rows
    table_footer
    pause
}

# --- Compact listing for menus (no pause) ------------------------------------

config_list_inline() {
    echo
    table_header
    _table_rows
    table_footer
}

# --- Shared row rendering ----------------------------------------------------

_table_rows() {
    local found=0
    declare -A seen

    # Managed instances (.env present)
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue
        local name network port backend
        name="$(env_get    "$env_file" WG_NAME)"
        network="$(env_get "$env_file" WG_SERVER_IP)"
        [[ -z "$network" ]] && network="$(env_get "$env_file" WG_NETWORK)"
        port="$(env_get    "$env_file" WG_PORT)"
        backend="$(env_get "$env_file" WG_BACKEND)"; backend="${backend:-wg}"
        [[ -z "$name" ]] && continue
        seen["$name"]=1; found=1

        local sys_id state boot peers
        sys_id="$(_iface_id     "$name")"
        state="$(_iface_state   "$name")"
        boot="$(_iface_boot     "$name")"
        peers="$(_peers_summary "$name")"

        table_row "$sys_id" "$name" "$backend" "$state" "$boot" \
                  "yes" "${network:--}" "${port:--}" "$peers" \
                  "$(_state_colour "$state")" "${GREEN}yes${NC}"
    done

    # Unmanaged .conf files (no .env)
    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        local name; name="$(basename "$conf_file" .conf)"
        [[ -n "${seen[$name]+_}" ]] && continue
        found=1

        local address port_c state boot sys_id
        address="$(_conf_address "$conf_file")"
        port_c="$(_conf_port     "$conf_file")"
        state="$(_iface_state    "$name")"
        boot="$(_iface_boot      "$name")"
        sys_id="$(_iface_id      "$name")"

        local backend_u
        backend_u="$(backend_for_iface "$name" 2>/dev/null || echo "wg")"

        table_row "$sys_id" "$name" "$backend_u" "$state" "$boot" \
                  "no" "${address:--}" "${port_c:--}" "-" \
                  "$(_state_colour "$state")" "${YELLOW}no${NC}"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No WireGuard configs found in ${WG_CONFIG_DIR}.${NC}"
        echo    "  Use 'Servers → Create server' to add one."
    fi
}