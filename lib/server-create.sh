#!/usr/bin/env bash
# =============================================================================
# lib/server-create.sh — Interactive WireGuard server creation
# =============================================================================

DEFAULT_MTU=1420

server_create() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Create New WireGuard Server        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Step 1: Interface name ────────────────────────────────────────────────
    echo -e "${CYAN}── Step 1: Interface Name ──${NC}"
    local iface
    iface="$(prompt_iface_name)" || return 1

    # ── Step 2: Network CIDR ─────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 2: Network (CIDR) ──${NC}"
    local cidr conflict

    while true; do
        cidr="$(prompt_cidr)" || return 1

        conflict="$(network_conflicts "$cidr")"
        if [[ $? -eq 0 ]]; then
            warn "Network ${cidr} overlaps with existing config: ${conflict}"
            warn "Choose a different network."
        else
            break
        fi
    done

    # ── Step 3: Server IP (auto) ──────────────────────────────────────────────
    local server_ip
    server_ip="$(network_to_server_ip "$cidr")"
    info "Server address will be: ${BOLD}${server_ip}${NC}"

    # ── Step 4: Listen port ───────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 3: Listen Port ──${NC}"
    local port
    port="$(prompt_port)" || return 1

    # ── Step 5: MTU ───────────────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 4: MTU ──${NC}"
    local mtu err

    while true; do
        read -rp "MTU [${DEFAULT_MTU}]: " mtu
        mtu="${mtu:-$DEFAULT_MTU}"

        err="$(validate_mtu "$mtu")"
        if [[ $? -eq 0 ]]; then
            break
        fi
        warn "$err"
    done

    # ── Step 6: Key directory ─────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 5: Key Directory ──${NC}"
    local default_keydir
    default_keydir="$(key_dir "$iface")"
    local keydir

    read -rp "Key directory [${default_keydir}]: " keydir
    keydir="${keydir:-$default_keydir}"
    keydir="${keydir%/}"   # strip trailing slash

    # ── Step 7: Endpoint ─────────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 6: Endpoint ──${NC}"
    local endpoint
    endpoint="$(prompt_endpoint)" || return 1

    # ── Step 8: PSK mode ─────────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 7: Pre-shared Keys ──${NC}"
    local use_psk
    read -rp "Use unique PSK per client? [Y/n]: " use_psk
    use_psk="${use_psk:-Y}"
    if [[ "${use_psk,,}" == "y" ]]; then
        use_psk="yes"
    else
        use_psk="no"
    fi

    # ── Step 9: Client-to-client ─────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 8: Client-to-Client Traffic ──${NC}"
    local c2c
    read -rp "Allow client-to-client communication by default? [y/N]: " c2c
    c2c="${c2c:-N}"
    if [[ "${c2c,,}" == "y" ]]; then
        c2c="yes"
    else
        c2c="no"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Summary${NC}"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    printf "  %-28s %s\n" "Interface:"          "$iface"
    printf "  %-28s %s\n" "Network:"            "$cidr"
    printf "  %-28s %s\n" "Server address:"     "$server_ip"
    printf "  %-28s %s\n" "Listen port:"        "$port"
    printf "  %-28s %s\n" "MTU:"                "$mtu"
    printf "  %-28s %s\n" "Key directory:"      "$keydir"
    printf "  %-28s %s\n" "Endpoint:"           "$endpoint"
    printf "  %-28s %s\n" "PSK per client:"     "$use_psk"
    printf "  %-28s %s\n" "Client-to-client:"   "$c2c"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo

    read -rp "Proceed with creation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        info "Cancelled."
        return 0
    fi

    # ── Generate keys ─────────────────────────────────────────────────────────
    msg "Creating key directory: ${keydir}"
    mkdir -p "$keydir"
    chmod 700 "$keydir"

    msg "Generating WireGuard keys..."
    local private_key public_key
    private_key="$(wg genkey)"
    public_key="$(echo "$private_key" | wg pubkey)"

    local priv_file="${keydir}/private.key"
    local pub_file="${keydir}/public.key"

    echo "$private_key" > "$priv_file"
    echo "$public_key"  > "$pub_file"

    chmod 600 "$priv_file"
    chmod 644 "$pub_file"
    ok "Keys generated."

    # ── Write .conf ───────────────────────────────────────────────────────────
    local conf_file
    conf_file="$(conf_path "$iface")"

    msg "Writing config: ${conf_file}"
    cat > "$conf_file" <<EOF
# WireGuard server configuration — managed by wg-manager
# Interface: ${iface}
# Created:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# DO NOT EDIT manually if using wg-manager.

[Interface]
PrivateKey = ${private_key}
Address    = ${server_ip}
ListenPort = ${port}
MTU        = ${mtu}

# Peers will be added here by wg-manager (future: client-create)
EOF

    chmod 600 "$conf_file"
    ok "Config written."

    # ── Write .env ────────────────────────────────────────────────────────────
    local env_file
    env_file="$(env_path "$iface")"
    local created_at
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    msg "Writing metadata: ${env_file}"
    cat > "$env_file" <<EOF
# wg-manager metadata — DO NOT EDIT manually
WG_NAME=${iface}
WG_NETWORK=${cidr}
WG_SERVER_IP=${server_ip}
WG_PORT=${port}
WG_MTU=${mtu}
WG_ENDPOINT=${endpoint}
WG_USE_PSK=${use_psk}
WG_CLIENT_TO_CLIENT_DEFAULT=${c2c}
WG_KEY_DIR=${keydir}
WG_PRIVATE_KEY_FILE=${priv_file}
WG_PUBLIC_KEY_FILE=${pub_file}
WG_SERVER_PUBLIC_KEY=${public_key}
WG_CREATED_AT=${created_at}
EOF

    chmod 600 "$env_file"
    ok "Metadata written."

    # ── Enable systemd service ────────────────────────────────────────────────
    msg "Enabling systemd service: wg-quick@${iface}"
    systemctl enable "wg-quick@${iface}" &>/dev/null
    ok "Service enabled (will start on next boot)."

    # ── Offer to start the interface ─────────────────────────────────────────
    echo
    read -rp "Start WireGuard interface now? [Y/n]: " start_now
    start_now="${start_now:-Y}"

    if [[ "${start_now,,}" == "y" ]]; then
        msg "Starting wg-quick@${iface}..."
        if systemctl start "wg-quick@${iface}"; then
            ok "Interface ${iface} is UP."
        else
            warn "Failed to start interface. Check: journalctl -u wg-quick@${iface}"
        fi
    else
        info "You can start it later: systemctl start wg-quick@${iface}"
    fi

    echo
    ok "Server '${iface}' created successfully."
    echo
    info "Public key: ${BOLD}${public_key}${NC}"
    info "Config:     ${conf_file}"
    info "Env:        ${env_file}"
    info "Keys:       ${keydir}/"
    pause
}
