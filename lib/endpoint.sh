#!/usr/bin/env bash
# =============================================================================
# lib/endpoint.sh — Public IP/endpoint detection and prompting
# =============================================================================

IPIFY_URL="https://api.ipify.org"
CURL_TIMEOUT=5

# --- Detect public IPv4 ------------------------------------------------------

detect_public_ip() {
    local ip
    ip="$(curl -4 -s --max-time "${CURL_TIMEOUT}" "${IPIFY_URL}" 2>/dev/null)"

    # Basic sanity check: looks like an IPv4?
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "$ip"
        return 0
    fi

    return 1
}

# --- Validate endpoint (IP or hostname) --------------------------------------

validate_endpoint() {
    local ep="$1"

    # Remove port if provided (host:port)
    local host="${ep%%:*}"

    # Could be IPv4
    if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 0
    fi

    # Could be a hostname / domain
    if [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]]; then
        return 0
    fi

    echo "Not a valid IP address or hostname."
    return 1
}

# --- Prompt for endpoint -----------------------------------------------------

prompt_endpoint() {
    local detected

    echo
    info "Detecting public IP address..."

    local suggested=""
    if detected="$(detect_public_ip)"; then
        suggested="$detected"
        info "Detected public IP: ${BOLD}${detected}${NC}"
    else
        warn "Could not auto-detect public IP. Please enter manually."
    fi

    local endpoint err

    while true; do
        if [[ -n "$suggested" ]]; then
            read -rp "Endpoint (IP or domain) [${suggested}]: " endpoint
            endpoint="${endpoint:-$suggested}"
        else
            read -rp "Endpoint (IP or domain, required): " endpoint
        fi

        endpoint="${endpoint// /}"

        if [[ -z "$endpoint" ]]; then
            warn "Endpoint cannot be empty."
            continue
        fi

        err="$(validate_endpoint "$endpoint")"
        if [[ $? -eq 0 ]]; then
            echo "$endpoint"
            return 0
        fi
        warn "$err"
    done
}
