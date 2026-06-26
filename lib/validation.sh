#!/usr/bin/env bash
# =============================================================================
# lib/validation.sh — Input validation: interface names, CIDR, ports
# =============================================================================

validate_iface_name() {
    local name="$1"

    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Interface name may only contain letters, digits, underscores and hyphens."
        return 1
    fi

    if (( ${#name} > 15 )); then
        echo "Interface name must be 15 characters or fewer (got ${#name})."
        return 1
    fi

    if ip link show "$name" &>/dev/null; then
        echo "Interface '${name}' already exists in the system."
        return 1
    fi

    if [[ -f "$(conf_path "$name")" ]]; then
        echo "Config file $(conf_path "$name") already exists."
        return 1
    fi

    if [[ -f "$(env_path "$name")" ]]; then
        echo "Env file $(env_path "$name") already exists."
        return 1
    fi

    return 0
}

# Usage: prompt_iface_name VARNAME
prompt_iface_name() {
    local -n _pif_out=$1
    local name err

    while true; do
        read -rep "Interface name (e.g. wg100): " name
        name="${name// /}"

        if [[ -z "$name" ]]; then
            warn "Interface name cannot be empty."
            continue
        fi

        err="$(validate_iface_name "$name")"
        if [[ $? -eq 0 ]]; then
            _pif_out="$name"
            return 0
        fi
        warn "$err"
    done
}

validate_cidr() {
    local cidr="$1"

    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Not a valid CIDR format (expected a.b.c.d/prefix)."
        return 1
    fi

    local ip prefix
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    local IFS='.'
    read -ra octets <<< "$ip"
    for oct in "${octets[@]}"; do
        if (( oct > 255 )); then
            echo "Invalid IP octet: ${oct}."
            return 1
        fi
    done
    unset IFS

    if (( prefix < 1 || prefix > 30 )); then
        echo "Prefix must be between /1 and /30 (got /${prefix})."
        return 1
    fi

    if [[ "$ip" == "0.0.0.0" && "$prefix" == "0" ]]; then
        echo "0.0.0.0/0 is not allowed."
        return 1
    fi

    local ip_int mask_int
    ip_int="$(ip_to_int "$ip")"
    mask_int="$(prefix_to_mask_int "$prefix")"
    local host_bits=$(( ip_int & ~mask_int ))
    if (( host_bits != 0 )); then
        local network_ip
        network_ip="$(int_to_ip $(( ip_int & mask_int )))"
        echo "Address is a host address, not a network address. Did you mean ${network_ip}/${prefix}?"
        return 1
    fi

    return 0
}

# Usage: prompt_cidr VARNAME
prompt_cidr() {
    local -n _pc_out=$1
    local cidr err

    while true; do
        read -rep "Network CIDR (e.g. 10.100.100.0/24): " cidr
        cidr="${cidr// /}"

        if [[ -z "$cidr" ]]; then
            warn "Network CIDR cannot be empty."
            continue
        fi

        err="$(validate_cidr "$cidr")"
        if [[ $? -eq 0 ]]; then
            _pc_out="$cidr"
            return 0
        fi
        warn "$err"
    done
}

validate_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "Port must be a number."
        return 1
    fi

    if (( port < 1 || port > 65535 )); then
        echo "Port must be between 1 and 65535."
        return 1
    fi

    return 0
}

validate_mtu() {
    local mtu="$1"

    if [[ ! "$mtu" =~ ^[0-9]+$ ]]; then
        echo "MTU must be a number."
        return 1
    fi

    if (( mtu < 576 || mtu > 9000 )); then
        echo "MTU must be between 576 and 9000."
        return 1
    fi

    return 0
}