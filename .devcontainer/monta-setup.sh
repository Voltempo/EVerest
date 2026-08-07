#!/bin/bash
#
# Stamps out the per-vSECC OCPP configs the 3-vSECC config expects, from
# .devcontainer/ocpp-monta.example.json plus your own CSMS credentials.
#
# Run it from your own shell after the container is up:
#     ./.devcontainer/monta-setup.sh
#
# Why a script: the three boards' configs differ in exactly three fields and are identical in the
# other forty, so hand-editing three files is all downside. It writes to /build/monta/vseccN/, which
# lives on the everest-build volume rather than in this repo - deliberately, because the
# authorisation keys must never reach git.
#
# Credentials come from .devcontainer/monta-credentials.env (gitignored), or from the environment.
# Copy monta-credentials.example.env to get started. Expected variables, N = 1, 2, 3:
#     MONTA_CP_N     charge point identity as created in the CSMS, e.g. MYNAME_EVEREST_1
#     MONTA_KEY_N    the authorisation key the CSMS issued for that charge point
#     MONTA_URI      optional, defaults to wss://ocpp.monta.app
#
# Idempotent, but it will not silently replace an existing config - pass --force for that. Each
# board keeps its own OCPP database under /build/monta/vseccN/db, and overwriting a config while
# leaving a database that was registered under a different identity is a confusing way to lose an
# afternoon.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="${EVEREST_CONTAINER:-devcontainer-devcontainer-1}"
TEMPLATE=/workspace/.devcontainer/ocpp-monta.example.json
FORCE=0

[[ "${1:-}" == "--force" ]] && FORCE=1

say() { echo "[monta-setup] $*"; }
die() { echo "[monta-setup] $*" >&2; exit 1; }

docker inspect "${CONTAINER}" > /dev/null 2>&1 || die "container ${CONTAINER} not found - run sil-up.sh first"

if [[ -f "${HERE}/monta-credentials.env" ]]; then
    say "reading ${HERE}/monta-credentials.env"
    # shellcheck disable=SC1091
    set -a; . "${HERE}/monta-credentials.env"; set +a
else
    say "no monta-credentials.env - falling back to the environment"
fi

for n in 1 2 3; do
    cp_var="MONTA_CP_${n}"
    key_var="MONTA_KEY_${n}"
    [[ -n "${!cp_var:-}" ]]  || die "${cp_var} is not set - see monta-credentials.example.env"
    [[ -n "${!key_var:-}" ]] || die "${key_var} is not set - see monta-credentials.example.env"
done

# Templating happens inside the container: python3 is there, the template is bind-mounted at
# /workspace, and /build is only reachable from in there anyway.
docker exec -i \
    -e MONTA_URI="${MONTA_URI:-wss://ocpp.monta.app}" \
    -e MONTA_CP_1="${MONTA_CP_1}" -e MONTA_KEY_1="${MONTA_KEY_1}" \
    -e MONTA_CP_2="${MONTA_CP_2}" -e MONTA_KEY_2="${MONTA_KEY_2}" \
    -e MONTA_CP_3="${MONTA_CP_3}" -e MONTA_KEY_3="${MONTA_KEY_3}" \
    -e MONTA_FORCE="${FORCE}" \
    -e MONTA_TEMPLATE="${TEMPLATE}" \
    "${CONTAINER}" python3 - <<'PY'
import json, os, sys

template = json.load(open(os.environ['MONTA_TEMPLATE']))
template.pop('_comment', None)
force = os.environ['MONTA_FORCE'] == '1'
wrote = skipped = 0

for n in ('1', '2', '3'):
    target_dir = f'/build/monta/vsecc{n}'
    target = f'{target_dir}/ocpp-monta.json'

    if os.path.exists(target) and not force:
        existing = json.load(open(target)).get('Internal', {}).get('ChargePointId')
        print(f'[monta-setup]   {target} exists (ChargePointId={existing}) - left alone, use --force')
        skipped += 1
        continue

    config = json.loads(json.dumps(template))
    config['Internal']['ChargePointId'] = os.environ[f'MONTA_CP_{n}']
    config['Internal']['ChargeBoxSerialNumber'] = f'0002-{n}'
    config['Internal']['CentralSystemURI'] = os.environ['MONTA_URI']
    config['Security']['AuthorizationKey'] = os.environ[f'MONTA_KEY_{n}']

    os.makedirs(f'{target_dir}/db', exist_ok=True)
    os.makedirs(f'{target_dir}/logs', exist_ok=True)
    with open(target, 'w') as handle:
        json.dump(config, handle, indent=2)
        handle.write('\n')

    print(f"[monta-setup]   wrote {target}  ChargePointId={config['Internal']['ChargePointId']}")
    wrote += 1

print(f'[monta-setup] {wrote} written, {skipped} left alone')
if wrote:
    print('[monta-setup] set EVEREST_CONFIG=/workspace/config/config-sil-6evse-3vsecc.yaml in')
    print('[monta-setup] .devcontainer/.env, then ./.devcontainer/sil-up.sh --force-recreate')
PY
