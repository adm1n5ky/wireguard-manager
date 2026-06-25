#!/usr/bin/env bash
# =============================================================================
# lib/peer-monitor.sh — Realtime WireGuard peer dashboard
# Основной буфер, tput cup 0 0 без clear — нет моргания.
# Выход: q / Q / Ctrl+C
# =============================================================================

MONITOR_INTERVAL=2

# --- Resolve client name by public key ---------------------------------------

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
    if   (( age < 60 ));    then echo "${age}s ago"
    elif (( age < 3600 ));  then echo "$(( age / 60 ))m ago"
    elif (( age < 86400 )); then echo "$(( age / 3600 ))h ago"
    else                         echo "$(( age / 86400 ))d ago"
    fi
}

# --- Human-readable bytes (целочисленная арифметика, без bc) -----------------

_fmt_bytes() {
    local b="$1"
    if   (( b < 1024 ));       then
        printf "%d B" "$b"
    elif (( b < 1048576 ));    then
        local k=$(( b * 10 / 1024 ))
        printf "%d.%d KiB" $(( k / 10 )) $(( k % 10 ))
    elif (( b < 1073741824 )); then
        local m=$(( b * 10 / 1048576 ))
        printf "%d.%d MiB" $(( m / 10 )) $(( m % 10 ))
    else
        local g=$(( b * 10 / 1073741824 ))
        printf "%d.%d GiB" $(( g / 10 )) $(( g % 10 ))
    fi
}

# --- Статус пира -------------------------------------------------------------

_peer_status() {
    local ts="$1"
    local now
    now="$(date +%s)"

    if [[ "$ts" == "0" || -z "$ts" ]]; then
        echo "NEVER"; return
    fi

    local age=$(( now - ts ))
    if   (( age < 180 )); then echo "ACTIVE"
    elif (( age < 900 )); then echo "IDLE"
    else                       echo "STALE"
    fi
}

# --- Цвет и символ статуса ---------------------------------------------------

_status_colour() {
    case "$1" in
        ACTIVE) printf '%s' "$GREEN"  ;;
        IDLE)   printf '%s' "$YELLOW" ;;
        STALE)  printf '%s' "$RED"    ;;
        NEVER)  printf '%s' "$NC"     ;;
        *)      printf '%s' "$NC"     ;;
    esac
}

_status_dot() {
    case "$1" in
        NEVER) echo "○" ;;
        *)     echo "●" ;;
    esac
}

# --- Ширина терминала --------------------------------------------------------

_term_cols() {
    tput cols 2>/dev/null || echo 80
}

# --- Рендер одного фрейма ----------------------------------------------------

