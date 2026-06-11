#!/usr/bin/env bash
# =============================================================================
# lib/status.sh — Detailed interface status, wg show, up/down management
# =============================================================================

# --- Pick an instance interactively ------------------------------------------

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
        local state
        state="$(_iface_state "$name")"
        printf "  %d) %-15s [%s]\n" $(( i + 1 )) "$name" "$state"
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

# --- Detailed status ---------------------------------------------------------

server_status() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Interface Status                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface")" || { pause; return 0; }

    echo
    echo -e "${BOLD}── ip link ──────────────────────────────${NC}"
    ip link show "$iface" 2>/dev/null || warn "Interface not found in kernel."

    echo
    echo -e "${BOLD}── wg show ──────────────────────────────${NC}"
    if ip link show "$iface" &>/dev/null; then
        wg show "$iface" 2>/dev/null || warn "wg show failed (interface may be down)."
    else
        warn "Interface '${iface}' is not up — nothing to show from wg."
    fi

    echo
    echo -e "${BOLD}── Metadata (.env) ──────────────────────${NC}"
    local env_file
    env_file="$(env_path "$iface")"
    if [[ -f "$env_file" ]]; then
        # Print key fields only (not private key)
        grep -v "PRIVATE_KEY" "$env_file" | grep -v "^#" | grep -v "^$" | \
            sed 's/^/  /'
    else
        warn "No .env file found for ${iface}."
    fi

    pause
}

# --- Bring interface UP -------------------------------------------------------

server_up() {
    echo
    echo -e "${CYAN}── Start WireGuard Interface ──${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface to start")" || { pause; return 0; }

    if ip link show "$iface" &>/dev/null; then
        local state
        state="$(_iface_state "$iface")"
        if [[ "$state" == "UP" ]]; then
            warn "Interface '${iface}' is already UP."
            pause
            return 0
        fi
    fi

    msg "Starting wg-quick@${iface}..."
    if systemctl start "wg-quick@${iface}"; then
        ok "Interface '${iface}' is now UP."
    else
        warn "Failed to start. Check: journalctl -u wg-quick@${iface} -n 30"
    fi

    pause
}

# --- Bring interface DOWN -----------------------------------------------------

server_down() {
    echo
    echo -e "${CYAN}── Stop WireGuard Interface ──${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface to stop")" || { pause; return 0; }

    if ! ip link show "$iface" &>/dev/null; then
        warn "Interface '${iface}' is already down."
        pause
        return 0
    fi

    msg "Stopping wg-quick@${iface}..."
    if systemctl stop "wg-quick@${iface}"; then
        ok "Interface '${iface}' is now DOWN."
    else
        warn "Failed to stop. Check: journalctl -u wg-quick@${iface} -n 30"
    fi

    pause
}
