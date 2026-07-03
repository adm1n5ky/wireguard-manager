#!/usr/bin/env bash
DEFAULT_MTU=1420

server_create() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Create New Server                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    echo -e "${CYAN}── Step 1: Backend ──${NC}"
    local backend
    prompt_backend backend || return 1

    if ! backend_check "$backend"; then
        warn "Backend '${backend}' is not properly installed."
        pause
        return 1
    fi

    echo
    echo -e "${CYAN}── Step 2: Interface Name ──${NC}"
    local iface
    prompt_iface_name iface || return 1

    echo
    echo -e "${CYAN}── Step 3: Network (CIDR) ──${NC}"
    local cidr

    while true; do
        prompt_cidr cidr || return 1

        local conflict
        conflict="$(network_conflicts "$cidr")"
        if [[ $? -eq 0 ]]; then
            warn "Network ${cidr} overlaps with existing config: ${conflict}"
            warn "Choose a different network."
        else
            break
        fi
    done

    local server_ip
    server_ip="$(network_to_server_ip "$cidr")"
    info "Server address will be: ${BOLD}${server_ip}${NC}"

    echo
    echo -e "${CYAN}── Step 4b: IPv6 Networks (optional) ──${NC}"
    echo

    local wg_network6=""
    local ipv6_mode=""

    local _avail_count
    _avail_count="$(ipv6_available_count)"

    if (( _avail_count == 0 )); then
        echo -e "  ${YELLOW}No IPv6 networks configured.${NC}"
        echo -e "  Go to ${BOLD}System → IPv6 Networks${NC} to add your routable blocks."
        echo
        read -rep "  Continue without IPv6? [Y/n]: " _skip_v6
        _skip_v6="${_skip_v6:-Y}"
        if [[ "${_skip_v6,,}" != "y" ]]; then
            info "Cancelled. Configure IPv6 networks in System menu first."
            pause
            return 0
        fi
    else
        echo "  Available IPv6 blocks:"
        echo
        local -a _avail_cidrs _avail_types
        local _aidx=0
        while IFS= read -r _line; do
            _aidx=$(( _aidx + 1 ))
            local _acidr _atype _acomment
            _acidr="$(echo "$_line"    | awk '{print $1}')"
            _atype="$(echo "$_line"    | awk '{print $2}')"
            _acomment="$(echo "$_line" | awk '{$1=$2=""; print substr($0,3)}')"
            _avail_cidrs+=("$_acidr")
            _avail_types+=("$_atype")

            local _preview=""
            local _apfx="${_acidr#*/}"
            if (( _apfx < 64 )); then
                local _next64
                _next64="$(ipv6_carve_next_64 "$_acidr")"
                [[ -n "$_next64" ]] && _preview=" (will use: ${_next64})"
            fi
            printf "  %d) %-38s [%-6s] %s%s\n" \
                "$_aidx" "$_acidr" "$_atype" "$_acomment" "$_preview"
        done < <(ipv6_read_available)

        echo
        echo "  Enter numbers to include (space-separated), or Enter to skip."
        echo
        read -rep "  Select [e.g. 1 2] or Enter to skip: " _v6_sel
        echo

        if [[ -n "$_v6_sel" ]]; then
            local _v6_cidrs=()
            local _v6_mode_final=""

            for _sel in $_v6_sel; do
                if [[ "$_sel" =~ ^[0-9]+$ ]] && \
                   (( _sel >= 1 && _sel <= ${#_avail_cidrs[@]} )); then
                    local _raw="${_avail_cidrs[$(( _sel - 1 ))]}"
                    local _rawtype="${_avail_types[$(( _sel - 1 ))]}"
                    local _apfx="${_raw#*/}"
                    local _carved

                    if (( _apfx < 64 )); then
                        _carved="$(ipv6_carve_next_64 "$_raw")"
                        if [[ -z "$_carved" ]]; then
                            warn "No free /64 available in ${_raw} — skipping."
                            continue
                        fi
                        info "Carved from ${_raw}: ${BOLD}${_carved}${NC}"
                    else
                        _carved="$_raw"
                    fi

                    _v6_cidrs+=("$_carved")

                    if [[ -z "$_v6_mode_final" ]]; then
                        _v6_mode_final="$_rawtype"
                    elif [[ "$_v6_mode_final" != "$_rawtype" ]]; then
                        _v6_mode_final="nat66"
                    fi
                fi
            done

            if [[ ${#_v6_cidrs[@]} -gt 0 ]]; then
                wg_network6="$(IFS=','; echo "${_v6_cidrs[*]}")"
                ipv6_mode="${_v6_mode_final:-nat66}"
                info "IPv6 networks: ${BOLD}${wg_network6}${NC}"
                info "IPv6 mode:     ${BOLD}${ipv6_mode}${NC}"
            fi
        fi
    fi

    # ── Step 4c: External Interface (NAT/forwarding) ──────────────────────────
    echo
    echo -e "${CYAN}── Step 4c: External Interface ──${NC}"
    echo
    local ext_iface=""
    if nft_available; then
        prompt_nft_ext_iface ext_iface || return 1
    else
        warn "nft (nftables) not found — firewall/NAT rules will not be managed automatically."
        warn "Install nftables and re-create the instance, or add forwarding rules manually."
    fi

    echo
    echo -e "${CYAN}── Step 4: Listen Port ──${NC}"
    local port
    prompt_port port || return 1

    echo
    echo -e "${CYAN}── Step 5: MTU ──${NC}"
    local mtu err

    while true; do
        read -rep "MTU [${DEFAULT_MTU}]: " mtu
        mtu="${mtu:-$DEFAULT_MTU}"

        err="$(validate_mtu "$mtu")"
        if [[ $? -eq 0 ]]; then
            break
        fi
        warn "$err"
    done

    echo
    echo -e "${CYAN}── Step 6: Key Directory ──${NC}"
    local default_keydir
    default_keydir="$(key_dir "$iface")"
    local keydir

    read -rep "Key directory [${default_keydir}]: " keydir
    keydir="${keydir:-$default_keydir}"
    keydir="${keydir%/}"

    echo
    echo -e "${CYAN}── Step 7: Endpoint ──${NC}"
    local endpoint
    prompt_endpoint endpoint || return 1

    echo
    echo -e "${CYAN}── Step 8: Pre-shared Keys ──${NC}"
    local use_psk
    read -rep "Use unique PSK per client? [Y/n]: " use_psk
    use_psk="${use_psk:-Y}"
    if [[ "${use_psk,,}" == "y" ]]; then
        use_psk="yes"
    else
        use_psk="no"
    fi

    echo
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo -e "${BOLD}  Summary${NC}"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    printf "  %-28s %s\n" "Backend:"            "$backend"
    printf "  %-28s %s\n" "Interface:"          "$iface"
    printf "  %-28s %s\n" "Network:"            "$cidr"
    printf "  %-28s %s\n" "Server address:"     "$server_ip"
    printf "  %-28s %s\n" "Listen port:"        "$port"
    printf "  %-28s %s\n" "MTU:"                "$mtu"
    printf "  %-28s %s\n" "Key directory:"      "$keydir"
    printf "  %-28s %s\n" "Endpoint:"           "$endpoint"
    printf "  %-28s %s\n" "PSK per client:"     "$use_psk"
    [[ -n "$wg_network6" ]] && printf "  %-28s %s\n" "IPv6 networks:" "$wg_network6"
    [[ -n "$ipv6_mode"   ]] && printf "  %-28s %s\n" "IPv6 mode:"    "$ipv6_mode"
    [[ -n "$ext_iface"   ]] && printf "  %-28s %s\n" "External interface:" "$ext_iface"
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo

    read -rep "Proceed with creation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        info "Cancelled."
        return 0
    fi

    msg "Creating key directory: ${keydir}"
    mkdir -p "$keydir"
    chmod 700 "$keydir"

    msg "Generating keys (backend: ${backend})..."
    local private_key public_key
    private_key="$(backend_genkey "$backend")"
    public_key="$(echo "$private_key" | backend_pubkey "$backend")"

    local priv_file="${keydir}/private.key"
    local pub_file="${keydir}/public.key"

    echo "$private_key" > "$priv_file"
    echo "$public_key"  > "$pub_file"

    chmod 600 "$priv_file"
    chmod 644 "$pub_file"
    ok "Keys generated."

    local conf_file
    conf_file="$(conf_path "$iface")"

    local v6_server_addresses=""
    if [[ -n "$wg_network6" ]]; then
        IFS=',' read -ra _v6nets <<< "$wg_network6"
        for _v6net in "${_v6nets[@]}"; do
            local _v6srv
            _v6srv="$(ipv6_network_to_server_ip "$_v6net")"
            [[ -n "$_v6srv" ]] && v6_server_addresses+=", ${_v6srv}"
        done
    fi

    msg "Writing config: ${conf_file}"
    cat > "$conf_file" <<EOF
# WireGuard server configuration — managed by wg-manager
# Interface: ${iface}
# Backend:   ${backend}
# Created:   $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# DO NOT EDIT manually if using wg-manager.

[Interface]
PrivateKey = ${private_key}
Address    = ${server_ip}${v6_server_addresses}
ListenPort = ${port}
MTU        = ${mtu}

# Peers will be added here by wg-manager (client-create)
EOF

    chmod 600 "$conf_file"
    ok "Config written."

    local env_file
    env_file="$(env_path "$iface")"
    local created_at
    created_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    msg "Writing metadata: ${env_file}"
    cat > "$env_file" <<EOF
# wg-manager metadata — DO NOT EDIT manually
WG_NAME=${iface}
WG_BACKEND=${backend}
WG_NETWORK=${cidr}
WG_SERVER_IP=${server_ip}
WG_PORT=${port}
WG_MTU=${mtu}
WG_ENDPOINT=${endpoint}
WG_USE_PSK=${use_psk}
WG_KEY_DIR=${keydir}
WG_PRIVATE_KEY_FILE=${priv_file}
WG_PUBLIC_KEY_FILE=${pub_file}
WG_SERVER_PUBLIC_KEY=${public_key}
WG_NETWORK6=${wg_network6}
WG_IPV6_MODE=${ipv6_mode}
WG_EXT_IFACE=${ext_iface}
WG_CREATED_AT=${created_at}
EOF

    chmod 600 "$env_file"
    ok "Metadata written."

    local unit
    unit="$(_systemd_unit "$backend" "$iface")"
    msg "Enabling systemd service: ${unit}"
    backend_enable "$iface"
    ok "Service enabled (will start on next boot)."

    echo
    read -rep "Start interface now? [Y/n]: " start_now
    start_now="${start_now:-Y}"

    if [[ "${start_now,,}" == "y" ]]; then
        msg "Starting ${unit}..."
        if backend_start "$iface"; then
            ok "Interface ${iface} is UP."
            nft_instance_start "$iface"
        else
            warn "Failed to start. Check: journalctl -u ${unit}"
        fi
    else
        info "Start later: systemctl start ${unit}"
        info "Firewall/NAT rules will be generated automatically on first start."
    fi

    echo
    ok "Server '${iface}' created successfully."
    echo
    info "Backend:    ${BOLD}${backend}${NC}"
    info "Public key: ${BOLD}${public_key}${NC}"
    info "Config:     ${conf_file}"
    info "Env:        ${env_file}"
    info "Keys:       ${keydir}/"
    pause
}