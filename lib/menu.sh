#!/usr/bin/env bash
# =============================================================================
# lib/menu.sh — Main interactive menu
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

main_menu() {
    while true; do
        _print_header
        _print_instance_summary

        echo -e "  ${BOLD}Server Management${NC}"
        echo "  ─────────────────────────────────"
        echo "  1) List configurations"
        echo "  2) Create new server"
        echo "  3) Delete server"
        echo
        echo -e "  ${BOLD}Interface Control${NC}"
        echo "  ─────────────────────────────────"
        echo "  4) Start interface"
        echo "  5) Stop interface"
        echo "  6) Interface status"
        echo
        echo "  0) Exit"
        echo

        read -rp "  Choice: " choice
        echo

        case "$choice" in
            1) config_list ;;
            2) server_create ;;
            3) server_delete ;;
            4) server_up ;;
            5) server_down ;;
            6) server_status ;;
            0)
                echo -e "  ${GREEN}Goodbye.${NC}"
                echo
                exit 0
                ;;
            *)
                warn "Unknown option: ${choice}"
                sleep 1
                ;;
        esac
    done
}
