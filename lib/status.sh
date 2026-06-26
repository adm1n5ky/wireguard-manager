#!/usr/bin/env bash
# =============================================================================
# lib/status.sh — Interface up/down management
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
        local state backend
        state="$(_iface_state "$name")"
        backend="$(backend_for_iface "$name")"
        printf "  %d) %-15s [%s] (%s)\n" $(( i + 1 )) "$name" "$state" "$backend"
    done
    echo "  0) Cancel"
    echo

    local choice
    while true; do
        read -rep "${prompt}: " choice
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

# --- Bring interface UP -------------------------------------------------------

server_up() {
    echo
    echo -e "${CYAN}── Start Interface ──${NC}"
    echo

    local iface
    iface="$(_pick_instance "Select interface to start")" || { pause; return 0; }

    local state
    state="$(_iface_state "$iface")"
    if [[ "$state" == "UP" ]]; then
        warn "Interface '${iface}' is already UP."
        pause
        return 0
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

# --- Bring interface DOWN -----------------------------------------------------

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
# --- Show interface status ---------------------------------------------------

server_status() {
    echo
    echo -e "${CYAN}── Interface Status ──${NC}"
    echo

    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed WireGuard instances found."
        pause
        return 0
    fi

    local iface
    iface="$(_pick_instance "Select interface")" || { pause; return 0; }

    local backend
    backend="$(backend_for_iface "$iface")"
    local bin
    bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"
    local unit
    unit="$(_systemd_unit "$backend" "$iface")"

    echo
    echo -e "${BOLD}  Interface:  ${NC}${iface}"
    echo -e "${BOLD}  Backend:    ${NC}${backend}"
    echo -e "${BOLD}  Unit:       ${NC}${unit}"

    local state
    state="$(_iface_state "$iface")"
    case "$state" in
        UP)      echo -e "${BOLD}  State:      ${GREEN}UP${NC}" ;;
        DOWN)    echo -e "${BOLD}  State:      ${YELLOW}DOWN${NC}" ;;
        STOPPED) echo -e "${BOLD}  State:      ${RED}STOPPED${NC}" ;;
    esac

    local boot
    boot="$(_iface_boot "$iface")"
    echo -e "${BOLD}  Boot:       ${NC}${boot}"

    if backend_is_up "$iface" 2>/dev/null; then
        echo
        echo -e "${BOLD}  WireGuard show:${NC}"
        echo "  ─────────────────────────────────────────"
        "$bin" show "$iface" 2>/dev/null | sed 's/^/  /' || true
    fi

    echo
    echo -e "${BOLD}  systemctl status:${NC}"
    echo "  ─────────────────────────────────────────"
    systemctl status "$unit" --no-pager -l 2>/dev/null | head -20 | sed 's/^/  /' || true

    pause
}