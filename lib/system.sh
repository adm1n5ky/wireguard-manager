#!/usr/bin/env bash
# =============================================================================
# lib/system.sh — Package management, module integrity, update
# =============================================================================

REQUIRED_PACKAGES_WG=(wireguard-tools curl qrencode nftables)
OPTIONAL_PACKAGES=()

# Modules expected to be present in LIB_DIR
EXPECTED_MODULES=(
    common.sh
    backend.sh
    validation.sh
    network.sh
    ports.sh
    endpoint.sh
    nftables.sh
    config-list.sh
    server-create.sh
    server-delete.sh
    client-create.sh
    client-delete.sh
    ip-pool.sh
    status.sh
    peer-monitor.sh
    system.sh
    menu.sh
)

# --- Status summary (printed inside System submenu header) -------------------

_system_status_summary() {
    echo -e "  ${BOLD}Package status${NC}"
    echo "  ─────────────────────────────────"

    local pkg status_col
    for pkg in "${REQUIRED_PACKAGES_WG[@]}"; do
        if _pkg_installed "$pkg"; then
            status_col="${GREEN}installed${NC}"
        else
            status_col="${RED}MISSING${NC}"
        fi
        printf "  %-20s %b\n" "$pkg" "$status_col"
    done

    for pkg in "${OPTIONAL_PACKAGES[@]}"; do
        if _pkg_installed "$pkg"; then
            status_col="${GREEN}installed${NC}"
        else
            status_col="${YELLOW}not installed${NC}"
        fi
        printf "  %-20s %b  (optional)\n" "$pkg" "$status_col"
    done

    echo
    echo -e "  ${BOLD}Backend status${NC}"
    echo "  ─────────────────────────────────"

    local b
    for b in wg awg; do
        if command -v "$b" &>/dev/null && command -v "${b}-quick" &>/dev/null; then
            printf "  %-8s %b\n" "$b" "${GREEN}available${NC}"
        else
            printf "  %-8s %b\n" "$b" "${YELLOW}not found${NC}"
        fi
    done
}

# --- Check / install packages ------------------------------------------------

system_check_packages() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Package Check                      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local missing_required=()
    local missing_optional=()

    for pkg in "${REQUIRED_PACKAGES_WG[@]}"; do
        _pkg_installed "$pkg" || missing_required+=("$pkg")
    done

    for pkg in "${OPTIONAL_PACKAGES[@]}"; do
        _pkg_installed "$pkg" || missing_optional+=("$pkg")
    done

    if [[ ${#missing_required[@]} -eq 0 && ${#missing_optional[@]} -eq 0 ]]; then
        ok "All packages installed."
        pause
        return 0
    fi

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        warn "Missing required: ${missing_required[*]}"
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        info "Missing optional: ${missing_optional[*]}"
    fi

    echo
    local to_install=("${missing_required[@]}")

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        read -rep "Install optional packages too? [y/N]: " opt_ans
        opt_ans="${opt_ans:-N}"
        if [[ "${opt_ans,,}" == "y" ]]; then
            to_install+=("${missing_optional[@]}")
        fi
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        info "Nothing to install."
        pause
        return 0
    fi

    read -rep "Install ${to_install[*]}? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "${answer,,}" != "y" ]]; then
        info "Cancelled."
        pause
        return 0
    fi

    msg "Updating package lists..."
    apt-get update -qq

    msg "Installing: ${to_install[*]}"
    apt-get install -y "${to_install[@]}" && ok "Done." || warn "Some packages failed to install."

    pause
}

# --- Module integrity check --------------------------------------------------

system_check_modules() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Module Integrity                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local missing=0

    for mod in "${EXPECTED_MODULES[@]}"; do
        local path="${LIB_DIR}/${mod}"
        if [[ -f "$path" ]]; then
            printf "  ${GREEN}[✓]${NC} %s\n" "$mod"
        else
            printf "  ${RED}[✗]${NC} %s  ${RED}MISSING${NC}\n" "$mod"
            missing=$(( missing + 1 ))
        fi
    done

    echo
    if (( missing == 0 )); then
        ok "All modules present."
    else
        warn "${missing} module(s) missing. Re-clone the repository."
    fi

    pause
}

# --- Update ------------------------------------------------------------------

system_update() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Update wg-manager                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    if ! command -v git &>/dev/null; then
        warn "git is not installed. Install it with: apt-get install git"
        pause
        return 0
    fi

    local repo_dir
    repo_dir="$(cd "$(dirname "${LIB_DIR}")" && pwd)"

    if [[ ! -d "${repo_dir}/.git" ]]; then
        warn "Not a git repository: ${repo_dir}"
        info "Update manually: git pull"
        pause
        return 0
    fi

    info "Repository: ${repo_dir}"
    echo

    read -rep "Pull latest changes from git? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        info "Cancelled."
        pause
        return 0
    fi

    msg "Pulling..."
    git -C "$repo_dir" pull && ok "Updated successfully." || warn "git pull failed."

    pause
}
# =============================================================================
# IPv6 Networks — manage /etc/wireguard/ipv6-available.conf
# =============================================================================

