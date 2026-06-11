#!/usr/bin/env bash
# =============================================================================
# lib/validation.sh — Input validation: interface names, CIDR, ports
# =============================================================================

# --- Interface name ----------------------------------------------------------
# Rules: [a-zA-Z0-9_-], max 15 chars, must not already exist in system or /etc/wireguard

validate_iface_name() {
    local name="$1"

    # Character set
    if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        echo "Interface name may only contain letters, digits, underscores and hyphens."
        return 1
    fi

    # Length
    if (( ${#name} > 15 )); then
        echo "Interface name must be 15 characters or fewer (got ${#name})."
        return 1
    fi

    # Not already a live network interface
    if ip link show "$name" &>/dev/null; then
        echo "Interface '${name}' already exists in the system."
        return 1
    fi

    # No existing .conf
    if [[ -f "$(conf_path "$name")" ]]; then
        echo "Config file $(conf_path "$name") already exists."
        return 1
    fi

    # No existing .env
    if [[ -f "$(env_path "$name")" ]]; then
        echo "Env file $(env_path "$name") already exists."
        return 1
    fi

    return 0
}

prompt_iface_name() {
    local name err

    while true; do
        read -rp "Interface name (e.g. wg100): " name
        name="${name// /}"      # strip spaces

        if [[ -z "$name" ]]; then
            warn "Interface name cannot be empty."
            continue
        fi

        err="$(validate_iface_name "$name")"
        if [[ $? -eq 0 ]]; then
            echo "$name"
            return 0
        fi
        warn "$err"
    done
}

# --- CIDR validation ---------------------------------------------------------

# Checks that a string is a valid IPv4 CIDR and not a forbidden range.
# Uses ipcalc if available, otherwise pure-bash checks.
validate_cidr() {
    local cidr="$1"

    # Basic format: x.x.x.x/n
    if [[ ! "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "Not a valid CIDR format (expected a.b.c.d/prefix)."
        return 1
    fi

    local ip prefix
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    # Octet range
    local IFS='.'
    read -ra octets <<< "$ip"
    for oct in "${octets[@]}"; do
        if (( oct > 255 )); then
            echo "Invalid IP octet: ${oct}."
            return 1
        fi
    done
    unset IFS

    # Prefix range
    if (( prefix < 1 || prefix > 30 )); then
        echo "Prefix must be between /1 and /30 (got /${prefix})."
        return 1
    fi

    # Forbidden: 0.0.0.0/0
    if [[ "$ip" == "0.0.0.0" && "$prefix" == "0" ]]; then
        echo "0.0.0.0/0 is not allowed."
        return 1
    fi

    # Forbidden: /31 /32 (already caught above, but explicit)
    if (( prefix >= 31 )); then
        echo "Prefix /${prefix} is too small for a WireGuard network."
        return 1
    fi

    # Validate network address is actually the base (host bits = 0)
    if command -v ipcalc &>/dev/null; then
        local network
        network="$(ipcalc -n "$cidr" 2>/dev/null | grep -i '^Network:' | awk '{print $2}')"
        if [[ -n "$network" && "$network" != "$cidr" ]]; then
            echo "Address is a host address, not a network address. Did you mean ${network}?"
            return 1
        fi
    fi

    return 0
}

prompt_cidr() {
    local cidr err

    while true; do
        read -rp "Network CIDR (e.g. 10.100.100.0/24): " cidr
        cidr="${cidr// /}"

        if [[ -z "$cidr" ]]; then
            warn "Network CIDR cannot be empty."
            continue
        fi

        err="$(validate_cidr "$cidr")"
        if [[ $? -eq 0 ]]; then
            echo "$cidr"
            return 0
        fi
        warn "$err"
    done
}

# --- Port validation ---------------------------------------------------------

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

# --- MTU validation ----------------------------------------------------------

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
