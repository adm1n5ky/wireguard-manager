#!/usr/bin/env bash
# =============================================================================
# lib/menu.sh — Main interactive menu (three-level structure)
# =============================================================================

_print_header_noclear() {
    echo -e "${BOLD}${CYAN}"
    echo "  ╦ ╦╔═╗  ╔╦╗╔═╗╔╗╔╔═╗╔═╗╔═╗╦═╗"
    echo "  ║║║║ ╦  ║║║╠═╣║║║╠═╣║ ╦║╣ ╠╦╝"
    echo "  ╚╩╝╚═╝  ╩ ╩╩ ╩╝╚╝╩ ╩╚═╝╚═╝╩╚═"
    echo -e "${NC}"
    echo -e "${BOLD}  WireGuard Multi-Instance Manager  v1.0${NC}"
    echo -e "  Ubuntu 24/26 LTS"
    echo
}

_print_header() {
    clear
    _print_header_noclear
}

_print_instance_summary() {
    local count=0
    local up_count=0

    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue
        local name
        name="$(env_get "$env_file" WG_NAME)"
        [[ -z "$name" ]] && continue
        count=$(( count + 1 ))
        local state
        state="$(_iface_state "$name")"
        [[ "$state" == "UP" ]] && up_count=$(( up_count + 1 ))
    done

    if (( count == 0 )); then
        echo -e "  ${YELLOW}No instances configured yet.${NC}"
    else
        echo -e "  Instances: ${BOLD}${count}${NC} total, ${GREEN}${up_count}${NC} UP"
    fi
    echo
}

# =============================================================================
# SUBMENU: Servers
# =============================================================================

_servers_list_compact() {
    config_list_inline
}

# Count peers: total_in_pool / created_in_conf / active_handshake
_peers_summary() {
    local iface="$1"
    local env_file conf_file
    env_file="$(env_path "$iface")"
    conf_file="$(conf_path "$iface")"

    local total="-" created=0 active="-"

    # Total from IP pool (subnet size - 2: network + server)
    local network prefix
    network="$(env_get "$env_file" WG_NETWORK 2>/dev/null)"
    if [[ -n "$network" ]]; then
        prefix="${network#*/}"
        if [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix <= 30 )); then
            local hosts=$(( (1 << (32 - prefix)) - 2 ))
            total=$(( hosts - 1 ))   # subtract server itself
        fi
    fi

    # Created: count [Peer] sections in conf
    if [[ -f "$conf_file" ]]; then
        created="$(grep -c '^\[Peer\]' "$conf_file" 2>/dev/null)"
        created="${created:-0}"
    fi

    # Active: peers with recent handshake (via wg show, if up)
    if ip link show "$iface" &>/dev/null 2>&1; then
        local backend
        backend="$(backend_for_iface "$iface")"
        active="$(wg show "$iface" latest-handshakes 2>/dev/null | \
            awk -v t="$(date +%s)" '{if (t-$2 < 180 && $2>0) c++} END {print c+0}')"
    fi

    echo "${total}/${created}/${active}"
}

menu_servers() {
    while true; do
        _print_header
        echo -e "  ${BOLD}Servers${NC}"
        _servers_list_compact

        echo -e "  ${BOLD}Actions${NC}"
        echo "  ─────────────────────────────────"
        echo "  1) Create server"
        echo "  2) Delete server"
        echo "  3) Start interface"
        echo "  4) Stop interface"
        echo "  5) Peer Monitor"
        echo "  6) Manage clients →"
        echo
        echo "  0) Back to main menu"
        echo

        read -rep "  Choice: " choice
        echo

        case "$choice" in
            1) server_create ;;
            2) server_delete ;;
            3) server_up ;;
            4) server_down ;;
            5) peer_monitor ;;
            6) menu_clients ;;
            0) return 0 ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# SUBMENU: Clients
# =============================================================================

