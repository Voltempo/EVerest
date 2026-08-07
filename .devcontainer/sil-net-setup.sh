#!/bin/bash
#
# Creates one veth pair per DC connector, so every ISO 15118 charger and its simulated car have a
# link entirely to themselves.
#
# V2G in SIL is not simulated - it is real IPv6 networking. The charger's SDP server binds UDP port
# 15118 (modules/EVSE/EvseV2G/sdp.cpp) and the car discovers it by link-local multicast to ff02::1.
# Put several chargers and several cars on one interface and a car pairs with whichever charger
# answers first, which is not necessarily its own. Each connector therefore gets a point-to-point
# link: EvseV2G pins its SDP socket with SO_BINDTODEVICE and PyEvJosev sends on the interface named
# in its 'device' config, so charger N only ever hears car N.
#
# Interface naming matches config-sil-<N>evse-dc.yaml:
#     evN-evse   charger side   (EvseV2G  device:)
#     evN-car    vehicle side   (PyEvJosev device:)
#
# Idempotent - safe to run again on an already-configured container.
#
# Usage: sil-net-setup.sh [connector-count]   (default 6)

set -euo pipefail

COUNT="${1:-6}"

if [[ ! "${COUNT}" =~ ^[0-9]+$ ]] || (( COUNT < 1 )); then
    echo "sil-net-setup: connector count must be a positive integer, got '${COUNT}'" >&2
    exit 2
fi

# CAP_NET_ADMIN is granted to the container but only usable by root; the devcontainer runs as an
# unprivileged user with passwordless sudo.
if [[ "${EUID}" -eq 0 ]]; then
    SUDO=()
else
    SUDO=(sudo -n)
fi

if ! "${SUDO[@]}" ip link show lo > /dev/null 2>&1; then
    echo "sil-net-setup: cannot run 'ip' - the container needs CAP_NET_ADMIN and root or sudo" >&2
    exit 1
fi

created=0
existing=0

for (( i = 1; i <= COUNT; i++ )); do
    evse="ev${i}-evse"
    car="ev${i}-car"

    if ip link show "${evse}" > /dev/null 2>&1; then
        (( existing += 1 ))
    else
        "${SUDO[@]}" ip link add "${evse}" type veth peer name "${car}"
        (( created += 1 ))
    fi

    "${SUDO[@]}" ip link set "${evse}" up
    "${SUDO[@]}" ip link set "${car}" up
done

# Both ends need an IPv6 link-local address before EvseV2G and PyEvJosev can bind. The kernel assigns
# it a moment after the link comes up, and duplicate address detection adds a little more, so wait
# rather than race the manager into a bind failure.
deadline=$(( SECONDS + 20 ))
missing=0
while (( SECONDS < deadline )); do
    missing=0
    for (( i = 1; i <= COUNT; i++ )); do
        for iface in "ev${i}-evse" "ev${i}-car"; do
            if ! ip -6 addr show dev "${iface}" scope link 2>/dev/null | grep -q 'inet6 fe80:'; then
                (( missing += 1 ))
            fi
        done
    done
    (( missing == 0 )) && break
    sleep 0.5
done

if (( missing != 0 )); then
    echo "sil-net-setup: ${missing} interface(s) still have no IPv6 link-local address after 20s" >&2
    ip -6 -o addr show scope link >&2
    exit 1
fi

echo "sil-net-setup: ${COUNT} connector link(s) ready (${created} created, ${existing} already present)"
