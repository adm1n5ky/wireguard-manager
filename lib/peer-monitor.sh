#!/usr/bin/env bash
# =============================================================================
# lib/peer-monitor.sh — Realtime WireGuard peer dashboard
# Refreshes in-place every 2s via tput, no flicker.
# Exit: q / Q / Ctrl+C
# =============================================================================

MONITOR_INTERVAL=2

# --- Resolve client name by public key ---------------------------------------
# Scans server .conf for "# Name = ..." line before matching [Peer] PublicKey

_peer_name_by_key() {
    local conf_file="$1"
    local pubkey="$2"

    local cur_name=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^#[[:space:]]Name[[:space:]]*=[[:space:]]*(.*) ]]; then
            cur_name="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.*) ]]; then
            local key="${BASH_REMATCH[1]// /}"
            if [[ "$key" == "$pubkey" ]]; then
                echo "${cur_name:-unknown}"
                return 0
            fi
            cur_name=""
        fi
    done < "$conf_file"

    echo "unknown"
}

# --- Human-readable handshake age --------------------------------------------

_fmt_handshake() {
    local ts="$1"
    local now
    now="$(date +%s)"

    if [[ "$ts" == "0" || -z "$ts" ]]; then
        echo "never"
        return
    fi

    local age=$(( now - ts ))

    if   (( age < 60 ));   then echo "${age}s ago"
    elif (( age < 3600 )); then echo "$(( age / 60 ))m ago"
    elif (( age < 86400 )); then echo "$(( age / 3600 ))h ago"
    else                        echo "$(( age / 86400 ))d ago"
    fi
}

# --- Human-readable bytes ----------------------------------------------------

_fmt_bytes() {
    local b="$1"
    if   (( b < 1024 ));         then printf "%d B"    "$b"
    elif (( b < 1048576 ));      then printf "%.1f KiB" "$(echo "scale=1; $b/1024"     | bc)"
    elif (( b < 1073741824 ));   then printf "%.1f MiB" "$(echo "scale=1; $b/1048576"  | bc)"
    else                              printf "%.1f GiB" "$(echo "scale=1; $b/1073741824" | bc)"
    fi
}

# --- Status dot + label ------------------------------------------------------
# ACTIVE  < 3 min   green  ●
# IDLE    < 15 min  yellow ●
# STALE   >= 15min  red    ●
# NEVER            grey   ○

_peer_status() {
    local ts="$1"
    local now
    now="$(date +%s)"

    if [[ "$ts" == "0" || -z "$ts" ]]; then
        echo "NEVER"
        return
    fi

    local age=$(( now - ts ))
    if   (( age < 180 ));  then echo "ACTIVE"
    elif (( age < 900 ));  then echo "IDLE"
    else                        echo "STALE"
    fi
}

_status_colour() {
    case "$1" in
        ACTIVE) echo "${GREEN}" ;;
        IDLE)   echo "${YELLOW}" ;;
        STALE)  echo "${RED}" ;;
        NEVER)  echo "${BOLD}" ;;  # grey-ish via dim bold
        *)      echo "${NC}" ;;
    esac
}

_status_dot() {
    case "$1" in
        NEVER) echo "○" ;;
        *)     echo "●" ;;
    esac
}

# --- Render one full table frame ---------------------------------------------

