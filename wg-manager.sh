#!/usr/bin/env bash
# =============================================================================
# wg-manager.sh — WireGuard Multi-Instance Manager
# Ubuntu 24/26 LTS | v1.0
# =============================================================================
# set -euo pipefail intentionally disabled:
# interactive scripts use non-zero returns as normal control flow
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/lib"

# Load all modules
for module in common validation network ports endpoint \
              config-list server-create server-delete status menu; do
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
