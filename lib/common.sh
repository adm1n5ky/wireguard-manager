#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Logging, system utilities, dependency bootstrap
# =============================================================================

# --- Colours -----------------------------------------------------------------
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Logging -----------------------------------------------------------------

msg()  { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}[i]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*" >&2; }
die()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }

# --- Root check --------------------------------------------------------------

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

# --- Pause -------------------------------------------------------------------

pause() {
    echo
    read -rp "Press Enter to continue..." _
}

# --- Package helper ----------------------------------------------------------

_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"
}

# --- Bootstrap dependency check ----------------------------------------------

BOOTSTRAP_REQUIRED=(ipcalc curl)

check_dependencies() {
    local missing=()

    if ! command -v wg &>/dev/null && ! command -v awg &>/dev/null; then
        missing+=(wireguard-tools)
    fi

    for pkg in "${BOOTSTRAP_REQUIRED[@]}"; do
        _pkg_installed "$pkg" || missing+=("$pkg")
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        return 0
    fi

    warn "Missing packages: ${missing[*]}"
    echo
    read -rp "Install missing packages now? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ "${answer,,}" != "y" ]]; then
        die "Cannot continue without required packages."
    fi

    msg "Updating package lists..."
    apt-get update -qq

    msg "Installing: ${missing[*]}"
    apt-get install -y "${missing[@]}" || die "Failed to install packages."

    ok "Dependencies installed."
}

# --- WireGuard config paths --------------------------------------------------

WG_CONFIG_DIR="/etc/wireguard"

conf_path() { echo "${WG_CONFIG_DIR}/${1}.conf"; }
env_path()  { echo "${WG_CONFIG_DIR}/${1}.env"; }
key_dir()   { echo "${WG_CONFIG_DIR}/server-${1}"; }

# --- Read .env safely (no source!) -------------------------------------------

env_get() {
    local env_file="$1"
    local key="$2"
    grep -m1 "^${key}=" "$env_file" 2>/dev/null | cut -d= -f2- | tr -d '"'
}

# --- List all managed WG instances -------------------------------------------

list_wg_instances() {
    local instances=()
    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue
        local name
        name="$(env_get "$env_file" WG_NAME)"
        [[ -n "$name" ]] && instances+=("$name")
    done
    printf '%s\n' "${instances[@]}"
}