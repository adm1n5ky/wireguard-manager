#!/usr/bin/env bash
# =============================================================================
# lib/status.sh — Interface status, up/down management
# =============================================================================

_pick_instance() {
    local prompt="${1:-Select instance}"

    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed WireGuard instances found."
        return 1
    fi

    local i
    for i in "${!instances[@]}"; do
        local name="${instances[$i]}"
        local state backend
        state="$(_iface_state "$name")"
        backend="$(backend_for_iface "$name")"
        printf "  %d) %-15s [%s] (%s)\n" $(( i + 1 )) "$name" "$state" "$backend"
    done
    echo "  0) Cancel"
    echo

    local choice
    while true; do
        read -rp "${prompt}: " choice
        if [[ "$choice" == "0" ]]; then
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#instances[@]} )); then
            echo "${instances[$(( choice - 1 ))]}"
            return 0
        fi
        warn "Invalid selection."
    done
}

server_status() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Interface Status                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface")" || { pause; return 0; }

    local backend
    backend="$(backend_for_iface "$iface")"

    echo
    echo -e "${BOLD}── ip link ──────────────────────────────${NC}"
    ip link show "$iface" 2>/dev/null || warn "Interface not found in kernel."

    echo
    echo -e "${BOLD}── ${backend} show ─────────────────────────────${NC}"
    if backend_is_up "$iface"; then
        backend_show "$iface" 2>/dev/null || warn "${backend} show failed."
    else
        warn "Interface '${iface}' is not up — nothing to show."
    fi

    echo
    echo -e "${BOLD}── Metadata (.env) ──────────────────────${NC}"
    local env_file
    env_file="$(env_path "$iface")"
    if [[ -f "$env_file" ]]; then
        grep -v "PRIVATE_KEY" "$env_file" | grep -v "^#" | grep -v "^$" | \
            sed 's/^/  /'
    else
        warn "No .env file found for ${iface}."
    fi

    pause
}

server_up() {
    echo
    echo -e "${CYAN}── Start Interface ──${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface to start")" || { pause; return 0; }

    if backend_is_up "$iface"; then
        local state
        state="$(_iface_state "$iface")"
        if [[ "$state" == "UP" ]]; then
            warn "Interface '${iface}' is already UP."
            pause
            return 0
        fi
    fi

    local backend unit
    backend="$(backend_for_iface "$iface")"
    unit="$(_systemd_unit "$backend" "$iface")"

    msg "Starting ${unit}..."
    if backend_start "$iface"; then
        ok "Interface '${iface}' is now UP."
    else
        warn "Failed to start. Check: journalctl -u ${unit} -n 30"
    fi

    pause
}

server_down() {
    echo
    echo -e "${CYAN}── Stop Interface ──${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface to stop")" || { pause; return 0; }

    if ! backend_is_up "$iface"; then
        warn "Interface '${iface}' is already down."
        pause
        return 0
    fi

    local backend unit
    backend="$(backend_for_iface "$iface")"
    unit="$(_systemd_unit "$backend" "$iface")"

    msg "Stopping ${unit}..."
    if backend_stop "$iface"; then
        ok "Interface '${iface}' is now DOWN."
    else
        warn "Failed to stop. Check: journalctl -u ${unit} -n 30"
    fi

    pause
}