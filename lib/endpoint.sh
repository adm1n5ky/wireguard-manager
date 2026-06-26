#!/usr/bin/env bash
# =============================================================================
# lib/endpoint.sh — Public IP/endpoint detection and prompting
# =============================================================================

IPIFY_URL="https://api.ipify.org"
CURL_TIMEOUT=5

detect_public_ip() {
    local ip
    ip="$(curl -4 -s --max-time "${CURL_TIMEOUT}" "${IPIFY_URL}" 2>/dev/null)"

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi

    return 1
}

validate_endpoint() {
    local ep="$1"
    local host="${ep%%:*}"

    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    if [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi

    echo "Not a valid IP address or hostname."
    return 1
}

# Usage: prompt_endpoint VARNAME
prompt_endpoint() {
    local -n _pe_out=$1

    echo
    info "Detecting public IP address..."

    local suggested=""
    local detected
    if detected="$(detect_public_ip)"; then
        suggested="$detected"
        info "Detected public IP: ${BOLD}${detected}${NC}"
    else
        warn "Could not auto-detect public IP. Please enter manually."
    fi

    local _ep_val _ep_err

    while true; do
        if [[ -n "$suggested" ]]; then
            read -rep "Endpoint (IP or domain) [${suggested}]: " _ep_val
            _ep_val="${_ep_val:-$suggested}"
        else
            read -rep "Endpoint (IP or domain, required): " _ep_val
        fi

        _ep_val="${_ep_val// /}"

        if [[ -z "$_ep_val" ]]; then
            warn "Endpoint cannot be empty."
            continue
        fi

        _ep_err="$(validate_endpoint "$_ep_val")"
        if [[ $? -eq 0 ]]; then
            _pe_out="$_ep_val"
            return 0
        fi
        warn "$_ep_err"
    done
}