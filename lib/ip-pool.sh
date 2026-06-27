#!/usr/bin/env bash
# =============================================================================
# lib/ip-pool.sh — IP address pool management per server instance
#
# Pool state is tracked in: ${WG_CONFIG_DIR}/server-${iface}/ip-pool.dat
# Format (one entry per line):
#   <ip>  <status>  <client_name>  <allocated_at>
#   status: free | used | server
# =============================================================================

_pool_file() {
    local iface="$1"
    local keydir
    keydir="$(env_get "$(env_path "$iface")" WG_KEY_DIR 2>/dev/null)"
    keydir="${keydir:-${WG_CONFIG_DIR}/server-${iface}}"
    echo "${keydir}/ip-pool.dat"
}

pool_init() {
    local iface="$1"
    local env_file conf_file pool_file
    env_file="$(env_path  "$iface")"
    conf_file="$(conf_path "$iface")"
    pool_file="$(_pool_file "$iface")"

    local network server_ip
    network="$(env_get "$env_file" WG_NETWORK)"
    server_ip="$(env_get "$env_file" WG_SERVER_IP)"
    server_ip="${server_ip%%/*}"

    if [[ -z "$network" ]]; then
        warn "No WG_NETWORK in ${env_file}"
        return 1
    fi

    local base prefix
    base="${network%/*}"
    prefix="${network#*/}"

    local base_int
    base_int="$(ip_to_int "$base")"

    local total_hosts=$(( (1 << (32 - prefix)) - 2 ))

    declare -A used_ips
    used_ips["$server_ip"]=server

    if [[ -f "$conf_file" ]]; then
        local client_name=""
        while IFS= read -r line; do
            if [[ "$line" =~ ^\[Peer\] ]]; then
                client_name=""
            elif [[ "$line" =~ ^#[[:space:]]Name[[:space:]]*=[[:space:]]*(.*) ]]; then
                client_name="${BASH_REMATCH[1]}"
            elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.*) ]]; then
                local ip_raw="${BASH_REMATCH[1]%%/*}"
                ip_raw="${ip_raw// /}"
                [[ -n "$ip_raw" ]] && used_ips["$ip_raw"]="${client_name:-unknown}"
            fi
        done < "$conf_file"
    fi

    local pool_dir
    pool_dir="$(dirname "$pool_file")"
    mkdir -p "$pool_dir"

    : > "$pool_file"

    local i
    for (( i = 1; i <= total_hosts; i++ )); do
        local ip
        ip="$(int_to_ip $(( base_int + i )))"
        if [[ -n "${used_ips[$ip]+_}" ]]; then
            local owner="${used_ips[$ip]}"
            if [[ "$owner" == "server" ]]; then
                printf "%s\tserver\tserver\t-\n" "$ip" >> "$pool_file"
            else
                printf "%s\tused\t%s\t-\n" "$ip" "$owner" >> "$pool_file"
            fi
        else
            printf "%s\tfree\t-\t-\n" "$ip" >> "$pool_file"
        fi
    done

    chmod 600 "$pool_file"
    ok "Pool initialised: ${total_hosts} addresses for ${iface}"
}

pool_allocate() {
    local iface="$1"
    local client_name="$2"
    local pool_file
    pool_file="$(_pool_file "$iface")"

    if [[ ! -f "$pool_file" ]]; then
        pool_init "$iface" || return 1
    fi

    local allocated_ip=""
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local tmpfile
    tmpfile="$(mktemp)"

    while IFS=$'\t' read -r ip status name ts; do
        if [[ -z "$allocated_ip" && "$status" == "free" ]]; then
            allocated_ip="$ip"
            printf "%s\tused\t%s\t%s\n" "$ip" "$client_name" "$timestamp"
        else
            printf "%s\t%s\t%s\t%s\n" "$ip" "$status" "$name" "$ts"
        fi
    done < "$pool_file" > "$tmpfile"

    if [[ -z "$allocated_ip" ]]; then
        rm -f "$tmpfile"
        warn "IP pool exhausted for ${iface}."
        return 1
    fi

    mv "$tmpfile" "$pool_file"
    chmod 600 "$pool_file"
    echo "$allocated_ip"
}

pool_release() {
    local iface="$1"
    local ip="$2"
    local pool_file
    pool_file="$(_pool_file "$iface")"

    if [[ ! -f "$pool_file" ]]; then
        warn "Pool file not found for ${iface}."
        return 1
    fi

    local tmpfile
    tmpfile="$(mktemp)"
    local found=0

    while IFS=$'\t' read -r pip status name ts; do
        if [[ "$pip" == "$ip" && "$status" == "used" ]]; then
            printf "%s\tfree\t-\t-\n" "$pip"
            found=1
        else
            printf "%s\t%s\t%s\t%s\n" "$pip" "$status" "$name" "$ts"
        fi
    done < "$pool_file" > "$tmpfile"

    if (( found == 0 )); then
        rm -f "$tmpfile"
        warn "IP ${ip} not found or not in 'used' state."
        return 1
    fi

    mv "$tmpfile" "$pool_file"
    chmod 600 "$pool_file"
    ok "Released: ${ip}"
}

