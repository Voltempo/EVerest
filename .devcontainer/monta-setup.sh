#!/bin/bash
#
# Host-side one-liner for pointing this rig at Monta. Run it from your own shell:
#
#     ./.devcontainer/monta-setup.sh              dry run - proves the topology without touching Monta
#     ./.devcontainer/monta-setup.sh --live       for real
#
# It does not build the configs itself. sim/make_vsecc_ocpp_configs.py in the EVerest-MCP repo does
# that, and stays the single place that knows what a vSECC config looks like. This exists because
# that generator has to run inside the container and reads its keys from a file inside the container,
# which is an unpleasant way to spend your first hour. So this wrapper:
#
#   1. reads your credentials from .devcontainer/monta-credentials.env, which you can edit normally
#   2. writes them into /build/monta/vsecc-keys.json inside the container
#   3. copies the generator in and runs it
#
# Everything it passes through - --boards, --connectors-per-board, --serial-base, --security-profile,
# --allow-shared-key - belongs to the generator; see its --help.
#
# Every docker command below is wrapped in sh -c on purpose. On Windows Git Bash, MSYS rewrites
# anything that looks like an absolute Unix path in a docker argument into a Windows path before
# Docker sees it, so a bare `docker exec ... python3 /tmp/gen.py` fails looking for
# /workspace/C:/Users/... - and a --root would silently write onto your host instead.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${EVEREST_CONTAINER:-devcontainer-devcontainer-1}"
CREDENTIALS="${HERE}/monta-credentials.env"

# The generator lives in the sibling EVerest-MCP clone. Overridable for anyone who keeps it elsewhere.
GENERATOR="${EVEREST_MCP_REPO:-${HERE}/../../EVerest-MCP}/sim/make_vsecc_ocpp_configs.py"

say() { echo "[monta-setup] $*"; }
die() { echo "[monta-setup] $*" >&2; exit 1; }

[[ -f "${GENERATOR}" ]] || die "no generator at ${GENERATOR} - clone EVerest-MCP beside this repo, or set EVEREST_MCP_REPO"
docker inspect "${CONTAINER}" > /dev/null 2>&1 || die "container ${CONTAINER} not found - run sil-up.sh first"

if [[ ! -f "${CREDENTIALS}" ]]; then
    die "no ${CREDENTIALS}
  Copy monta-credentials.example.env to monta-credentials.env and fill it in. It is gitignored."
fi

# shellcheck disable=SC1090
set -a; . "${CREDENTIALS}"; set +a

[[ -n "${MONTA_PREFIX:-}" ]] || die "MONTA_PREFIX is not set - use your own name, not a colleague's"
[[ "${MONTA_PREFIX}" != "YOURNAME_EVEREST" ]] || die "MONTA_PREFIX is still the placeholder - set it to your own prefix"

BOARDS="${MONTA_BOARDS:-3}"
LIVE=0
[[ "${1:-}" == "--live" ]] && { LIVE=1; shift; }

if [[ "${LIVE}" == "1" ]]; then
    keys='{'

    for n in $(seq 1 "${BOARDS}"); do
        key_var="MONTA_KEY_${n}"
        [[ -n "${!key_var:-}" ]] || die "${key_var} is not set. Create ${MONTA_PREFIX}_${n} in Monta and paste its authorisation key."
        [[ ${n} -eq 1 ]] || keys+=','
        keys+="\"${MONTA_PREFIX}_${n}\":\"${!key_var}\""
    done

    keys+='}'

    say "writing /build/monta/vsecc-keys.json for ${BOARDS} board(s)"

    # Through stdin rather than an argument, so no key is ever visible in ps output or shell history.
    printf '%s' "${keys}" | docker exec -i "${CONTAINER}" sh -c 'mkdir -p /build/monta && cat > /build/monta/vsecc-keys.json && chmod 600 /build/monta/vsecc-keys.json'
fi

say "copying the generator into ${CONTAINER}"
docker cp "${GENERATOR}" "${CONTAINER}:/tmp/make_vsecc_ocpp_configs.py" > /dev/null

generator_args="--prefix ${MONTA_PREFIX} --boards ${BOARDS}"
[[ "${LIVE}" == "1" ]] && generator_args+=" --live"
[[ -n "${MONTA_URI:-}" ]] && say "note: CentralSystemURI comes from ocpp-monta.example.json, not MONTA_URI - edit the template to change it"

docker exec "${CONTAINER}" sh -c "python3 /tmp/make_vsecc_ocpp_configs.py ${generator_args} $*"

if [[ "${LIVE}" == "1" ]]; then
    say "now point the stack at the OCPP config:"
    say "  echo 'EVEREST_CONFIG=/workspace/config/config-sil-6evse-3vsecc.yaml' >> .devcontainer/.env"
    say "  ./.devcontainer/sil-up.sh --force-recreate"
else
    say "dry run - nothing reached Monta. Re-run with --live once the charge points exist and the keys are in place."
fi