system_ipv6_networks() {
    while true; do
        echo
        echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║   IPv6 Networks                      ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
        echo

        # ── Show current list ─────────────────────────────────────────────────
        local count
        count="$(ipv6_available_count)"

        if (( count == 0 )); then
            echo -e "  ${YELLOW}No IPv6 networks configured.${NC}"
        else
            printf "  ${BOLD}%-4s %-38s %-8s %s${NC}\n" "#" "CIDR" "TYPE" "COMMENT"
            echo "  ──────────────────────────────────────────────────────────────"
            local idx=0
            while IFS= read -r line; do
                idx=$(( idx + 1 ))
                local cidr type comment
                cidr="$(echo "$line" | awk '{print $1}')"
                type="$(echo "$line" | awk '{print $2}')"
                comment="$(echo "$line" | awk '{$1=$2=""; print substr($0,3)}')"
                local type_col
                case "$type" in
                    routed) type_col="${GREEN}routed${NC}"  ;;
                    nat66)  type_col="${YELLOW}nat66${NC}"  ;;
                    *)      type_col="$type"               ;;
                esac
                printf "  %-4s %-38s %b%b %s\n" \
                    "$idx" "$cidr" "$type_col" "$NC" "$comment"
            done < <(ipv6_read_available)
        fi

        echo
        echo "  ─────────────────────────────────"
        echo "  1) Add network"
        echo "  2) Remove network"
        echo
        echo "  0) Back"
        echo

        read -rep "  Choice: " choice
        echo

        case "$choice" in
            1) _ipv6_add_network    ;;
            2) _ipv6_remove_network ;;
            0) return 0 ;;
            *) warn "Unknown option: ${choice}"; sleep 1 ;;
        esac
    done
}

_ipv6_add_network() {
    echo
    echo -e "${CYAN}── Add IPv6 Network ──${NC}"
    echo
    echo "  Enter the CIDR of your routable IPv6 block."
    echo "  Examples: 2001:abcd:1234::/48   2a01:c001:face:cafe::/64"
    echo

    # ── CIDR input ────────────────────────────────────────────────────────────
    local _cidr
    while true; do
        read -rep "  CIDR: " _cidr
        _cidr="${_cidr// /}"
        if [[ -z "$_cidr" ]]; then
            warn "CIDR cannot be empty."
            continue
        fi
        local _err
        _err="$(validate_ipv6_cidr "$_cidr" 2>&1)"
        if [[ $? -eq 0 ]]; then
            break
        fi
        warn "$_err"
    done

    # ── Type ──────────────────────────────────────────────────────────────────
    echo
    echo "  Type:"
    echo "  1) routed — block fully routed to this server (HE /48, provider /48)"
    echo "  2) nat66  — single uplink IP, clients behind NAT"
    echo
    local _type_choice _type
    read -rep "  Type [1]: " _type_choice
    _type_choice="${_type_choice:-1}"
    case "$_type_choice" in
        2) _type="nat66"  ;;
        *) _type="routed" ;;
    esac

    # ── Comment ───────────────────────────────────────────────────────────────
    echo
    local _comment
    read -rep "  Comment (e.g. 'HE Frankfurt'): " _comment
    _comment="${_comment:-no comment}"

    # ── Check duplicate ───────────────────────────────────────────────────────
    if ipv6_read_available | grep -q "^${_cidr}[[:space:]]"; then
        warn "Network ${_cidr} already exists."
        pause
        return 0
    fi

    ipv6_available_add "$_cidr" "$_type" "$_comment"
    ok "Added: ${_cidr} (${_type}) — ${_comment}"
    pause
}

