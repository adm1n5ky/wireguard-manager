#!/usr/bin/env bash
# =============================================================================
# lib/table.sh — Shared server table rendering
# =============================================================================

TABLE_SEP="══════════════════════════════════════════════════════════════════════════════════════"

table_header() {
    echo -e "${BOLD}${TABLE_SEP}${NC}"
    printf "${BOLD}  %-3s%-16s%-8s%-6s%-5s%-4s%-21s%-8s%s${NC}\n" \
        "ID " "INTERFACE" "BACKEND" "STATE" "BOOT" "MGR" "  ADDRESS" "   PORT" "PEERS"
    echo -e "${BOLD}${TABLE_SEP}${NC}"
}

table_footer() {
    echo -e "${BOLD}${TABLE_SEP}${NC}"
    echo -e "  ${CYAN}ID=system  |  PEERS: total/created/active  |  MGR: ${GREEN}yes${NC}${CYAN}=managed  ${YELLOW}no${NC}${CYAN}=manual${NC}"
    echo
}

table_row() {
    local id="$1" iface="$2" backend="$3" state="$4" boot="$5"
    local mgr_plain="$6" addr="$7" port="$8" peers="$9"
    local state_col="${10}" mgr_col="${11}"

    printf "  %-3s%-16s%-8s" "$id" "$iface" "$backend"
    printf "%b%-$((6 - ${#state}))s" "$state_col" ""
    printf "%-5s" "$boot"
    printf "%b%-$((4 - ${#mgr_plain}))s" "$mgr_col" ""
    printf "  %-19s   %-5s %s\n" "$addr" "$port" "$peers"
}