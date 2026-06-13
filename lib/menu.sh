#!/usr/bin/env bash
# =============================================================================
# lib/menu.sh — Main interactive menu (three-level structure)
# =============================================================================

_print_header() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╦ ╦╔═╗  ╔╦╗╔═╗╔╗╔╔═╗╔═╗╔═╗╦═╗"
    echo "  ║║║║ ╦  ║║║╠═╣║║║╠═╣║ ╦║╣ ╠╦╝"
    echo "  ╚╩╝╚═╝  ╩ ╩╩ ╩╝╚╝╩ ╩╚═╝╚═╝╩╚═"
    echo -e "${NC}"
    echo -e "${BOLD}  WireGuard Multi-Instance Manager  v1.0${NC}"
    echo -e "  Ubuntu 24/26 LTS"
    echo
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
    echo
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}  %-4s %-16s %-8s %-7s %-5s %-4s %-22s %-6s %s${NC}\n" \
           "ID" "INTERFACE" "BACKEND" "STATE" "BOOT" "MGR" "ADDRESS" "PORT" "PEERS"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"

    local found=0
    local idx=0
    declare -A seen

    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue
        local name network port backend
        name="$(env_get    "$env_file" WG_NAME)"
        network="$(env_get "$env_file" WG_SERVER_IP)"
        [[ -z "$network" ]] && network="$(env_get "$env_file" WG_NETWORK)"
        port="$(env_get    "$env_file" WG_PORT)"
        backend="$(env_get "$env_file" WG_BACKEND)"
        backend="${backend:-wg}"
        [[ -z "$name" ]] && continue

        idx=$(( idx + 1 ))
        seen["$name"]=1
        found=1

        local state boot peers state_col
        state="$(_iface_state "$name")"
        boot="$(_iface_boot   "$name")"
        peers="$(_peers_summary "$name")"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac

        printf "  %-4s %-16s %-8s %-16s %-5s %-4s %-22s %-6s %s\n" \
               "$idx" "$name" "$backend" \
               "$(echo -e "$state_col")" \
               "$boot" \
               "${GREEN}yes${NC}" \
               "${network:--}" \
               "${port:--}" \
               "${peers:--}"
    done

    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        local name
        name="$(basename "$conf_file" .conf)"
        [[ -n "${seen[$name]+_}" ]] && continue
        found=1
        idx=$(( idx + 1 ))

        local address port_c state boot state_col
        address="$(_conf_address "$conf_file")"
        port_c="$(_conf_port "$conf_file")"
        state="$(_iface_state "$name")"
        boot="$(_iface_boot   "$name")"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac

        printf "  %-4s %-16s %-8s %-16s %-5s %-4s %-22s %-6s %s\n" \
               "$idx" "$name" "-" \
               "$(echo -e "$state_col")" \
               "$boot" \
               "${YELLOW}no${NC} " \
               "${address:--}" \
               "${port_c:--}" \
               "-"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No WireGuard configs found.${NC}"
    fi

    echo -e "${BOLD}══════════════════════════════════════════════════════════════════════════${NC}"
    echo -e "  ${CYAN}PEERS: total/created/active  |  MGR: ${GREEN}yes${NC}${CYAN} = managed  |  ${YELLOW}no${NC}${CYAN} = manual${NC}"
    echo
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
        created="$(grep -c '^\[Peer\]' "$conf_file" 2>/dev/null || echo 0)"
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
        echo "  5) Interface status"
        echo "  6) Manage clients →"
        echo
        echo "  0) Back to main menu"
        echo

        read -rp "  Choice: " choice
        echo

        case "$choice" in
            1) server_create ;;
            2) server_delete ;;
            3) server_up ;;
            4) server_down ;;
            5) server_status ;;
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
        read -rp "  Server: " schoice
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
        _print_header
        echo -e "  ${BOLD}Clients — ${iface}${NC}"
        echo
        # Future: show client list here
        echo -e "  ${YELLOW}[client list — roadmap]${NC}"
        echo
        echo "  ─────────────────────────────────"
        echo "  1) Add client          [roadmap]"
        echo "  2) Delete client       [roadmap]"
        echo "  3) Show QR code        [roadmap]"
        echo "  4) SSH push config     [roadmap]"
        echo
        echo "  0) Back"
        echo

        read -rp "  Choice: " choice
        echo

        case "$choice" in
            1|2|3|4)
                warn "Not implemented yet — coming in roadmap."
                sleep 1
                ;;
            0) return 0 ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
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

        read -rp "  Choice: " choice
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

        read -rp "  Choice: " choice
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