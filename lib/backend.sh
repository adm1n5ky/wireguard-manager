#!/usr/bin/env bash
# =============================================================================
# lib/backend.sh — WireGuard / AmneziaWG backend abstraction
# =============================================================================
#
# Usage:
#   Every call to wg / awg / wg-quick / awg-quick goes through this file.
#   Callers use:
#     backend_genkey
#     backend_pubkey
#     backend_genpsk
#     backend_show      [iface]
#     backend_up        <iface>
#     backend_down      <iface>
#     backend_enable    <iface>
#     backend_disable   <iface>
#     backend_start     <iface>
#     backend_stop      <iface>
#     backend_is_up     <iface>    → returns 0 if up
#     backend_check     <backend>  → validate + check installed
#     backend_detect                → prints "wg" or "awg" (first found)
#     backend_for_iface <iface>    → reads WG_BACKEND from .env, prints it
#
# The active backend is resolved per-interface via WG_BACKEND in .env.
# Falls back to "wg" if not set.
# =============================================================================

# --- Binary resolution -------------------------------------------------------

_backend_bin() {
    local backend="$1"   # "wg" or "awg"
    case "$backend" in
        wg)  echo "wg" ;;
        awg) echo "awg" ;;
        *)   die "Unknown backend: ${backend}" ;;
    esac
}

_quick_bin() {
    local backend="$1"
    case "$backend" in
        wg)  echo "wg-quick" ;;
        awg) echo "awg-quick" ;;
        *)   die "Unknown backend: ${backend}" ;;
    esac
}

_systemd_unit() {
    local backend="$1"
    local iface="$2"
    case "$backend" in
        wg)  echo "wg-quick@${iface}" ;;
        awg) echo "awg-quick@${iface}" ;;
        *)   die "Unknown backend: ${backend}" ;;
    esac
}

# --- Backend detection -------------------------------------------------------

backend_detect() {
    if command -v awg &>/dev/null; then
        echo "awg"
    elif command -v wg &>/dev/null; then
        echo "wg"
    else
        echo ""
    fi
}

backend_for_iface() {
    local iface="$1"
    local env_file
    env_file="$(env_path "$iface")"
    local b
    b="$(env_get "$env_file" WG_BACKEND 2>/dev/null)"
    echo "${b:-wg}"
}

# --- Installation check ------------------------------------------------------

backend_check() {
    local backend="${1:-wg}"
    local bin
    bin="$(_backend_bin "$backend")"

    if ! command -v "$bin" &>/dev/null; then
        warn "Backend '${backend}' not found (binary: ${bin})."
        return 1
    fi

    local quick
    quick="$(_quick_bin "$backend")"
    if ! command -v "$quick" &>/dev/null; then
        warn "Quick utility '${quick}' not found."
        return 1
    fi

    return 0
}

# --- Key operations ----------------------------------------------------------

backend_genkey() {
    local backend="${1:-wg}"
    "$(_backend_bin "$backend")" genkey
}

backend_pubkey() {
    local backend="${1:-wg}"
    "$(_backend_bin "$backend")" pubkey
}

backend_genpsk() {
    local backend="${1:-wg}"
    "$(_backend_bin "$backend")" genpsk
}

# --- wg show -----------------------------------------------------------------

backend_show() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    "$(_backend_bin "$backend")" show "$iface"
}

# --- Interface state ---------------------------------------------------------

backend_is_up() {
    local iface="$1"
    ip link show "$iface" &>/dev/null
}

# --- systemd control ---------------------------------------------------------

backend_enable() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    systemctl enable "$(_systemd_unit "$backend" "$iface")" &>/dev/null
}

backend_disable() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    systemctl disable "$(_systemd_unit "$backend" "$iface")" &>/dev/null
}

backend_start() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    systemctl start "$(_systemd_unit "$backend" "$iface")"
}

backend_stop() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    systemctl stop "$(_systemd_unit "$backend" "$iface")"
}

backend_is_enabled() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    systemctl is-enabled "$(_systemd_unit "$backend" "$iface")" &>/dev/null
}

# --- wg-quick / awg-quick ----------------------------------------------------

backend_up() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    "$(_quick_bin "$backend")" up "$iface"
}

backend_down() {
    local iface="$1"
    local backend
    backend="$(backend_for_iface "$iface")"
    "$(_quick_bin "$backend")" down "$iface"
}

# --- Prompt: choose backend --------------------------------------------------
# Prints chosen backend ("wg" or "awg"). Returns 1 on cancel.

prompt_backend() {
    echo
    info "Available backends:"
    local opts=()

    if command -v wg &>/dev/null && command -v wg-quick &>/dev/null; then
        opts+=("wg")
        echo "  1) WireGuard   (wg)"
    fi
    if command -v awg &>/dev/null && command -v awg-quick &>/dev/null; then
        opts+=("awg")
        echo "  ${#opts[@]}) AmneziaWG  (awg)"
    fi

    if [[ ${#opts[@]} -eq 0 ]]; then
        die "No WireGuard backend found. Install wireguard-tools or amneziawg-tools."
    fi

    if [[ ${#opts[@]} -eq 1 ]]; then
        info "Only one backend available: ${opts[0]}"
        echo "${opts[0]}"
        return 0
    fi

    local choice
    while true; do
        read -rp "Select backend [1]: " choice
        choice="${choice:-1}"
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#opts[@]} )); then
            echo "${opts[$(( choice - 1 ))]}"
            return 0
        fi
        warn "Invalid selection."
    done
}