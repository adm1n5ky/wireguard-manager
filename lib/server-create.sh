#!/usr/bin/env bash
# =============================================================================
# lib/server-create.sh — Interactive WireGuard / AmneziaWG server creation
# =============================================================================

DEFAULT_MTU=1420

server_create() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Create New Server                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Step 1: Backend ───────────────────────────────────────────────────────
    echo -e "${CYAN}── Step 1: Backend ──${NC}"
    local backend
    prompt_backend backend || return 1

    if ! backend_check "$backend"; then
        warn "Backend '${backend}' is not properly installed."
        pause
        return 1
    fi

    # ── Step 2: Interface name ────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 2: Interface Name ──${NC}"
    local iface
    prompt_iface_name iface || return 1

    # ── Step 3: Network CIDR ──────────────────────────────────────────────────
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

    # ── Step 4: Server IP (auto) ──────────────────────────────────────────────
    local server_ip
    server_ip="$(network_to_server_ip "$cidr")"
    info "Server address will be: ${BOLD}${server_ip}${NC}"

    # ── Step 4b: IPv6 networks (optional) ─────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 4b: IPv6 Networks (optional) ──${NC}"
    echo

    local detected_v6=()
    mapfile -t detected_v6 < <(detect_ipv6_prefixes)

    local wg_network6=""

    if [[ ${#detected_v6[@]} -gt 0 ]]; then
        info "Detected routable IPv6 prefixes on this host:"
        local di
        for di in "${!detected_v6[@]}"; do
            printf "  %d) %s
" $(( di + 1 )) "${detected_v6[$di]}"
        done
        echo
        echo "  Enter numbers to include (space-separated), or press Enter to skip."
        echo "  A /64 will be auto-carved from larger prefixes using instance name."
        echo
        read -rep "  Select [e.g. 1 2] or Enter to skip: " v6_sel
        echo

        if [[ -n "$v6_sel" ]]; then
            local v6_cidrs=()
            for sel in $v6_sel; do
                if [[ "$sel" =~ ^[0-9]+$ ]] &&                    (( sel >= 1 && sel <= ${#detected_v6[@]} )); then
                    local raw="${detected_v6[$(( sel - 1 ))]}"
                    local prefix="${raw#*/}"
                    local carved
                    if (( prefix < 64 )); then
                        # Carve /64 from larger prefix using iface as subnet index
                        carved="$(python3 -c "
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
# Use subnets() to get /64 slices; pick one based on iface hash
subnets = list(net.subnets(new_prefix=64))
idx = hash(sys.argv[2]) % len(subnets)
print(str(subnets[abs(idx)]))
" "$raw" "$iface" 2>/dev/null)"
                        if [[ -n "$carved" ]]; then
                            info "Carved from ${raw}: ${BOLD}${carved}${NC}"
                            v6_cidrs+=("$carved")
                        fi
                    else
                        v6_cidrs+=("$raw")
                    fi
                fi
            done
            if [[ ${#v6_cidrs[@]} -gt 0 ]]; then
                wg_network6="$(IFS=','; echo "${v6_cidrs[*]}")"
                info "IPv6 networks: ${BOLD}${wg_network6}${NC}"
            fi
        fi
    else
        info "No routable IPv6 prefixes detected."
        read -rep "  Enter IPv6 CIDR(s) manually (comma-separated) or Enter to skip: " wg_network6
        wg_network6="${wg_network6// /}"
    fi

    # ── Step 4c: NAT66 or routing (only if IPv6 configured) ───────────────────
    local ipv6_mode=""
    if [[ -n "$wg_network6" ]]; then
        echo
        echo -e "${CYAN}── Step 4c: IPv6 Forwarding Mode ──${NC}"
        echo "  1) NAT66     — masquerade behind server IP (simpler, recommended for HE tunnel)"
        echo "  2) Routing   — pure forwarding, clients get real IPv6 (requires upstream routing)"
        echo
        local v6_mode_choice
        read -rep "  Mode [1]: " v6_mode_choice
        v6_mode_choice="${v6_mode_choice:-1}"
        case "$v6_mode_choice" in
            2) ipv6_mode="routing" ;;
            *) ipv6_mode="nat66"   ;;
        esac
        info "IPv6 mode: ${BOLD}${ipv6_mode}${NC}"
    fi

    # ── Step 5: Listen port ───────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 4: Listen Port ──${NC}"
    local port
    prompt_port port || return 1

    # ── Step 6: MTU ───────────────────────────────────────────────────────────
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

    # ── Step 7: Key directory ─────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 6: Key Directory ──${NC}"
    local default_keydir
    default_keydir="$(key_dir "$iface")"
    local keydir

    read -rep "Key directory [${default_keydir}]: " keydir
    keydir="${keydir:-$default_keydir}"
    keydir="${keydir%/}"

    # ── Step 8: Endpoint ──────────────────────────────────────────────────────
    echo
    echo -e "${CYAN}── Step 7: Endpoint ──${NC}"
    local endpoint
    prompt_endpoint endpoint || return 1

    # ── Step 9: PSK mode ──────────────────────────────────────────────────────
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

    # ── Summary ───────────────────────────────────────────────────────────────
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
    echo -e "${BOLD}══════════════════════════════════════${NC}"
    echo

    read -rep "Proceed with creation? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        info "Cancelled."
        return 0
    fi

    # ── Generate keys ─────────────────────────────────────────────────────────
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

    # ── Write .conf ───────────────────────────────────────────────────────────
    local conf_file
    conf_file="$(conf_path "$iface")"

    # Build IPv6 server addresses for [Interface] Address field
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

    # ── Write .env ────────────────────────────────────────────────────────────
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
WG_CREATED_AT=${created_at}
EOF

    chmod 600 "$env_file"
    ok "Metadata written."

    # ── Enable systemd service ────────────────────────────────────────────────
    local unit
    unit="$(_systemd_unit "$backend" "$iface")"
    msg "Enabling systemd service: ${unit}"
    backend_enable "$iface"
    ok "Service enabled (will start on next boot)."

    # ── Offer to start the interface ──────────────────────────────────────────
    echo
    read -rep "Start interface now? [Y/n]: " start_now
    start_now="${start_now:-Y}"

    if [[ "${start_now,,}" == "y" ]]; then
        msg "Starting ${unit}..."
        if backend_start "$iface"; then
            ok "Interface ${iface} is UP."
        else
            warn "Failed to start. Check: journalctl -u ${unit}"
        fi
    else
        info "Start later: systemctl start ${unit}"
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