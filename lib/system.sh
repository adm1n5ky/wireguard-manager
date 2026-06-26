#!/usr/bin/env bash
# =============================================================================
# lib/system.sh — Package management, module integrity, update
# =============================================================================

REQUIRED_PACKAGES_WG=(wireguard-tools curl)
OPTIONAL_PACKAGES=(qrencode)

# Modules expected to be present in LIB_DIR
EXPECTED_MODULES=(
    common.sh
    backend.sh
    validation.sh
    network.sh
    ports.sh
    endpoint.sh
    config-list.sh
    server-create.sh
    server-delete.sh
    client-create.sh
    client-delete.sh
    ip-pool.sh
    status.sh
    peer-monitor.sh
    system.sh
    menu.sh
)

# --- Status summary (printed inside System submenu header) -------------------

_system_status_summary() {
    echo -e "  ${BOLD}Package status${NC}"
    echo "  ─────────────────────────────────"

    local pkg status_col
    for pkg in "${REQUIRED_PACKAGES_WG[@]}"; do
        if _pkg_installed "$pkg"; then
            status_col="${GREEN}installed${NC}"
        else
            status_col="${RED}MISSING${NC}"
        fi
        printf "  %-20s %b\n" "$pkg" "$status_col"
    done

    for pkg in "${OPTIONAL_PACKAGES[@]}"; do
        if _pkg_installed "$pkg"; then
            status_col="${GREEN}installed${NC}"
        else
            status_col="${YELLOW}not installed${NC}"
        fi
        printf "  %-20s %b  (optional)\n" "$pkg" "$status_col"
    done

    echo
    echo -e "  ${BOLD}Backend status${NC}"
    echo "  ─────────────────────────────────"

    local b
    for b in wg awg; do
        if command -v "$b" &>/dev/null && command -v "${b}-quick" &>/dev/null; then
            printf "  %-8s %b\n" "$b" "${GREEN}available${NC}"
        else
            printf "  %-8s %b\n" "$b" "${YELLOW}not found${NC}"
        fi
    done
}

# --- Check / install packages ------------------------------------------------

system_check_packages() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Package Check                      ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local missing_required=()
    local missing_optional=()

    for pkg in "${REQUIRED_PACKAGES_WG[@]}"; do
        _pkg_installed "$pkg" || missing_required+=("$pkg")
    done

    for pkg in "${OPTIONAL_PACKAGES[@]}"; do
        _pkg_installed "$pkg" || missing_optional+=("$pkg")
    done

    if [[ ${#missing_required[@]} -eq 0 && ${#missing_optional[@]} -eq 0 ]]; then
        ok "All packages installed."
        pause
        return 0
    fi

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        warn "Missing required: ${missing_required[*]}"
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        info "Missing optional: ${missing_optional[*]}"
    fi

    echo
    local to_install=("${missing_required[@]}")

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        read -rep "Install optional packages too? [y/N]: " opt_ans
        opt_ans="${opt_ans:-N}"
        if [[ "${opt_ans,,}" == "y" ]]; then
            to_install+=("${missing_optional[@]}")
        fi
    fi

    if [[ ${#to_install[@]} -eq 0 ]]; then
        info "Nothing to install."
        pause
        return 0
    fi

    read -rep "Install ${to_install[*]}? [Y/n]: " answer
    answer="${answer:-Y}"
    if [[ "${answer,,}" != "y" ]]; then
        info "Cancelled."
        pause
        return 0
    fi

    msg "Updating package lists..."
    apt-get update -qq

    msg "Installing: ${to_install[*]}"
    apt-get install -y "${to_install[@]}" && ok "Done." || warn "Some packages failed to install."

    pause
}

# --- Module integrity check --------------------------------------------------

system_check_modules() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Module Integrity                   ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    local missing=0

    for mod in "${EXPECTED_MODULES[@]}"; do
        local path="${LIB_DIR}/${mod}"
        if [[ -f "$path" ]]; then
            printf "  ${GREEN}[✓]${NC} %s\n" "$mod"
        else
            printf "  ${RED}[✗]${NC} %s  ${RED}MISSING${NC}\n" "$mod"
            missing=$(( missing + 1 ))
        fi
    done

    echo
    if (( missing == 0 )); then
        ok "All modules present."
    else
        warn "${missing} module(s) missing. Re-clone the repository."
    fi

    pause
}

# --- Update ------------------------------------------------------------------

system_update() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Update wg-manager                  ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    if ! command -v git &>/dev/null; then
        warn "git is not installed. Install it with: apt-get install git"
        pause
        return 0
    fi

    local repo_dir
    repo_dir="$(cd "$(dirname "${LIB_DIR}")" && pwd)"

    if [[ ! -d "${repo_dir}/.git" ]]; then
        warn "Not a git repository: ${repo_dir}"
        info "Update manually: git pull"
        pause
        return 0
    fi

    info "Repository: ${repo_dir}"
    echo

    read -rep "Pull latest changes from git? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ "${confirm,,}" != "y" ]]; then
        info "Cancelled."
        pause
        return 0
    fi

    msg "Pulling..."
    git -C "$repo_dir" pull && ok "Updated successfully." || warn "git pull failed."

    pause
}