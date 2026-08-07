#!/bin/bash
#
# Container command for the devcontainer service: bring up the SIL network, start EVerest, and keep
# the container alive either way.
#
# Why this exists: the stock devcontainer runs `sleep infinity`, so restarting it silently leaves you
# with a broker, a Node-RED dashboard and no EVerest. Every button still "works" - MQTT publishes
# never fail - while every readout is dead, which is a confusing way to lose an afternoon.
#
# Environment:
#     EVEREST_AUTOSTART    1 (default) to start the manager, 0 for a bare shell container
#     EVEREST_CONFIG       config path (default /workspace/config/config-sil-6evse-dc.yaml)
#     EVEREST_CONNECTORS   veth pairs to create (default 6, must match the config)
#     EVEREST_PREFIX       install prefix passed to the manager (default /build/dist)
#     MQTT_SERVER_ADDRESS  broker host, already set by the compose file
#     MQTT_SERVER_PORT     broker port, already set by the compose file
#
# The manager runs in the foreground so `docker logs` shows it, but the container falls back to
# sleep infinity if it exits. Losing EVerest should not also cost you the shell you need to debug it.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${EVEREST_CONFIG:-/workspace/config/config-sil-6evse-dc.yaml}"
CONNECTORS="${EVEREST_CONNECTORS:-6}"
PREFIX="${EVEREST_PREFIX:-/build/dist}"
MANAGER="${PREFIX}/bin/manager"
LOG=/tmp/everest-manager.log

say() { echo "[sil-start] $*"; }

idle_forever() {
    say "container staying up - start EVerest by hand with:"
    say "  ${MANAGER} --prefix ${PREFIX} --config ${CONFIG}"
    exec sleep infinity
}

if [[ "${EVEREST_AUTOSTART:-1}" != "1" ]]; then
    say "EVEREST_AUTOSTART=${EVEREST_AUTOSTART:-1} - skipping EVerest startup"
    idle_forever
fi

if [[ ! -x "${MANAGER}" ]]; then
    say "no manager binary at ${MANAGER} - the /build volume has not been built yet"
    idle_forever
fi

if [[ ! -f "${CONFIG}" ]]; then
    say "no config at ${CONFIG}"
    idle_forever
fi

if ! "${HERE}/sil-net-setup.sh" "${CONNECTORS}"; then
    say "network setup failed - ISO 15118 would bind the wrong interfaces, refusing to start EVerest"
    idle_forever
fi

# The manager exits immediately if the broker is not there yet, and compose only orders container
# start, not readiness.
broker_host="${MQTT_SERVER_ADDRESS:-mqtt-server}"
broker_port="${MQTT_SERVER_PORT:-1883}"

say "waiting for MQTT broker at ${broker_host}:${broker_port}"
for _ in $(seq 1 60); do
    if (echo > "/dev/tcp/${broker_host}/${broker_port}") > /dev/null 2>&1; then
        break
    fi
    sleep 1
done

if ! (echo > "/dev/tcp/${broker_host}/${broker_port}") > /dev/null 2>&1; then
    say "broker never came up at ${broker_host}:${broker_port}"
    idle_forever
fi

say "starting EVerest with ${CONFIG} (${CONNECTORS} connectors)"
"${MANAGER}" --prefix "${PREFIX}" --config "${CONFIG}" 2>&1 | tee "${LOG}"

say "manager exited with status ${PIPESTATUS[0]} - see ${LOG}"
idle_forever