pool_stats() {
    local iface="$1"
    local pool_file
    pool_file="$(_pool_file "$iface")"

    if [[ ! -f "$pool_file" ]]; then
        echo "0/0/0"
        return
    fi

    local total=0 used=0 free=0
    while IFS=$'\t' read -r ip status _rest; do
        [[ "$status" == "server" ]] && continue
        total=$(( total + 1 ))
        if [[ "$status" == "used" ]]; then
            used=$(( used + 1 ))
        else
            free=$(( free + 1 ))
        fi
    done < "$pool_file"

    echo "${total}/${used}/${free}"
}

pool_show() {
    local iface="$1"
    local pool_file
    pool_file="$(_pool_file "$iface")"

    if [[ ! -f "$pool_file" ]]; then
        warn "Pool not initialised for ${iface}. Run pool_init first."
        return 1
    fi

    echo
    printf "${BOLD}  %-18s %-8s %-20s %s${NC}\n" "IP" "STATUS" "CLIENT" "ALLOCATED AT"
    echo "  ──────────────────────────────────────────────────────────"

    while IFS=$'\t' read -r ip status name ts; do
        local status_col
        case "$status" in
            server) status_col="${CYAN}server${NC}" ;;
            used)   status_col="${YELLOW}used${NC}" ;;
            free)   status_col="${GREEN}free${NC}" ;;
            *)      status_col="$status" ;;
        esac
        printf "  %-18s %-17s %-20s %s\n" \
               "$ip" \
               "$(echo -e "$status_col")" \
               "${name:--}" \
               "${ts:--}"
    done < "$pool_file"

    echo
    local stats
    stats="$(pool_stats "$iface")"
    info "Total/Used/Free: ${BOLD}${stats}${NC}"
}
# =============================================================================
# IPv6 pool — on-demand allocation, no pre-generation
#
# File: ${keydir}/ip-pool6.dat
# Format: <ipv6>  <status>  <client_name>  <prefix_cidr>  <allocated_at>
#         status: used | server
# =============================================================================

_pool6_file() {
    local iface="$1"
    local keydir
    keydir="$(env_get "$(env_path "$iface")" WG_KEY_DIR 2>/dev/null)"
    keydir="${keydir:-${WG_CONFIG_DIR}/server-${iface}}"
    echo "${keydir}/ip-pool6.dat"
}

# Allocate next IPv6 from a specific /64 CIDR for client
# Returns: ipv6_address (without prefix)
pool6_allocate() {
    local iface="$1"
    local client_name="$2"
    local cidr="$3"          # e.g. 2001:470:7547:100::/64
    local pool_file
    pool_file="$(_pool6_file "$iface")"

    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Find last allocated IP for this cidr
    local last_ip=""
    if [[ -f "$pool_file" ]]; then
        # Check client not already allocated in this cidr
        if grep -q "$(printf '\t')${client_name}$(printf '\t')" "$pool_file" 2>/dev/null; then
            # Return existing allocation for this cidr
            local existing
            existing="$(awk -F'\t' -v c="$client_name" -v n="$cidr" \
                '$2=="used" && $3==c && $4==n {print $1}' "$pool_file")"
            if [[ -n "$existing" ]]; then
                echo "$existing"
                return 0
            fi
        fi
        # Find last IP in this cidr
        last_ip="$(awk -F'\t' -v n="$cidr" '$4==n {print $1}' "$pool_file" | tail -1)"
    fi

    # Get next available IP
    local next_ip
    next_ip="$(ipv6_next_host "$cidr" "$last_ip")"

    if [[ -z "$next_ip" ]]; then
        warn "IPv6 pool exhausted for ${cidr} on ${iface}."
        return 1
    fi

    # Append to pool file
    mkdir -p "$(dirname "$pool_file")"
    printf "%s\tused\t%s\t%s\t%s\n" \
        "$next_ip" "$client_name" "$cidr" "$timestamp" >> "$pool_file"
    chmod 600 "$pool_file"

    echo "$next_ip"
}

pool6_release() {
    local iface="$1"
    local client_name="$2"
    local pool_file
    pool_file="$(_pool6_file "$iface")"

    [[ ! -f "$pool_file" ]] && return 0

    local tmpfile
    tmpfile="$(mktemp)"
    grep -v "$(printf '\t')${client_name}$(printf '\t')" "$pool_file" > "$tmpfile" 2>/dev/null || true
    mv "$tmpfile" "$pool_file"
    chmod 600 "$pool_file"
    ok "IPv6 addresses released for: ${client_name}"
}

pool6_stats() {
    local iface="$1"
    local pool_file
    pool_file="$(_pool6_file "$iface")"

    [[ ! -f "$pool_file" ]] && { echo "0"; return; }
    grep -c $'used' "$pool_file" 2>/dev/null || echo "0"
}