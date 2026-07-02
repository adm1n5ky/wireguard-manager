#!/usr/bin/env bash
# =============================================================================
# wg-manager.sh — WireGuard Multi-Instance Manager
# Ubuntu 24/26 LTS | v1.1
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# for module in common backend table validation network ports endpoint ip-pool \
#               config-list server-create server-delete client-create client-delete \
#               client-show status peer-monitor system menu; do
for module in common backend table validation network ports endpoint ip-pool \
               nftables \
               config-list server-create server-delete client-create client-delete \
               client-show status peer-monitor system menu; do
    lib_file="${LIB_DIR}/${module}.sh"
    if [[ ! -f "$lib_file" ]]; then
        echo "ERROR: Missing module: ${lib_file}" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$lib_file"
done

require_root
check_dependencies
main_menu