_render_peer_table() {
    local iface="$1"
    local conf_file
    conf_file="$(conf_path "$iface")"

    local backend
    backend="$(backend_for_iface "$iface")"
    local bin
    bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"

    local now_fmt
    now_fmt="$(date "+%Y-%m-%d %H:%M:%S")"

    # ── Header ───────────────────────────────────────────────────────────────
    local iface_state
    iface_state="$(_iface_state "$iface")"

    local state_col
    case "$iface_state" in
        UP)      state_col="${GREEN}${iface_state}${NC}" ;;
        DOWN)    state_col="${YELLOW}${iface_state}${NC}" ;;
        STOPPED) state_col="${RED}${iface_state}${NC}" ;;
        *)       state_col="${iface_state}" ;;
    esac

    echo -e "${BOLD}${CYAN}"
    echo    "  ╔══════════════════════════════════════════════════════════════════╗"
    printf  "  ║  Peer Monitor — %-10s  [%b%-7s${BOLD}${CYAN}]  %31s  ║\n" \
            "$iface" "$state_col" "" "$now_fmt"
    echo    "  ╚══════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # ── Check interface is up -------------------------------------------------
    if ! backend_is_up "$iface" 2>/dev/null; then
        echo -e "  ${YELLOW}Interface is not up — no live data available.${NC}"
        echo
        echo -e "  ${BOLD}Press [q] to quit${NC}"
        return
    fi

    # ── Collect wg show data --------------------------------------------------
    local peers_raw endpoints_raw handshakes_raw transfer_raw
    peers_raw="$(      "$bin" show "$iface" peers             2>/dev/null)"
    endpoints_raw="$(  "$bin" show "$iface" endpoints         2>/dev/null)"
    handshakes_raw="$( "$bin" show "$iface" latest-handshakes 2>/dev/null)"
    transfer_raw="$(   "$bin" show "$iface" transfer          2>/dev/null)"

    if [[ -z "$peers_raw" ]]; then
        echo -e "  ${YELLOW}No peers configured on ${iface}.${NC}"
        echo
        echo -e "  ${BOLD}Press [q] to quit${NC}"
        return
    fi

    # ── Table header ─────────────────────────────────────────────────────────
    printf "  ${BOLD}%-3s  %-20s  %-21s  %-10s  %-10s  %-10s  %s${NC}\n" \
           " " "NAME" "ENDPOINT" "LAST SEEN" "↓ RX" "↑ TX" "STATUS"
    echo   "  ──────────────────────────────────────────────────────────────────────────"

    # ── Rows ─────────────────────────────────────────────────────────────────
    local idx=0
    while IFS= read -r pubkey; do
        [[ -z "$pubkey" ]] && continue
        idx=$(( idx + 1 ))

        # Name from .conf
        local name="unknown"
        [[ -f "$conf_file" ]] && name="$(_peer_name_by_key "$conf_file" "$pubkey")"

        # Endpoint
        local endpoint
        endpoint="$(echo "$endpoints_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        endpoint="${endpoint:-(none)}"

        # Handshake timestamp
        local hs_ts
        hs_ts="$(echo "$handshakes_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        hs_ts="${hs_ts:-0}"

        local last_seen
        last_seen="$(_fmt_handshake "$hs_ts")"

        # Transfer
        local rx_b tx_b rx_fmt tx_fmt
        rx_b="$(echo "$transfer_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        tx_b="$(echo "$transfer_raw" | awk -v k="$pubkey" '$1==k{print $3}')"
        rx_b="${rx_b:-0}"
        tx_b="${tx_b:-0}"
        rx_fmt="$(_fmt_bytes "$rx_b")"
        tx_fmt="$(_fmt_bytes "$tx_b")"

        # Status
        local status dot col
        status="$(_peer_status "$hs_ts")"
        dot="$(_status_dot "$status")"
        col="$(_status_colour "$status")"

        printf "  ${BOLD}%3d${NC}  %-20s  %-21s  %-10s  %-10s  %-10s  %b%s %s${NC}\n" \
               "$idx" \
               "${name:0:20}" \
               "${endpoint:0:21}" \
               "$last_seen" \
               "$rx_fmt" \
               "$tx_fmt" \
               "$col" "$dot" "$status"

    done <<< "$peers_raw"

    # ── Footer ───────────────────────────────────────────────────────────────
    echo   "  ──────────────────────────────────────────────────────────────────────────"

    local stats
    stats="$(pool_stats "$iface" 2>/dev/null || echo "-")"
    printf "  ${CYAN}Pool (total/used/free): ${BOLD}%s${NC}   " "$stats"

    local active_count
    active_count="$(echo "$handshakes_raw" | awk -v now="$(date +%s)" \
        '$2>0 && (now-$2)<180 {c++} END{print c+0}')"
    printf "${GREEN}● ACTIVE: %d${NC}   " "$active_count"

    local idle_count
    idle_count="$(echo "$handshakes_raw" | awk -v now="$(date +%s)" \
        '$2>0 && (now-$2)>=180 && (now-$2)<900 {c++} END{print c+0}')"
    printf "${YELLOW}● IDLE: %d${NC}   " "$idle_count"

    local stale_count
    stale_count="$(echo "$handshakes_raw" | awk -v now="$(date +%s)" \
        '($2==0 || (now-$2)>=900) {c++} END{print c+0}')"
    printf "${RED}● STALE/NEVER: %d${NC}\n" "$stale_count"

    echo
    echo -e "  ${BOLD}Auto-refresh: ${MONITOR_INTERVAL}s   Press [q] to quit${NC}"
}

# --- Main entrypoint ---------------------------------------------------------

peer_monitor() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Peer Monitor                       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Pick instance ────────────────────────────────────────────────────────
    local instances
    mapfile -t instances < <(list_wg_instances)

    if [[ ${#instances[@]} -eq 0 ]]; then
        warn "No managed instances found."
        pause
        return 0
    fi

    local iface

    if [[ ${#instances[@]} -eq 1 ]]; then
        iface="${instances[0]}"
    else
        local i
        for i in "${!instances[@]}"; do
            local name="${instances[$i]}"
            local state
            state="$(_iface_state "$name")"
            printf "  %d) %-15s [%s]\n" $(( i + 1 )) "$name" "$state"
        done
        echo "  0) Cancel"
        echo

        local choice
        while true; do
            read -rp "  Select instance: " choice
            [[ "$choice" == "0" ]] && return 0
            if [[ "$choice" =~ ^[0-9]+$ ]] && \
               (( choice >= 1 && choice <= ${#instances[@]} )); then
                iface="${instances[$(( choice - 1 ))]}"
                break
            fi
            warn "Invalid selection."
        done
    fi

    # ── Realtime loop ────────────────────────────────────────────────────────
    tput civis 2>/dev/null          # скрыть курсор

    _monitor_cleanup() {
        tput cnorm 2>/dev/null      # вернуть курсор
        echo
        info "Peer Monitor closed."
    }
    trap '_monitor_cleanup; return 0' INT TERM

    while true; do
        clear
        _render_peer_table "$iface"

        # Ждём нажатия до MONITOR_INTERVAL секунд
        if read -r -s -n 1 -t "$MONITOR_INTERVAL" key 2>/dev/null; then
            if [[ "${key,,}" == "q" ]]; then
                break
            fi
        fi
    done

    trap - INT TERM
    _monitor_cleanup
}