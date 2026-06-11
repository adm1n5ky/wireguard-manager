#!/usr/bin/env bash
# =============================================================================
# lib/network.sh — IP math, subnet overlap detection, conflict checking
# =============================================================================

# --- IP ↔ integer conversion -------------------------------------------------

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# Convert prefix length to 32-bit mask integer
prefix_to_mask_int() {
    local prefix="$1"
    if (( prefix == 0 )); then
        echo 0
    else
        echo $(( 0xFFFFFFFF ^ ( (1 << (32 - prefix)) - 1 ) ))
    fi
}

# --- Network overlap detection -----------------------------------------------
# Returns 0 (overlap found) or 1 (no overlap)

network_overlap() {
    local net1="$1"   # e.g. 10.0.0.0/24
    local net2="$2"   # e.g. 10.0.0.128/25

    local ip1 prefix1 ip2 prefix2
    ip1="${net1%/*}";  prefix1="${net1#*/}"
    ip2="${net2%/*}";  prefix2="${net2#*/}"

    local int1 int2 mask1 mask2 base1 base2

    int1="$(ip_to_int "$ip1")"
    int2="$(ip_to_int "$ip2")"

    mask1="$(prefix_to_mask_int "$prefix1")"
    mask2="$(prefix_to_mask_int "$prefix2")"

    # Shorter mask wins (covers larger space)
    local common_mask
    if (( mask1 < mask2 )); then
        common_mask="$mask1"
    else
        common_mask="$mask2"
    fi

    base1=$(( int1 & common_mask ))
    base2=$(( int2 & common_mask ))

    if (( base1 == base2 )); then
        return 0   # overlap
    fi
    return 1       # no overlap
}

# --- Derive server IP from network CIDR --------------------------------------
# 10.100.100.0/24 → 10.100.100.1/24

network_to_server_ip() {
    local cidr="$1"
    local ip prefix
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    local int
    int="$(ip_to_int "$ip")"
    int=$(( int + 1 ))

    echo "$(int_to_ip "$int")/${prefix}"
}

# --- Check new network against all existing .env files ----------------------
# Prints the conflicting network+name if found, returns 0 on conflict.

network_conflicts() {
    local new_cidr="$1"

    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue

        local existing_net existing_name
        existing_net="$(env_get "$env_file" WG_NETWORK)"
        existing_name="$(env_get "$env_file" WG_NAME)"

        [[ -z "$existing_net" ]] && continue

        if network_overlap "$new_cidr" "$existing_net"; then
            echo "${existing_name} (${existing_net})"
            return 0
        fi
    done

    return 1
}