_ipv6_remove_network() {
    echo
    local count
    count="$(ipv6_available_count)"

    if (( count == 0 )); then
        warn "No networks to remove."
        pause
        return 0
    fi

    echo "  Select network to remove:"
    echo

    local -a cidrs
    local idx=0
    while IFS= read -r line; do
        idx=$(( idx + 1 ))
        local cidr type comment
        cidr="$(echo "$line" | awk '{print $1}')"
        type="$(echo "$line" | awk '{print $2}')"
        comment="$(echo "$line" | awk '{$1=$2=""; print substr($0,3)}')"
        cidrs+=("$cidr")
        printf "  %d) %-38s %-8s %s\n" "$idx" "$cidr" "$type" "$comment"
    done < <(ipv6_read_available)

    echo "  0) Cancel"
    echo

    local _sel
    while true; do
        read -rep "  Choice: " _sel
        [[ "$_sel" == "0" ]] && { info "Cancelled."; return 0; }
        if [[ "$_sel" =~ ^[0-9]+$ ]] && (( _sel >= 1 && _sel <= ${#cidrs[@]} )); then
            break
        fi
        warn "Invalid selection."
    done

    local target="${cidrs[$(( _sel - 1 ))]}"

    # Warn if used by any instance
    local used_by=()
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue
        local net6 name
        net6="$(env_get "$env_file" WG_NETWORK6 2>/dev/null)"
        name="$(env_get "$env_file" WG_NAME 2>/dev/null)"
        if [[ -n "$net6" ]] && echo "$net6" | grep -q "$target"; then
            used_by+=("$name")
        fi
    done

    if [[ ${#used_by[@]} -gt 0 ]]; then
        warn "Network ${target} is used by instance(s): ${used_by[*]}"
        warn "Removing from available list will not affect existing instances."
    fi

    read -rep "  Confirm removal of ${target}? [y/N]: " _confirm
    [[ "${_confirm,,}" != "y" ]] && { info "Cancelled."; return 0; }

    ipv6_available_remove "$target"
    ok "Removed: ${target}"
    pause
}
# =============================================================================
# Nftables Rules — show persistent-config location + generated allow block
#
# wg-manager never edits a foreign nftables config file automatically (see
# lib/nftables.sh header for the full rationale). This screen is the "System"
# side of that decision: it tells the admin exactly where their real config
# lives and gives them a ready-to-paste block, generated from the instances
# that are actually running right now, so they never have to write it by
# hand from scratch.
# =============================================================================

system_nftables_rules() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Nftables Rules                     ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    if ! nft_available; then
        warn "nft (nftables) is not installed."
        pause
        return 0
    fi

    local main_conf
    main_conf="$(nft_main_conf_from_service)"
    main_conf="${main_conf:-$NFT_MAIN_CONF}"

    info "Persistent nftables config (resolved from nftables.service ExecStart):"
    echo "    ${main_conf}"
    echo

    local foreign
    foreign="$(nft_foreign_drop_chains)"

    if [[ -z "$foreign" ]]; then
        ok "No foreign default-drop input chain detected."
        echo "  wg-manager's own per-instance tables (wg_manager_<iface>) are"
        echo "  additive, self-contained, and persisted automatically via:"
        echo "    ${NFT_FRAG_DIR}/*.conf  (included from ${main_conf})"
        echo "  There is nothing that needs manual persistence right now."
        pause
        return 0
    fi

    echo -e "  ${YELLOW}Default-drop firewall chain(s) detected outside wg-manager:${NC}"
    echo
    while IFS=$'\t' read -r family table chain hook; do
        [[ -z "$table" ]] && continue
        echo "    ${family} table '${table}', chain '${chain}' (${hook}) — policy drop"
    done <<< "$foreign"
    echo
    echo "  wg-manager never edits this file automatically — it is yours to"
    echo "  maintain. Paste the lines below manually inside the matching chain's"
    echo "  '{ ... }' body in ${main_conf} (or wherever it is actually defined,"
    echo "  if split across includes). One line per managed instance that is"
    echo "  currently UP, grouped by which hook needs it:"
    echo

    local instances
    mapfile -t instances < <(list_wg_instances)

    local has_input=0 has_forward=0
    while IFS=$'\t' read -r _f _t _c hook; do
        [[ "$hook" == "input"   ]] && has_input=1
        [[ "$hook" == "forward" ]] && has_forward=1
    done <<< "$foreign"

    local name any_up

    if (( has_input )); then
        echo "  For the 'input' chain (opens the UDP port itself):"
        echo "  ────────────────────────────────────────────────────────────"
        any_up=0
        for name in "${instances[@]}"; do
            [[ "$(_iface_state "$name")" == "UP" ]] || continue
            local port
            port="$(env_get "$(env_path "$name")" WG_PORT)"
            [[ -z "$port" ]] && continue
            any_up=1
            echo "        udp dport ${port} accept comment \"wg-manager: ${name}\""
        done
        (( any_up == 0 )) && echo "        (no managed instances are currently UP)"
        echo "  ────────────────────────────────────────────────────────────"
        echo
    fi

    if (( has_forward )); then
        echo "  For the 'forward' chain (lets client traffic reach the internet):"
        echo "  ────────────────────────────────────────────────────────────"
        any_up=0
        for name in "${instances[@]}"; do
            [[ "$(_iface_state "$name")" == "UP" ]] || continue
            local ext_if
            ext_if="$(env_get "$(env_path "$name")" WG_EXT_IFACE)"
            [[ -z "$ext_if" ]] && ext_if="$(nft_detect_ext_iface)"
            [[ -z "$ext_if" ]] && continue
            any_up=1
            echo "        iifname \"${name}\" oifname \"${ext_if}\" accept comment \"wg-manager: ${name}\""
        done
        (( any_up == 0 )) && echo "        (no managed instances are currently UP)"
        echo "  ────────────────────────────────────────────────────────────"
        echo "  Assumes that chain already has a generic 'ct state"
        echo "  established,related accept' rule for return traffic — check"
        echo "  that it does, or add it alongside the lines above if not."
        echo
    fi

    info "After editing manually, apply with:"
    echo "    nft -c -f ${main_conf}   # check first — will not touch the live ruleset"
    echo "    systemctl reload-or-restart nftables"
    echo
    info "Rules added live via the 'Start interface' confirmation prompt do"
    info "NOT survive the reload above unless pasted into the file first."

    pause
}