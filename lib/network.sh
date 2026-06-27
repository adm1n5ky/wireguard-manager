#!/usr/bin/env bash
# =============================================================================
# lib/network.sh — IP math, subnet overlap detection, conflict checking
# =============================================================================

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

prefix_to_mask_int() {
    local prefix="$1"
    if (( prefix == 0 )); then
        echo 0
    else
        echo $(( 0xFFFFFFFF ^ ( (1 << (32 - prefix)) - 1 ) ))
    fi
}

network_overlap() {
    local net1="$1"
    local net2="$2"

    local ip1 prefix1 ip2 prefix2
    ip1="${net1%/*}";  prefix1="${net1#*/}"
    ip2="${net2%/*}";  prefix2="${net2#*/}"

    local int1 int2 mask1 mask2 base1 base2

    int1="$(ip_to_int "$ip1")"
    int2="$(ip_to_int "$ip2")"

    mask1="$(prefix_to_mask_int "$prefix1")"
    mask2="$(prefix_to_mask_int "$prefix2")"

    local common_mask
    if (( mask1 < mask2 )); then
        common_mask="$mask1"
    else
        common_mask="$mask2"
    fi

    base1=$(( int1 & common_mask ))
    base2=$(( int2 & common_mask ))

    if (( base1 == base2 )); then
        return 0   # overlap
    fi
    return 1       # no overlap
}

network_to_server_ip() {
    local cidr="$1"
    local ip prefix
    ip="${cidr%/*}"
    prefix="${cidr#*/}"

    local int
    int="$(ip_to_int "$ip")"
    int=$(( int + 1 ))

    echo "$(int_to_ip "$int")/${prefix}"
}

network_conflicts() {
    local new_cidr="$1"

    for env_file in "${WG_CONFIG_DIR}"/*.env; do
        [[ -f "$env_file" ]] || continue

        local existing_net existing_name
        existing_net="$(env_get "$env_file" WG_NETWORK)"
        existing_name="$(env_get "$env_file" WG_NAME)"

        [[ -z "$existing_net" ]] && continue

        if network_overlap "$new_cidr" "$existing_net"; then
            echo "${existing_name} (${existing_net})"
            return 0
        fi
    done

    return 1
}
# =============================================================================
# IPv6 helpers
# =============================================================================

# Expand a compressed IPv6 address to full 8-group form
ipv6_expand() {
    python3 -c "
import sys, ipaddress
try:
    print(ipaddress.ip_address(sys.argv[1]).exploded)
except:
    print('')
" "$1"
}

# Validate an IPv6 CIDR (e.g. 2001:470:7547:100::/64)
validate_ipv6_cidr() {
    python3 -c "
import sys, ipaddress
try:
    net = ipaddress.ip_network(sys.argv[1], strict=True)
    if net.version != 6:
        print('Not an IPv6 network.')
        sys.exit(1)
    prefix = net.prefixlen
    if prefix < 48 or prefix > 126:
        print('Prefix must be between /48 and /126.')
        sys.exit(1)
    sys.exit(0)
except ValueError as e:
    print(str(e))
    sys.exit(1)
" "$1"
}

# Get server IPv6 address (first host) from a /64 CIDR
# e.g. 2001:470:7547:100::/64 → 2001:470:7547:100::1/64
ipv6_network_to_server_ip() {
    python3 -c "
import sys, ipaddress
net = ipaddress.ip_network(sys.argv[1], strict=False)
hosts = net.hosts()
first = next(hosts)
print(f'{first}/{net.prefixlen}')
" "$1"
}

# Allocate next available IPv6 from pool (after last used)
# Pool file: ip-pool6.dat, format: <ip> <status> <client> <ts>
ipv6_next_host() {
    python3 -c "
import sys, ipaddress

cidr   = sys.argv[1]
last   = sys.argv[2] if len(sys.argv) > 2 else ''

net    = ipaddress.ip_network(cidr, strict=False)
start  = int(net.network_address) + 2   # ::1 reserved for server

if last:
    try:
        start = int(ipaddress.ip_address(last)) + 1
    except:
        pass

candidate = ipaddress.ip_address(start)
# safety: must be within network
if candidate not in net:
    print('')
    sys.exit(1)
print(str(candidate))
" "$1" "$2"
}

# Detect routable IPv6 prefixes available on this host (≤/64)
detect_ipv6_prefixes() {
    python3 -c "
import subprocess, ipaddress, re

result = subprocess.run(['ip', '-6', 'addr', 'show'], capture_output=True, text=True)
seen = set()
for line in result.stdout.splitlines():
    m = re.search(r'inet6\s+([0-9a-f:]+/\d+)', line)
    if not m:
        continue
    try:
        net = ipaddress.ip_network(m.group(1), strict=False)
    except:
        continue
    if net.is_loopback or net.is_link_local or net.is_multicast:
        continue
    if net.prefixlen > 64:
        continue
    key = str(net)
    if key not in seen:
        seen.add(key)
        print(key)
"
}