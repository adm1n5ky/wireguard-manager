#!/usr/bin/env bash
# =============================================================================
# lib/server-delete.sh — Safe WireGuard server removal
# IMPORTANT: Never `source` .env — all values parsed via grep/env_get
# =============================================================================

server_delete() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Delete WireGuard Server            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # List available instances
    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed WireGuard instances found."
        pause
        return 0
    fi

    echo "Available instances:"
    local i
    for i in "${!instances[@]}"; do
        local name="${instances[$i]}"
        local state
        state="$(_iface_state "$name")"
        printf "  %d) %-15s [%s]\n" $(( i + 1 )) "$name" "$state"
    done
    echo "  0) Cancel"
    echo

    local choice iface
    while true; do
        read -rp "Select instance to delete: " choice
        if [[ "$choice" == "0" ]]; then
            info "Cancelled."
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#instances[@]} )); then
            iface="${instances[$(( choice - 1 ))]}"
            break
        fi
        warn "Invalid selection."
    done

    # ── Confirm ───────────────────────────────────────────────────────────────
    local env_file conf_file
    env_file="$(env_path "$iface")"
    conf_file="$(conf_path "$iface")"

    # Read paths from .env SAFELY (no source)
    local keydir
    keydir="$(env_get "$env_file" WG_KEY_DIR)"

    echo
    echo -e "${RED}  !! This will permanently delete: !!${NC}"
    echo "     Config:    ${conf_file}"
    echo "     Env file:  ${env_file}"
    [[ -n "$keydir" ]] && echo "     Keys dir:  ${keydir}/"
    echo

    read -rp "Type the interface name to confirm deletion (${iface}): " confirm_name
    if [[ "$confirm_name" != "$iface" ]]; then
        warn "Name does not match. Deletion cancelled."
        pause
        return 0
    fi

    # ── Stop interface ────────────────────────────────────────────────────────
    if ip link show "$iface" &>/dev/null; then
        msg "Stopping interface ${iface}..."
        systemctl stop "wg-quick@${iface}" 2>/dev/null || \
            wg-quick down "$iface" 2>/dev/null || \
            warn "Could not stop interface gracefully (it may already be down)."
    fi

    # ── Disable systemd ───────────────────────────────────────────────────────
    if systemctl is-enabled "wg-quick@${iface}" &>/dev/null; then
        msg "Disabling systemd service..."
        systemctl disable "wg-quick@${iface}" &>/dev/null
        ok "Service disabled."
    fi

    # ── Remove files ─────────────────────────────────────────────────────────

    if [[ -f "$conf_file" ]]; then
        rm -f "$conf_file"
        ok "Removed: ${conf_file}"
    fi

    if [[ -f "$env_file" ]]; then
        rm -f "$env_file"
        ok "Removed: ${env_file}"
    fi

    if [[ -n "$keydir" && -d "$keydir" ]]; then
        rm -rf "$keydir"
        ok "Removed: ${keydir}/"
    fi

    echo
    ok "Instance '${iface}' deleted."
    pause
}
