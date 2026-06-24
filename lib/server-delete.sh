#!/usr/bin/env bash
# =============================================================================
# lib/server-delete.sh — Safe WireGuard / AmneziaWG server removal
# =============================================================================

server_delete() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Delete Server                      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

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
        local state backend
        state="$(_iface_state "$name")"
        backend="$(backend_for_iface "$name")"
        printf "  %d) %-15s [%s] (%s)\n" $(( i + 1 )) "$name" "$state" "$backend"
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

    local env_file conf_file
    env_file="$(env_path "$iface")"
    conf_file="$(conf_path "$iface")"

    local keydir backend
    keydir="$(env_get   "$env_file" WG_KEY_DIR)"
    backend="$(env_get  "$env_file" WG_BACKEND)"
    backend="${backend:-wg}"

    local peer_count=0
    if [[ -f "$conf_file" ]]; then
        peer_count="$(grep -c '^\[Peer\]' "$conf_file" 2>/dev/null || echo 0)"
    fi

    echo
    echo -e "${RED}  !! This will permanently delete: !!${NC}"
    echo "     Config:    ${conf_file}"
    echo "     Env file:  ${env_file}"
    [[ -n "$keydir" ]] && echo "     Keys dir:  ${keydir}/"
    if (( peer_count > 0 )); then
        echo -e "     ${RED}Peers:     ${peer_count} client config(s) will be lost!${NC}"
    fi
    echo

    read -rp "Type the interface name to confirm deletion (${iface}): " confirm_name
    if [[ "$confirm_name" != "$iface" ]]; then
        warn "Name does not match. Deletion cancelled."
        pause
        return 0
    fi

    if backend_is_up "$iface"; then
        msg "Stopping interface ${iface}..."
        backend_stop "$iface" 2>/dev/null || \
            backend_down "$iface" 2>/dev/null || \
            warn "Could not stop interface gracefully (may already be down)."
    fi

    if backend_is_enabled "$iface"; then
        msg "Disabling systemd service..."
        backend_disable "$iface"
        ok "Service disabled."
    fi

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