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