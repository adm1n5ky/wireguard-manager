#!/usr/bin/env bash
# =============================================================================
# lib/client-create.sh — Add a new peer to an existing WireGuard server
# =============================================================================
# --- Generate SVG QR code for client config ----------------------------------

_generate_qr_svg() {
    local c_conf_file="$1"
    local svg_file="${c_conf_file%.conf}.svg"
    if command -v qrencode &>/dev/null; then
        qrencode -l L -t SVG -o "$svg_file" < "$c_conf_file" 2>/dev/null &&             chmod 600 "$svg_file" &&             echo "$svg_file"
    fi
}

client_create() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Add Client                         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Pick server ───────────────────────────────────────────────────────────
    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed servers found. Create a server first."
        pause
        return 0
    fi

    echo "Select server:"
    local i
    for i in "${!instances[@]}"; do
        local name="${instances[$i]}"
        local state backend stats
        state="$(_iface_state "$name")"
        backend="$(backend_for_iface "$name")"
        stats="$(pool_stats "$name")"
        printf "  %d) %-15s [%s] (%s)  pool: %s\n" \
               $(( i + 1 )) "$name" "$state" "$backend" "$stats"
    done
    echo "  0) Cancel"
    echo

    local schoice iface
    while true; do
        read -rep "Server: " schoice
        [[ "$schoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$schoice" =~ ^[0-9]+$ ]] && (( schoice >= 1 && schoice <= ${#instances[@]} )); then
            iface="${instances[$(( schoice - 1 ))]}"
            break
        fi
        warn "Invalid selection."
    done

    local env_file conf_file
    env_file="$(env_path  "$iface")"
    conf_file="$(conf_path "$iface")"

    local backend endpoint use_psk
    backend="$(env_get    "$env_file" WG_BACKEND)"
    backend="${backend:-wg}"
    endpoint="$(env_get   "$env_file" WG_ENDPOINT)"
    local server_port
    server_port="$(env_get "$env_file" WG_PORT)"
    use_psk="$(env_get    "$env_file" WG_USE_PSK)"
    local server_pubkey mtu
    server_pubkey="$(env_get "$env_file" WG_SERVER_PUBLIC_KEY)"
    mtu="$(env_get "$env_file" WG_MTU)"
    mtu="${mtu:-1420}"

    # ── Step 1: Client name ───────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 1: Client Name ──${NC}"
    local client_name
    while true; do
        read -rep "Client name (e.g. phone-alice): " client_name
        client_name="${client_name// /_}"
        client_name="${client_name//[^a-zA-Z0-9_-]/}"

        if [[ -z "$client_name" ]]; then
            warn "Name cannot be empty."
            continue
        fi
        if (( ${#client_name} > 32 )); then
            warn "Name too long (max 32 chars)."
            continue
        fi
        if _client_exists "$iface" "$client_name"; then
            warn "Client '${client_name}' already exists on ${iface}."
            continue
        fi
        break
    done

    # ── Step 2: DNS ───────────────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 2: DNS ──${NC}"
    local dns
    read -rep "DNS servers [1.1.1.1, 1.0.0.1]: " dns
    dns="${dns:-1.1.1.1, 1.0.0.1}"

    # ── Step 3: Allowed IPs (split tunnel vs full tunnel) ─────────────────────
    echo
    echo -e "${CYAN}── Step 3: Routing ──${NC}"
    echo "  1) Full tunnel      (0.0.0.0/0 — all traffic via VPN)"
    echo "  2) Split tunnel     (VPN subnet only)"
    echo "  3) Custom"
    echo
    local allowed_ips rchoice
    read -rep "Routing [1]: " rchoice
    rchoice="${rchoice:-1}"

    local server_network
    server_network="$(env_get "$env_file" WG_NETWORK)"

    case "$rchoice" in
        1) allowed_ips="0.0.0.0/0, ::/0" ;;
        2) allowed_ips="${server_network}" ;;
        3)
            read -rep "AllowedIPs: " allowed_ips
            if [[ -z "$allowed_ips" ]]; then
                warn "Empty input, using full tunnel."
                allowed_ips="0.0.0.0/0, ::/0"
            fi
            ;;
        *) allowed_ips="0.0.0.0/0, ::/0" ;;
    esac

    # ── Step 4: Output directory ──────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 5: Output ──${NC}"
    local keydir
    keydir="$(env_get "$env_file" WG_KEY_DIR)"
    local client_dir="${keydir}/clients/${client_name}"

    read -rep "Client config directory [${client_dir}]: " client_dir_in
    client_dir="${client_dir_in:-$client_dir}"
    client_dir="${client_dir%/}"

    # ── Allocate IP ───────────────────────────────────────────────────────────
    info "Allocating IP from pool..."

    local pool_file
    pool_file="$(_pool_file "$iface")"
    if [[ ! -f "$pool_file" ]]; then
        pool_init "$iface" || { warn "Failed to init IP pool."; pause; return 1; }
    fi

    local client_ip
    client_ip="$(pool_allocate "$iface" "$client_name")" || {
        warn "No free IPs available."
        pause
        return 1
    }
    info "Allocated: ${BOLD}${client_ip}${NC}"

    local prefix
    prefix="${server_network#*/}"
    local client_addr="${client_ip}/${prefix}"

    # ── Generate client keys ──────────────────────────────────────────────────
    msg "Generating client keys (backend: ${backend})..."
    local client_priv client_pub
    client_priv="$(backend_genkey "$backend")"
    client_pub="$(echo "$client_priv" | backend_pubkey "$backend")"

    local psk=""
    if [[ "$use_psk" == "yes" ]]; then
        psk="$(backend_genpsk "$backend")"
    fi

    # ── Write client key files ────────────────────────────────────────────────
    mkdir -p "$client_dir"
    chmod 700 "$client_dir"

    local c_priv_file="${client_dir}/private.key"
    local c_pub_file="${client_dir}/public.key"
    local c_conf_file="${client_dir}/${iface}-${client_name}.conf"

    echo "$client_priv" > "$c_priv_file";  chmod 600 "$c_priv_file"
    echo "$client_pub"  > "$c_pub_file";   chmod 644 "$c_pub_file"
    ok "Client keys generated."

    # ── Write client .conf ────────────────────────────────────────────────────
    msg "Writing client config: ${c_conf_file}"
    {
        echo "# WireGuard client config — generated by wg-manager"
        echo "# Server:  ${iface}  |  Client: ${client_name}"
        echo "# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo ""
        echo "[Interface]"
        echo "PrivateKey = ${client_priv}"
        echo "Address    = ${client_addr}"
        echo "DNS        = ${dns}"
        echo "MTU        = ${mtu}"
        echo ""
        echo "[Peer]"
        echo "PublicKey  = ${server_pubkey}"
        [[ -n "$psk" ]] && echo "PresharedKey = ${psk}"
        echo "Endpoint   = ${endpoint}:${server_port}"
        echo "AllowedIPs = ${allowed_ips}"
        echo "PersistentKeepalive = 25"
    } > "$c_conf_file"
    chmod 600 "$c_conf_file"
    ok "Client config written."

    # ── Append [Peer] to server .conf ────────────────────────────────────────
    # NOTE: [Peer] header comes first so parsers find # Name inside the block,
    #       not before it (parser resets cur_name on [Peer]).
    msg "Adding peer to server config: ${conf_file}"
    {
        echo ""
        echo "[Peer]"
        echo "# Name = ${client_name}"
        echo "# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "PublicKey  = ${client_pub}"
        [[ -n "$psk" ]] && echo "PresharedKey = ${psk}"
        echo "AllowedIPs = ${client_ip}/32"
    } >> "$conf_file"
    ok "Peer added to server config."

    # ── Hot-reload if interface is up ─────────────────────────────────────────
    if backend_is_up "$iface"; then
        msg "Applying peer live..."
        local bin quick_bin
        bin="$(  [[ "$backend" == "awg" ]] && echo "awg" || echo "wg"  )"
        quick_bin="$( [[ "$backend" == "awg" ]] && echo "awg-quick" || echo "wg-quick" )"
        if "$bin" syncconf "$iface" <("$quick_bin" strip "$iface" 2>/dev/null) 2>/dev/null; then
            ok "Peer applied live."
        else
            warn "Live sync failed — reloading service..."
            local unit
            unit="$(_systemd_unit "$backend" "$iface")"
            if systemctl reload-or-restart "$unit" 2>/dev/null; then
                ok "Service reloaded."
            else
                warn "Reload failed. Restart manually: systemctl restart ${unit}"
            fi
        fi
    else
        info "Interface is down — peer will be active on next start."
    fi

    # ── Generate SVG QR ───────────────────────────────────────────────────────
    local svg_file
    svg_file="$(_generate_qr_svg "$c_conf_file")"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo
    ok "Client '${client_name}' created on '${iface}'."
    echo
    info "IP address:    ${BOLD}${client_addr}${NC}"
    info "Config:        ${c_conf_file}"
    [[ -n "$svg_file" ]] && echo -e "${CYAN}[i]${NC} QR SVG:        ${GREEN}${svg_file}${NC}"
    info "Private key:   ${c_priv_file}"
    info "Public key:    ${BOLD}${client_pub}${NC}"
    [[ -n "$psk" ]] && info "PSK:           (stored in configs)"
    echo

    # ── Print config for copy-paste ───────────────────────────────────────────
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$c_conf_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    # ── Offer terminal QR ─────────────────────────────────────────────────────
    read -rep "Show QR code in terminal? [Y/n]: " qr_ans
    qr_ans="${qr_ans:-Y}"
    if [[ "${qr_ans,,}" == "y" ]]; then
        echo
        qrencode -l L -s 1 -t ansiutf8 < "$c_conf_file"
        echo
    fi

    pause
}

# --- Wrapper called from menu with pre-selected server ----------------------

client_create_for() {
    local iface="$1"
    _client_create_on "$iface"
}

# Core creation logic (shared between client_create and client_create_for)
_client_create_on() {
    local iface="$1"

    local env_file conf_file
    env_file="$(env_path  "$iface")"
    conf_file="$(conf_path "$iface")"

    local backend endpoint use_psk server_port server_pubkey mtu server_network
    backend="$(env_get      "$env_file" WG_BACKEND)";      backend="${backend:-wg}"
    endpoint="$(env_get     "$env_file" WG_ENDPOINT)"
    server_port="$(env_get  "$env_file" WG_PORT)"
    use_psk="$(env_get      "$env_file" WG_USE_PSK)"
    server_pubkey="$(env_get "$env_file" WG_SERVER_PUBLIC_KEY)"
    mtu="$(env_get          "$env_file" WG_MTU)"; mtu="${mtu:-1420}"
    server_network="$(env_get "$env_file" WG_NETWORK)"

    echo
    echo -e "${CYAN}── Client Name ──${NC}"
    local client_name
    while true; do
        read -rep "Client name (e.g. phone-alice): " client_name
        client_name="${client_name// /_}"
        client_name="${client_name//[^a-zA-Z0-9_-]/}"
        [[ -z "$client_name" ]]        && { warn "Name cannot be empty."; continue; }
        (( ${#client_name} > 32 ))     && { warn "Name too long (max 32 chars)."; continue; }
        _client_exists "$iface" "$client_name" && { warn "Client '${client_name}' already exists."; continue; }
        break
    done

    echo; echo -e "${CYAN}── DNS ──${NC}"
    local dns
    read -rep "DNS servers [1.1.1.1, 1.0.0.1]: " dns
    dns="${dns:-1.1.1.1, 1.0.0.1}"

    echo; echo -e "${CYAN}── Routing ──${NC}"
    echo "  1) Full tunnel  (0.0.0.0/0)"
    echo "  2) Split tunnel (VPN subnet only)"
    echo "  3) Custom"
    local rchoice allowed_ips
    read -rep "Routing [1]: " rchoice; rchoice="${rchoice:-1}"
    case "$rchoice" in
        2) allowed_ips="${server_network}" ;;
        3) read -rep "AllowedIPs: " allowed_ips; allowed_ips="${allowed_ips:-0.0.0.0/0, ::/0}" ;;
        *) allowed_ips="0.0.0.0/0, ::/0" ;;
    esac

    echo; echo -e "${CYAN}── Output ──${NC}"
    local keydir; keydir="$(env_get "$env_file" WG_KEY_DIR)"
    local client_dir="${keydir}/clients/${client_name}"
    read -rep "Client config directory [${client_dir}]: " client_dir_in
    client_dir="${client_dir_in:-$client_dir}"; client_dir="${client_dir%/}"

    info "Allocating IP..."
    local pool_file; pool_file="$(_pool_file "$iface")"
    [[ ! -f "$pool_file" ]] && { pool_init "$iface" || { warn "Pool init failed."; pause; return 1; }; }

    local client_ip
    client_ip="$(pool_allocate "$iface" "$client_name")" || { warn "No free IPs."; pause; return 1; }
    info "Allocated: ${BOLD}${client_ip}${NC}"

    local prefix="${server_network#*/}"
    local client_addr="${client_ip}/${prefix}"

    msg "Generating client keys (backend: ${backend})..."
    local client_priv client_pub psk=""
    client_priv="$(backend_genkey "$backend")"
    client_pub="$(echo "$client_priv" | backend_pubkey "$backend")"
    [[ "$use_psk" == "yes" ]] && psk="$(backend_genpsk "$backend")"

    mkdir -p "$client_dir"; chmod 700 "$client_dir"
    local c_priv_file="${client_dir}/private.key"
    local c_pub_file="${client_dir}/public.key"
    local c_conf_file="${client_dir}/${iface}-${client_name}.conf"

    echo "$client_priv" > "$c_priv_file"; chmod 600 "$c_priv_file"
    echo "$client_pub"  > "$c_pub_file";  chmod 644 "$c_pub_file"
    ok "Keys generated."

    {
        echo "# WireGuard client config — generated by wg-manager"
        echo "# Server: ${iface}  |  Client: ${client_name}"
        echo "# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo ""
        echo "[Interface]"
        echo "PrivateKey = ${client_priv}"
        echo "Address    = ${client_addr}"
        echo "DNS        = ${dns}"
        echo "MTU        = ${mtu}"
        echo ""
        echo "[Peer]"
        echo "PublicKey  = ${server_pubkey}"
        [[ -n "$psk" ]] && echo "PresharedKey = ${psk}"
        echo "Endpoint   = ${endpoint}:${server_port}"
        echo "AllowedIPs = ${allowed_ips}"
        echo "PersistentKeepalive = 25"
    } > "$c_conf_file"; chmod 600 "$c_conf_file"
    ok "Client config written: ${c_conf_file}"

    # NOTE: [Peer] header comes first so parsers find # Name inside the block,
    #       not before it (parser resets cur_name on [Peer]).
    {
        echo ""
        echo "[Peer]"
        echo "# Name = ${client_name}"
        echo "# Created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "PublicKey  = ${client_pub}"
        [[ -n "$psk" ]] && echo "PresharedKey = ${psk}"
        echo "AllowedIPs = ${client_ip}/32"
    } >> "$conf_file"
    ok "Peer added to server config."

    local bin; bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"
    if backend_is_up "$iface"; then
        msg "Applying peer live..."
        local quick_bin
        quick_bin="$( [[ "$backend" == "awg" ]] && echo "awg-quick" || echo "wg-quick" )"
        if "$bin" syncconf "$iface" <("$quick_bin" strip "$iface" 2>/dev/null) 2>/dev/null; then
            ok "Peer applied live."
        else
            warn "Live sync failed — reloading service..."
            local unit
            unit="$(_systemd_unit "$backend" "$iface")"
            if systemctl reload-or-restart "$unit" 2>/dev/null; then
                ok "Service reloaded."
            else
                warn "Reload failed. Restart manually: systemctl restart ${unit}"
            fi
        fi
    fi

    # ── Generate SVG QR ───────────────────────────────────────────────────────
    local svg_file
    svg_file="$(_generate_qr_svg "$c_conf_file")"

    echo
    ok "Client '${client_name}' created on '${iface}'."
    info "IP:      ${BOLD}${client_addr}${NC}"
    info "Config:  ${c_conf_file}"
    [[ -n "$svg_file" ]] && echo -e "${CYAN}[i]${NC} QR SVG:  ${GREEN}${svg_file}${NC}"
    echo

    # ── Print config for copy-paste ───────────────────────────────────────────
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    cat "$c_conf_file"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo

    # ── Offer terminal QR ─────────────────────────────────────────────────────
    read -rep "Show QR code? [Y/n]: " qr_ans; qr_ans="${qr_ans:-Y}"
    [[ "${qr_ans,,}" == "y" ]] && { echo; qrencode -l L -s 1 -t ansiutf8 < "$c_conf_file"; echo; }

    pause
}

# --- Check if client name already exists on this server ----------------------

_client_exists() {
    local iface="$1"
    local client_name="$2"
    local conf_file
    conf_file="$(conf_path "$iface")"
    [[ -f "$conf_file" ]] && grep -q "^# Name = ${client_name}$" "$conf_file"
}