#!/usr/bin/env bash
# =============================================================================
# lib/ports.sh — Port conflict detection and auto-allocation
# =============================================================================

DEFAULT_PORT=51820
PORT_SCAN_MAX=100   # how many ports to try before giving up

# --- Runtime check via ss ----------------------------------------------------

port_used_runtime() {
    local port="$1"
    # Check UDP (WireGuard uses UDP)
    ss -lnup 2>/dev/null | awk '{print $5}' | grep -q ":${port}$"
}

# --- Config-file check -------------------------------------------------------

port_used_configs() {
    local port="$1"

    for conf_file in "${WG_CONFIG_DIR}"/*.conf; do
        [[ -f "$conf_file" ]] || continue
        if grep -qE "^ListenPort\s*=\s*${port}\s*$" "$conf_file"; then
            return 0
        fi
    done
    return 1
}

# --- Combined check ----------------------------------------------------------

port_in_use() {
    local port="$1"
    port_used_runtime "$port" || port_used_configs "$port"
}

# --- Find next free port -----------------------------------------------------

find_free_port() {
    local start="${1:-$DEFAULT_PORT}"
    local port="$start"

    for (( i = 0; i < PORT_SCAN_MAX; i++ )); do
        if ! port_in_use "$port"; then
            echo "$port"
            return 0
        fi
        port=$(( port + 1 ))
    done

    # Nothing found in range
    return 1
}

# --- Prompt for port with auto-suggestion ------------------------------------

prompt_port() {
    local suggested
    suggested="$(find_free_port "$DEFAULT_PORT")" || suggested="$DEFAULT_PORT"

    info "Scanning for available UDP ports..." >&2

    local port err

    while true; do
        echo
        read -rp "Listen port [${suggested}]: " port
        port="${port:-$suggested}"

        err="$(validate_port "$port")"
        if [[ $? -ne 0 ]]; then
            warn "$err"
            continue
        fi

        if port_used_runtime "$port"; then
            warn "Port ${port}/udp is currently in use (ss)."
            continue
        fi

        if port_used_configs "$port"; then
            warn "Port ${port} is already used in another WireGuard config."
            continue
        fi

        echo "$port"
        return 0
    done
}