menu_clients() {
    while true; do
        _print_header
        echo -e "  ${BOLD}Clients${NC}"
        echo

        # Pick server first if called from main menu
        local instances
        mapfile -t instances < <(list_wg_instances)

        if [[ ${#instances[@]} -eq 0 ]]; then
            warn "No managed instances found. Create a server first."
            pause
            return 0
        fi

        echo "  Select server:"
        local i
        for i in "${!instances[@]}"; do
            local name="${instances[$i]}"
            local state
            state="$(_iface_state "$name")"
            local peers
            peers="$(_peers_summary "$name")"
            printf "  %d) %-15s [%s]  peers: %s\n" \
                   $(( i + 1 )) "$name" "$state" "$peers"
        done
        echo "  0) Back"
        echo

        local schoice
        read -rep "  Server: " schoice
        echo

        if [[ "$schoice" == "0" ]]; then
            return 0
        fi

        if ! [[ "$schoice" =~ ^[0-9]+$ ]] || (( schoice < 1 || schoice > ${#instances[@]} )); then
            warn "Invalid selection."
            sleep 1
            continue
        fi

        local selected_iface="${instances[$(( schoice - 1 ))]}"
        _menu_clients_for "$selected_iface"
    done
}

_menu_clients_for() {
    local iface="$1"

    while true; do
        clear
        _print_header_noclear
        echo -e "  ${BOLD}Clients — ${iface}${NC}"
        echo
        _clients_list_compact "$iface"

        echo "  ─────────────────────────────────"
        echo "  1) Add client"
        echo "  2) Delete client"
        echo "  3) Show client .conf & QR code"
        echo
        echo "  0) Back"
        echo

        read -rep "  Choice: " choice
        echo

        case "$choice" in
            1) client_create_for "$iface" ;;
            2) client_delete_for "$iface" ;;
            3) client_show_for "$iface" ;;
            0) return 0 ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
}

_clients_list_compact() {
    local iface="$1"
    local conf_file
    conf_file="$(conf_path "$iface")"

    if [[ ! -f "$conf_file" ]] || ! grep -q '^\[Peer\]' "$conf_file" 2>/dev/null; then
        echo -e "  ${YELLOW}No clients yet.${NC}"
        echo
        return
    fi

    printf "  ${BOLD}%-4s %-20s %-18s %s${NC}\n" "ID" "NAME" "IP" "PUBLIC KEY"
    echo "  ──────────────────────────────────────────────────────────────"

    local idx=0 cur_name="" cur_pubkey="" cur_ip=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then
            if [[ -n "$cur_pubkey" ]]; then
                idx=$(( idx + 1 ))
                printf "  %-4s %-20s %-18s %.24s…\n" \
                       "$idx" "${cur_name:--}" "${cur_ip:--}" "$cur_pubkey"
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

    if [[ -n "$cur_pubkey" ]]; then
        idx=$(( idx + 1 ))
        printf "  %-4s %-20s %-18s %.24s…\n" \
               "$idx" "${cur_name:--}" "${cur_ip:--}" "$cur_pubkey"
    fi

    local stats
    stats="$(pool_stats "$iface")"
    echo
    echo -e "  Pool (total/used/free): ${BOLD}${stats}${NC}"
    echo
}

# =============================================================================
# QR code display
# =============================================================================

client_show_qr() {
    local iface="$1"

    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Show QR Code                       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    if ! command -v qrencode &>/dev/null; then
        warn "qrencode not installed. Install it with: apt-get install qrencode"
        pause
        return 0
    fi

    local env_file keydir
    env_file="$(env_path "$iface")"
    keydir="$(env_get "$env_file" WG_KEY_DIR)"

    # Build list of clients from conf
    local conf_file
    conf_file="$(conf_path "$iface")"

    if [[ ! -f "$conf_file" ]] || ! grep -q '^\[Peer\]' "$conf_file" 2>/dev/null; then
        warn "No clients on '${iface}'."
        pause
        return 0
    fi

    local -a client_names client_ips
    local cur_name="" cur_ip=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^\[Peer\] ]]; then
            if [[ -n "$cur_name" ]]; then
                client_names+=("$cur_name")
                client_ips+=("${cur_ip:--}")
            fi
            cur_name=""; cur_ip=""
        elif [[ "$line" =~ ^#[[:space:]]Name[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_ip="${BASH_REMATCH[1]%%/*}"; cur_ip="${cur_ip// /}"
        fi
    done < "$conf_file"
    [[ -n "$cur_name" ]] && { client_names+=("$cur_name"); client_ips+=("${cur_ip:--}"); }

    if [[ ${#client_names[@]} -eq 0 ]]; then
        warn "No named clients found on '${iface}'."
        pause
        return 0
    fi

    echo "Select client:"
    local i
    for i in "${!client_names[@]}"; do
        printf "  %d) %-20s  IP: %s\n" $(( i + 1 )) "${client_names[$i]}" "${client_ips[$i]}"
    done
    echo "  0) Cancel"
    echo

    local cchoice
    while true; do
        read -rep "Client: " cchoice
        [[ "$cchoice" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$cchoice" =~ ^[0-9]+$ ]] && (( cchoice >= 1 && cchoice <= ${#client_names[@]} )); then
            break
        fi
        warn "Invalid selection."
    done

    local sel_name="${client_names[$(( cchoice - 1 ))]}"
    local client_dir="${keydir}/clients/${sel_name}"
    local c_conf_file="${client_dir}/${iface}-${sel_name}.conf"

    if [[ ! -f "$c_conf_file" ]]; then
        warn "Config file not found: ${c_conf_file}"
        pause
        return 0
    fi

    echo
    info "Client: ${BOLD}${sel_name}${NC}"
    info "Config: ${c_conf_file}"
    echo
    qrencode -t ansiutf8 < "$c_conf_file"
    echo

    pause
}

# =============================================================================
# SUBMENU: System
# =============================================================================

menu_system() {
    while true; do
        _print_header
        echo -e "  ${BOLD}System${NC}"
        echo

        _system_status_summary
        echo

        echo "  ─────────────────────────────────"
        echo "  1) Check / install packages"
        echo "  2) Check module integrity"
        echo "  3) Update wg-manager"
        echo
        echo "  0) Back to main menu"
        echo

        read -rep "  Choice: " choice
        echo

        case "$choice" in
            1) system_check_packages ;;
            2) system_check_modules ;;
            3) system_update ;;
            0) return 0 ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
}

# =============================================================================
# MAIN MENU
# =============================================================================

main_menu() {
    while true; do
        _print_header
        _print_instance_summary

        echo -e "  ${BOLD}Main Menu${NC}"
        echo "  ─────────────────────────────────"
        echo "  1) Servers"
        echo "  2) Clients"
        echo "  3) System"
        echo
        echo "  0) Exit"
        echo

        read -rep "  Choice: " choice
        echo

        case "$choice" in
            1) menu_servers ;;
            2) menu_clients ;;
            3) menu_system ;;
            0)
                echo -e "  ${GREEN}Goodbye.${NC}"
                echo
                exit 0
                ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
}