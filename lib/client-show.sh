#!/usr/bin/env bash
# =============================================================================
# lib/client-show.sh — Show client config and QR code
# =============================================================================

client_show_for() {
    local iface="$1"
    _client_show_on "$iface"
}

_client_show_on() {
    local iface="$1"
    local conf_file
    conf_file="$(conf_path "$iface")"

    if [[ ! -f "$conf_file" ]] || ! grep -q '^\[Peer\]' "$conf_file" 2>/dev/null; then
        warn "No clients on '${iface}'."
        pause
        return 0
    fi

    # ── Build client list ─────────────────────────────────────────────────────
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

    if [[ ${#client_names[@]} -eq 0 ]]; then
        warn "No clients found on '${iface}'."
        pause
        return 0
    fi

    # ── Pick client ───────────────────────────────────────────────────────────
    echo
    echo "Clients on '${iface}':"
    local i
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
        read -rp "Select client: " cchoice
        [[ "$cchoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$cchoice" =~ ^[0-9]+$ ]] && (( cchoice >= 1 && cchoice <= ${#client_names[@]} )); then
            break
        fi
        warn "Invalid selection."
    done

    local sel_idx=$(( cchoice - 1 ))
    local sel_name="${client_names[$sel_idx]}"
    local sel_ip="${client_ips[$sel_idx]}"
    local sel_pubkey="${client_pubkeys[$sel_idx]}"

    # ── Locate client config file ─────────────────────────────────────────────
    local env_file keydir
    env_file="$(env_path "$iface")"
    keydir="$(env_get "$env_file" WG_KEY_DIR)"
    local c_conf_file="${keydir}/clients/${sel_name}/${iface}-${sel_name}.conf"

    if [[ ! -f "$c_conf_file" ]]; then
        warn "Client config file not found: ${c_conf_file}"
        pause
        return 0
    fi

    # ── Live handshake info (if interface is up) ──────────────────────────────
    local handshake_info=""
    if backend_is_up "$iface" 2>/dev/null; then
        local backend bin
        backend="$(backend_for_iface "$iface")"
        bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"
        local ts
        ts="$("$bin" show "$iface" latest-handshakes 2>/dev/null \
              | awk -v key="$sel_pubkey" '$1==key {print $2}')"
        if [[ -n "$ts" && "$ts" != "0" ]]; then
            local now elapsed
            now="$(date +%s)"
            elapsed=$(( now - ts ))
            if (( elapsed < 60 )); then
                handshake_info="${elapsed}s ago"
            elif (( elapsed < 3600 )); then
                handshake_info="$(( elapsed / 60 ))m ago"
            else
                handshake_info="$(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m ago"
            fi
        else
            handshake_info="never"
        fi
    fi

    # ── Print header ──────────────────────────────────────────────────────────
    echo
    echo -e "${BOLD}┌─────────────────────────────────────────┐${NC}"
    printf "${BOLD}│  %-41s│${NC}\n" "Client: ${sel_name}"
    printf "${BOLD}│  %-41s│${NC}\n" "Server: ${iface}   IP: ${sel_ip}"
    [[ -n "$handshake_info" ]] && \
        printf "${BOLD}│  %-41s│${NC}\n" "Last handshake: ${handshake_info}"
    echo -e "${BOLD}└─────────────────────────────────────────┘${NC}"
    echo

    # ── Print config (copy-friendly, no ANSI inside) ──────────────────────────
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$c_conf_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # ── QR code ───────────────────────────────────────────────────────────────
    echo
    if command -v qrencode &>/dev/null; then
        info "QR code (scan with WireGuard app):"
        echo
        # -l L  : error correction Low  — max data capacity for long configs
        # -s 1  : 1 terminal cell per module — compact, readable on 80-col term
        # -t ansiutf8 : colour UTF-8 blocks, best terminal rendering
        qrencode -l L -s 1 -t ansiutf8 < "$c_conf_file"
        echo
    else
        warn "qrencode not installed. To enable QR codes:"
        echo "      apt install qrencode"
    fi

    pause
}