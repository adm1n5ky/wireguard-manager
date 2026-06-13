#!/usr/bin/env bash
# =============================================================================
# lib/client-delete.sh — Remove a peer from an existing WireGuard server
# =============================================================================

client_delete() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Delete Client                      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Pick server ───────────────────────────────────────────────────────────
    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed servers found."
        pause
        return 0
    fi

    echo "Select server:"
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

    local schoice iface
    while true; do
        read -rp "Server: " schoice
        [[ "$schoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$schoice" =~ ^[0-9]+$ ]] && (( schoice >= 1 && schoice <= ${#instances[@]} )); then
            iface="${instances[$(( schoice - 1 ))]}"
            break
        fi
        warn "Invalid selection."
    done

    # ── List clients on this server ───────────────────────────────────────────
    local conf_file
    conf_file="$(conf_path "$iface")"

    if [[ ! -f "$conf_file" ]]; then
        warn "Config file not found: ${conf_file}"
        pause
        return 0
    fi

    # Parse peers: collect name, pubkey, ip
    local -a client_names client_pubkeys client_ips
    local cur_name="" cur_pubkey="" cur_ip=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then
            # Save previous peer if complete
            if [[ -n "$cur_pubkey" ]]; then
                client_names+=("${cur_name:-unnamed}")
                client_pubkeys+=("$cur_pubkey")
                client_ips+=("${cur_ip:--}")
            fi
            cur_name=""; cur_pubkey=""; cur_ip=""
        elif [[ "$line" =~ ^#[[:space:]]Name[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_pubkey="${BASH_REMATCH[1]// /}"
        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_ip="${BASH_REMATCH[1]%%/*}"
            cur_ip="${cur_ip// /}"
        fi
    done < "$conf_file"

    # Last peer
    if [[ -n "$cur_pubkey" ]]; then
        client_names+=("${cur_name:-unnamed}")
        client_pubkeys+=("$cur_pubkey")
        client_ips+=("${cur_ip:--}")
    fi

    if [[ ${#client_names[@]} -eq 0 ]]; then
        warn "No clients found on '${iface}'."
        pause
        return 0
    fi

    echo
    echo "Clients on '${iface}':"
    for i in "${!client_names[@]}"; do
        printf "  %d) %-20s  IP: %-16s  Key: %.16s…\n" \
               $(( i + 1 )) \
               "${client_names[$i]}" \
               "${client_ips[$i]}" \
               "${client_pubkeys[$i]}"
    done
    echo "  0) Cancel"
    echo

    local cchoice
    while true; do
        read -rp "Select client to delete: " cchoice
        [[ "$cchoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$cchoice" =~ ^[0-9]+$ ]] && (( cchoice >= 1 && cchoice <= ${#client_names[@]} )); then
            break
        fi
        warn "Invalid selection."
    done

    local del_idx=$(( cchoice - 1 ))
    local del_name="${client_names[$del_idx]}"
    local del_pubkey="${client_pubkeys[$del_idx]}"
    local del_ip="${client_ips[$del_idx]}"

    # ── Confirm ───────────────────────────────────────────────────────────────
    echo
    echo -e "${RED}  !! This will permanently remove: !!${NC}"
    echo "     Client:    ${del_name}"
    echo "     IP:        ${del_ip}"
    echo "     PublicKey: ${del_pubkey:0:24}…"
    echo

    local env_file keydir
    env_file="$(env_path "$iface")"
    keydir="$(env_get "$env_file" WG_KEY_DIR)"
    local client_dir="${keydir}/clients/${del_name}"

    [[ -d "$client_dir" ]] && echo "     Files:     ${client_dir}/"
    echo

    read -rp "Type client name to confirm (${del_name}): " confirm_name
    if [[ "$confirm_name" != "$del_name" ]]; then
        warn "Name does not match. Deletion cancelled."
        pause
        return 0
    fi

    # ── Remove peer from server .conf ─────────────────────────────────────────
    msg "Removing peer from server config..."
    _remove_peer_from_conf "$conf_file" "$del_pubkey"
    ok "Peer removed from ${conf_file}."

    # ── Release IP back to pool ───────────────────────────────────────────────
    if [[ "$del_ip" != "-" ]]; then
        pool_release "$iface" "$del_ip" 2>/dev/null && \
            info "IP ${del_ip} returned to pool."
    fi

    # ── Remove client files ───────────────────────────────────────────────────
    if [[ -d "$client_dir" ]]; then
        read -rp "Delete client files (${client_dir}/)? [Y/n]: " del_files
        del_files="${del_files:-Y}"
        if [[ "${del_files,,}" == "y" ]]; then
            rm -rf "$client_dir"
            ok "Removed: ${client_dir}/"
        fi
    fi

    # ── Hot-reload if interface is up ─────────────────────────────────────────
    local backend
    backend="$(backend_for_iface "$iface")"
    if backend_is_up "$iface"; then
        msg "Removing peer live (wg set)..."
        local bin
        bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"
        if "$bin" set "$iface" peer "$del_pubkey" remove 2>/dev/null; then
            ok "Peer removed from live interface."
        else
            warn "Could not remove peer live. Restart to apply: systemctl restart $(_systemd_unit "$backend" "$iface")"
        fi
    else
        info "Interface is down — changes apply on next start."
    fi

    echo
    ok "Client '${del_name}' deleted from '${iface}'."
    pause
}

# --- Remove a [Peer] block by public key from a .conf file -------------------
# Removes the comment block (# Name, # Created) immediately before [Peer] too.

_remove_peer_from_conf() {
    local conf_file="$1"
    local pubkey="$2"

    local tmpfile
    tmpfile="$(mktemp)"

    local skip=0
    local -a buffer=()

    while IFS= read -r line; do
        # Accumulate comment lines that precede a [Peer]
        if [[ "$line" =~ ^#  || -z "$line" ]]; then
            buffer+=("$line")
            continue
        fi

        if [[ "$line" =~ ^\[Peer\] ]]; then
            # Peek ahead: is this our target peer?
            # We'll decide when we hit PublicKey
            buffer+=("$line")
            skip=0
            continue
        fi

        if [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]// /}"
            if [[ "$key" == "$pubkey" ]]; then
                skip=1
                buffer=()   # discard buffered comments + [Peer] header
                continue
            else
                # Flush buffer — this peer stays
                for buffered in "${buffer[@]}"; do
                    echo "$buffered" >> "$tmpfile"
                done
                buffer=()
                echo "$line" >> "$tmpfile"
                continue
            fi
        fi

        if (( skip == 1 )); then
            # Skip all lines belonging to this peer until next blank or section
            if [[ "$line" =~ ^\[ ]]; then
                skip=0
                # This is a new section — flush and keep
                for buffered in "${buffer[@]}"; do
                    echo "$buffered" >> "$tmpfile"
                done
                buffer=()
                echo "$line" >> "$tmpfile"
            fi
            # else: skip the line
            continue
        fi

        # Flush any buffered lines, then write current line
        for buffered in "${buffer[@]}"; do
            echo "$buffered" >> "$tmpfile"
        done
        buffer=()
        echo "$line" >> "$tmpfile"

    done < "$conf_file"

    # Flush remaining buffer (only if not skipping)
    if (( skip == 0 )); then
        for buffered in "${buffer[@]}"; do
            echo "$buffered" >> "$tmpfile"
        done
    fi

    mv "$tmpfile" "$conf_file"
    chmod 600 "$conf_file"
}

# --- Wrapper called from menu with pre-selected server ----------------------

client_delete_for() {
    local iface="$1"
    # Inject iface directly — reuse main logic skipping server selection
    _client_delete_on "$iface"
}

_client_delete_on() {
    local iface="$1"
    local conf_file
    conf_file="$(conf_path "$iface")"

    if [[ ! -f "$conf_file" ]] || ! grep -q '^\[Peer\]' "$conf_file" 2>/dev/null; then
        warn "No clients on '${iface}'."
        pause
        return 0
    fi

    local -a client_names client_pubkeys client_ips
    local cur_name="" cur_pubkey="" cur_ip=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then
            if [[ -n "$cur_pubkey" ]]; then
                client_names+=("${cur_name:-unnamed}")
                client_pubkeys+=("$cur_pubkey")
                client_ips+=("${cur_ip:--}")
            fi
            cur_name=""; cur_pubkey=""; cur_ip=""
        elif [[ "$line" =~ ^#[[:space:]]Name[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_pubkey="${BASH_REMATCH[1]// /}"
        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_ip="${BASH_REMATCH[1]%%/*}"; cur_ip="${cur_ip// /}"
        fi
    done < "$conf_file"
    [[ -n "$cur_pubkey" ]] && {
        client_names+=("${cur_name:-unnamed}")
        client_pubkeys+=("$cur_pubkey")
        client_ips+=("${cur_ip:--}")
    }

    echo
    echo "Clients on '${iface}':"
    local i
    for i in "${!client_names[@]}"; do
        printf "  %d) %-20s  IP: %-16s  Key: %.16s…\n" \
               $(( i + 1 )) "${client_names[$i]}" "${client_ips[$i]}" "${client_pubkeys[$i]}"
    done
    echo "  0) Cancel"
    echo

    local cchoice
    while true; do
        read -rp "Select client to delete: " cchoice
        [[ "$cchoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$cchoice" =~ ^[0-9]+$ ]] && (( cchoice >= 1 && cchoice <= ${#client_names[@]} )); then
            break
        fi
        warn "Invalid selection."
    done

    local del_idx=$(( cchoice - 1 ))
    local del_name="${client_names[$del_idx]}"
    local del_pubkey="${client_pubkeys[$del_idx]}"
    local del_ip="${client_ips[$del_idx]}"

    echo
    echo -e "${RED}  !! Removing: ${del_name} (${del_ip}) !!${NC}"
    read -rp "Type client name to confirm (${del_name}): " confirm_name
    [[ "$confirm_name" != "$del_name" ]] && { warn "Name mismatch. Cancelled."; pause; return 0; }

    _remove_peer_from_conf "$conf_file" "$del_pubkey"
    ok "Peer removed from ${conf_file}."

    [[ "$del_ip" != "-" ]] && pool_release "$iface" "$del_ip" 2>/dev/null

    local env_file keydir
    env_file="$(env_path "$iface")"
    keydir="$(env_get "$env_file" WG_KEY_DIR)"
    local client_dir="${keydir}/clients/${del_name}"
    if [[ -d "$client_dir" ]]; then
        read -rp "Delete client files (${client_dir}/)? [Y/n]: " df_ans; df_ans="${df_ans:-Y}"
        [[ "${df_ans,,}" == "y" ]] && { rm -rf "$client_dir"; ok "Removed: ${client_dir}/"; }
    fi

    local backend; backend="$(backend_for_iface "$iface")"
    local bin; bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"
    if backend_is_up "$iface"; then
        "$bin" set "$iface" peer "$del_pubkey" remove 2>/dev/null && \
            ok "Peer removed from live interface." || \
            warn "Live removal failed — restart to apply."
    fi

    echo
    ok "Client '${del_name}' deleted from '${iface}'."
    pause
}