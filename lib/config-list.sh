#!/usr/bin/env bash
# =============================================================================
# lib/config-list.sh — List all WireGuard instances (managed + unmanaged)
# =============================================================================

# Returns UP / DOWN / STOPPED for a given interface name
_iface_state() {
    local iface="$1"
    if ip link show "$iface" &>/dev/null 2>&1; then
        if ip link show "$iface" 2>/dev/null | head -1 | grep -q "UP"; then
            echo "UP"
        else
            echo "DOWN"
        fi
    else
        echo "STOPPED"
    fi
}

# Returns YES / NO for systemd auto-start
_iface_boot() {
    local iface="$1"
    if systemctl is-enabled "wg-quick@${iface}" &>/dev/null; then
        echo "YES"
    else
        echo "NO"
    fi
}

# Extract Address from a .conf file
_conf_address() {
    local conf="$1"
    grep -m1 "^Address" "$conf" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

# Extract ListenPort from a .conf file
_conf_port() {
    local conf="$1"
    grep -m1 "^ListenPort" "$conf" 2>/dev/null | sed 's/.*=\s*//' | tr -d ' '
}

# Count visible (non-ANSI) characters in a string
# Usage: _visible_len "$colored_string"
_visible_len() {
    local s
    s="$(printf '%b' "$1")"
    s="$(echo "$s" | sed 's/\x1b\[[0-9;]*m//g')"
    echo "${#s}"
}

# Print a colored string padded to $width visible characters (left-aligned)
# Usage: _pad_colored "$colored_string" $width
_pad_colored() {
    local s="$1"
    local width="$2"
    local visible pad
    visible="$(_visible_len "$s")"
    pad=$(( width - visible ))
    (( pad < 0 )) && pad=0
    printf '%b%*s' "$s" "$pad" ""
}

config_list() {
    echo
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    printf "${BOLD}  %-16s %-9s %-5s %-7s %-22s %s${NC}\n" \
           "INTERFACE" "STATE" "BOOT" "MGR" "ADDRESS" "PORT"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"

    local found=0
    declare -A seen

    # ── 1. Managed instances (have .env) ─────────────────────────────────────
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue

        local name network port
        name="$(env_get    "$env_file" WG_NAME)"
        network="$(env_get "$env_file" WG_SERVER_IP)"
        [[ -z "$network" ]] && network="$(env_get "$env_file" WG_NETWORK)"
        port="$(env_get    "$env_file" WG_PORT)"

        [[ -z "$name" ]] && continue
        seen["$name"]=1
        found=1

        local state boot state_col mgr_col
        state="$(_iface_state "$name")"
        boot="$(_iface_boot   "$name")"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac
        mgr_col="${GREEN}yes${NC}"

        printf "  %-16s %s %s %s %-22s %s\n" \
               "$name" \
               "$(_pad_colored "$state_col" 9)" \
               "$(_pad_colored "$boot" 5)" \
               "$(_pad_colored "$mgr_col" 7)" \
               "${network:--}" \
               "${port:--}"
    done

    # ── 2. Unmanaged .conf files (no matching .env) ───────────────────────────
    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue

        local name
        name="$(basename "$conf_file" .conf)"
        [[ -n "${seen[$name]+_}" ]] && continue
        found=1

        local address port state boot state_col mgr_col
        address="$(_conf_address "$conf_file")"
        port="$(_conf_port "$conf_file")"
        state="$(_iface_state "$name")"
        boot="$(_iface_boot   "$name")"

        case "$state" in
            UP)      state_col="${GREEN}${state}${NC}" ;;
            DOWN)    state_col="${YELLOW}${state}${NC}" ;;
            STOPPED) state_col="${RED}${state}${NC}" ;;
            *)       state_col="${state}" ;;
        esac
        mgr_col="${YELLOW}no${NC}"

        printf "  %-16s %s %s %s %-22s %s\n" \
               "$name" \
               "$(_pad_colored "$state_col" 9)" \
               "$(_pad_colored "$boot" 5)" \
               "$(_pad_colored "$mgr_col" 7)" \
               "${address:--}" \
               "${port:--}"
    done

    if [[ $found -eq 0 ]]; then
        echo -e "  ${YELLOW}No WireGuard configs found in ${WG_CONFIG_DIR}.${NC}"
        echo    "  Use 'Create Server' to add one."
    else
        echo
        echo -e "  ${CYAN}MGR: ${GREEN}yes${NC}${CYAN} = managed by wg-manager  |  ${YELLOW}no${NC}${CYAN} = manual config${NC}"
    fi

    echo -e "${BOLD}══════════════════════════════════════════════════════════════════${NC}"
    pause
}