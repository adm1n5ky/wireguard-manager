#!/usr/bin/env bash
# =============================================================================
# lib/table.sh — Shared server table rendering
# Total width: 86 chars
#
#  2  left pad
#  2+1  ID
# 15+1  INTERFACE
#  7+1  BACKEND
#  5+1  STATE
#  4+1  BOOT
#  3+1  MGR
# 18+3  ADDRESS
#  5+3  PORT
# 11    PEERS
#  2    right pad
# =============================================================================

TABLE_SEP="══════════════════════════════════════════════════════════════════════════════════════"
# 86 ═

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

# table_row id iface backend state boot mgr_plain addr port peers state_col mgr_col
table_row() {
    local id="$1" iface="$2" backend="$3" state="$4" boot="$5"
    local mgr_plain="$6" addr="$7" port="$8" peers="$9"
    local state_col="${10}" mgr_col="${11}"

    # Plain fixed-width columns (no ANSI inside)
    printf "  %-3s%-16s%-8s" "$id" "$iface" "$backend"

    # STATE: field=6, colour adds invisible chars — pad manually
    printf "%b%-$((6 - ${#state}))s" "$state_col" ""

    printf "%-5s" "$boot"

    # MGR: field=4
    printf "%b%-$((4 - ${#mgr_plain}))s" "$mgr_col" ""

    # ADDRESS right-aligned in 21, PORT right-aligned in 8
    printf "  %-19s   %-5s %s\n" "$addr" "$port" "$peers"
}