_render_peer_table() {
    local iface="$1"
    local conf_file
    conf_file="$(conf_path "$iface")"

    local backend bin
    backend="$(backend_for_iface "$iface")"
    bin="$( [[ "$backend" == "awg" ]] && echo "awg" || echo "wg" )"

    local now_fmt
    now_fmt="$(date "+%Y-%m-%d %H:%M:%S")"

    # ── Заголовок ─────────────────────────────────────────────────────────────
    local iface_state
    iface_state="$(_iface_state "$iface")"

    local state_label state_col
    case "$iface_state" in
        UP)      state_label="UP"      ; state_col="$GREEN"  ;;
        DOWN)    state_label="DOWN"    ; state_col="$YELLOW" ;;
        STOPPED) state_label="STOPPED" ; state_col="$RED"    ;;
        *)       state_label="$iface_state" ; state_col="$NC" ;;
    esac

    # Рамка фиксированной ширины 72 символа (без пробелов слева)
    local W=72
    local border
    printf -v border '%*s' "$W" '' ; border="${border// /═}"

    echo -e "${BOLD}${CYAN}  ╔${border}╗${NC}"

    # Строка заголовка без ANSI в printf-ширинах — собираем вручную
    local title="Peer Monitor — ${iface}"
    local state_plain="[${state_label}]"
    # Паддинг между title и datetime: W-2 (внутренняя ширина) - длины строк - разделители
    local inner=$(( W - 2 ))
    local left="${title}  ${state_plain}"
    local right="${now_fmt}"
    local pad=$(( inner - ${#left} - ${#right} ))
    (( pad < 1 )) && pad=1
    local spaces
    printf -v spaces '%*s' "$pad" ''

    printf "  ${BOLD}${CYAN}║${NC} ${BOLD}%s${NC}  ${state_col}%s${NC}%s${CYAN}%s${NC}  ${BOLD}${CYAN}║${NC}\n" \
           "$title" "$state_plain" "$spaces" "$right"

    echo -e "${BOLD}${CYAN}  ╚${border}╝${NC}"
    echo

    # ── Интерфейс не поднят ───────────────────────────────────────────────────
    if ! backend_is_up "$iface" 2>/dev/null; then
        echo -e "  ${YELLOW}Interface is not up — no live data available.${NC}"
        echo
        echo -e "  ${BOLD}[q]${NC} quit"
        # Затираем остаток экрана
        tput ed 2>/dev/null
        return
    fi

    # ── Данные wg show ────────────────────────────────────────────────────────
    local peers_raw endpoints_raw handshakes_raw transfer_raw
    peers_raw="$(      "$bin" show "$iface" peers             2>/dev/null)"
    endpoints_raw="$(  "$bin" show "$iface" endpoints         2>/dev/null)"
    handshakes_raw="$( "$bin" show "$iface" latest-handshakes 2>/dev/null)"
    transfer_raw="$(   "$bin" show "$iface" transfer          2>/dev/null)"

    if [[ -z "$peers_raw" ]]; then
        echo -e "  ${YELLOW}No peers configured on ${iface}.${NC}"
        echo
        echo -e "  ${BOLD}[q]${NC} quit"
        tput ed 2>/dev/null
        return
    fi

    # ── Заголовок таблицы ─────────────────────────────────────────────────────
    # Колонки: №(3) NAME(20) ENDPOINT(25) LAST SEEN(11) RX(11) TX(11) STATUS(10)
    printf "  ${BOLD}%-3s  %-20s  %-25s  %-16s  %-16s  %-16s  %-10s${NC}\n" \
           "#" "NAME" "ENDPOINT" "LAST SEEN" "↓ RX" "↑ TX" "STATUS"
    echo   "  ────────────────────────────────────────────────────────────────────────────────"

    # ── Строки ────────────────────────────────────────────────────────────────
    local idx=0
    local active_count=0 idle_count=0 stale_count=0

    while IFS= read -r pubkey; do
        [[ -z "$pubkey" ]] && continue
        idx=$(( idx + 1 ))

        local name="unknown"
        [[ -f "$conf_file" ]] && name="$(_peer_name_by_key "$conf_file" "$pubkey")"

        local endpoint
        endpoint="$(echo "$endpoints_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        endpoint="${endpoint:-(none)}"

        local hs_ts
        hs_ts="$(echo "$handshakes_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        hs_ts="${hs_ts:-0}"

        local last_seen
        last_seen="$(_fmt_handshake "$hs_ts")"

        local rx_b tx_b rx_fmt tx_fmt
        rx_b="$(echo "$transfer_raw" | awk -v k="$pubkey" '$1==k{print $2}')"
        tx_b="$(echo "$transfer_raw" | awk -v k="$pubkey" '$1==k{print $3}')"
        rx_b="${rx_b:-0}"
        tx_b="${tx_b:-0}"
        rx_fmt="$(_fmt_bytes "$rx_b")"
        tx_fmt="$(_fmt_bytes "$tx_b")"

        local status dot col
        status="$(_peer_status "$hs_ts")"
        dot="$(_status_dot "$status")"
        col="$(_status_colour "$status")"

        case "$status" in
            ACTIVE) active_count=$(( active_count + 1 )) ;;
            IDLE)   idle_count=$(( idle_count + 1 ))     ;;
            *)      stale_count=$(( stale_count + 1 ))   ;;
        esac

        # Печатаем строку: фиксированные поля без ANSI внутри %-форматов
        printf "  %-3d  %-20s  %-25s  %-16s  %-16s  %-16s  " \
               "$idx" \
               "${name:0:20}" \
               "${endpoint:0:25}" \
               "$last_seen" \
               "$rx_fmt" \
               "$tx_fmt"
        # STATUS со цветом — отдельно, после всех полей
        printf "%b%s %s%b\n" "$col" "$dot" "$status" "$NC"

    done <<< "$peers_raw"

    # ── Футер ────────────────────────────────────────────────────────────────
    echo   "  ────────────────────────────────────────────────────────────────────────────────"

    local stats
    stats="$(pool_stats "$iface" 2>/dev/null || echo "-")"

    printf "  Pool: ${BOLD}%s${NC}" "$stats"
    printf "     ${GREEN}● ACTIVE: %d${NC}" "$active_count"
    printf "   ${YELLOW}● IDLE: %d${NC}"   "$idle_count"
    printf "   ${RED}● STALE/NEVER: %d${NC}\n" "$stale_count"

    echo
    printf "  ${BOLD}Refresh: %ds${NC}   ${BOLD}[q]${NC} quit\n" "$MONITOR_INTERVAL"

    # Затираем всё что ниже курсора (хвост от предыдущего фрейма)
    tput ed 2>/dev/null
}

# --- Основная функция --------------------------------------------------------

peer_monitor() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   Peer Monitor                       ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════╝${NC}"
    echo

    # ── Выбор инстанса ────────────────────────────────────────────────────────
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

    # ── Realtime цикл ─────────────────────────────────────────────────────────
    tput civis 2>/dev/null                  # скрыть курсор

    _monitor_cleanup() {
        tput cnorm 2>/dev/null              # вернуть курсор
    }
    trap '_monitor_cleanup; return 0' INT TERM

    # Сохраняем строку, с которой начнём рисовать
    # (после выбора инстанса экран не чистили — делаем один clear перед первым фреймом)
    clear

    while true; do
        tput cup 0 0                        # курсор в начало, без clear
        _render_peer_table "$iface"

        if read -r -s -n 1 -t "$MONITOR_INTERVAL" key 2>/dev/null; then
            [[ "${key,,}" == "q" ]] && break
        fi
    done

    trap - INT TERM
    _monitor_cleanup
    clear                                   # убираем монитор, menu_servers перерисует сам
}